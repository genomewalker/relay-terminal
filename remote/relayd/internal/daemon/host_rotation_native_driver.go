package daemon

import (
	"context"
	"errors"
	"os"
	"time"
)

// Only the acquisition path can provide this interface. Recovery never creates
// one from journal bytes and never resubmits native commit.
type hostNativeDriverClaim interface {
	requestCommitIntent(context.Context) (hostNativeIntentReceipt, error)
	submitNativeCommit(context.Context) (nativeRotationReply, error)
	release(context.Context) error
}

type hostNativeDriverResult struct {
	Pending bool
	State   string
}

type hostNativeDriverDependencies struct {
	hostNativeRetirementDependencies
	acquire       func(context.Context, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverClaim, error)
	observe       func(context.Context, hostRotationEnrollment, string, string) (nativeRotationReply, error)
	refusalOwner  func(hostRotationEnrollment, hostNativeRefusalRecord) error
	retireRefusal func(context.Context, hostRotationEnrollment, hostNativeRefusalRecord) (nativeRotationReply, error)
}

type hostNativeTransactionDriver struct {
	directory string
	deps      hostNativeDriverDependencies
}

func nativeHostRotationTransactionDriver(session *Session, directory string) *hostNativeTransactionDriver {
	return &hostNativeTransactionDriver{directory: directory, deps: hostNativeDriverDependencies{
		hostNativeRetirementDependencies: hostNativeRetirementDependencies{
			hostNativeRegistrationDependencies: hostNativeRegistrationDependencies{
				binding: readHostNativeRegistrationBinding, ledger: callHostNativeLedger,
			},
			retire: session.retireNativeContextRotation,
		},
		acquire: func(ctx context.Context, e hostRotationEnrollment, p hostRotationPreparation, guard func() error) (hostNativeDriverClaim, error) {
			return session.claimNativeContextRotation(ctx, directory, e, p, guard)
		},
		observe:       session.observeNativeContextRotation,
		refusalOwner:  verifyHostNativeRefusalOwner,
		retireRefusal: session.retireNativeRefusal,
	}}
}

func hostNativeDriverPending(state string, err error) (hostNativeDriverResult, error) {
	return hostNativeDriverResult{Pending: true, State: state}, err
}

// All pre-commit stages retain the original in-memory lease. The underlying
// claim refuses release after its durable commit boundary, including failures.
func (d *hostNativeTransactionDriver) start(ctx context.Context, s *hostRotationSupervisor,
	e hostRotationEnrollment, p hostRotationPreparation, guard func() error) (hostNativeDriverResult, error) {
	if d == nil || s == nil || d.deps.acquire == nil || guard == nil || e.Client != "codex" ||
		p.State != "prepared" || p.Capsule == nil {
		return hostNativeDriverPending("native_start_unavailable", errors.New("native transaction preparation unavailable"))
	}
	if err := ctx.Err(); err != nil {
		return hostNativeDriverPending("native_start_cancelled", err)
	}
	if err := guard(); err != nil {
		return hostNativeDriverPending("native_start_cancelled", err)
	}
	if previous := s.snapshot().NativeAbortTransition; previous != nil && previous.Finalized && previous.Source == e &&
		(p.TurnID == previous.TurnID || p.TurnSeq <= previous.TurnSeq) {
		return hostNativeDriverPending("native_retry_requires_new_turn", errors.New("native refusal requires a new completed turn or explicit re-enrollment"))
	}
	claim, err := d.deps.acquire(ctx, e, p, guard)
	if err != nil {
		return hostNativeDriverPending("native_claim_pending", err)
	}
	if claim == nil {
		return hostNativeDriverPending("native_claim_pending", errors.New("native acquisition returned no claim"))
	}
	if _, err := claim.requestCommitIntent(ctx); err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = claim.release(cleanup)
		cancel()
		return hostNativeDriverPending("native_intent_pending", err)
	}
	observed, err := claim.submitNativeCommit(ctx)
	if err != nil {
		return hostNativeDriverPending("native_handoff_pending", err)
	}
	return d.completeObservation(ctx, s, e, observed)
}

// A restored receipt must pass the existing complete native journal and owner
// checks before registration. Each downstream stage is independently durable.
func (d *hostNativeTransactionDriver) completeObservation(ctx context.Context, s *hostRotationSupervisor,
	e hostRotationEnrollment, observed nativeRotationReply) (hostNativeDriverResult, error) {
	if err := ctx.Err(); err != nil {
		return hostNativeDriverPending("native_completion_pending", err)
	}
	if s == nil || s.snapshot().Enrollment != e {
		return hostNativeDriverPending("native_source_mismatch", errors.New("native supervisor source changed"))
	}
	input, err := readHostNativeCompletionInput(d.directory, e.SessionID)
	if err != nil {
		return hostNativeDriverPending("native_handoff_pending", err)
	}
	r := input.request
	if r.Source.Enrollment != e || observed.Version != 1 ||
		validateNativeRotationReply(nativeRotationCommand{Operation: "reconcile", ThreadID: r.SessionID,
			OperationID: r.Epoch, HostClaimID: r.HostClaimID}, observed) != nil {
		return hostNativeDriverPending("native_completion_unavailable", errors.New("native observation differs from durable handoff"))
	}
	switch observed.State {
	case "pending":
		return hostNativeDriverPending("native_completion_pending", nil)
	case "source_retained":
		if !observed.Source.matches(r.Reservation.Native) {
			return hostNativeDriverPending("native_completion_unavailable", errors.New("native retained source changed"))
		}
		if observed.JournalDirectory == "" {
			return hostNativeDriverPending("native_source_retained", nil)
		}
		if _, err := verifyAndRecordHostNativeRefusal(ctx, d.directory, e.SessionID, observed.JournalDirectory, d.deps.refusalOwner); err != nil {
			return hostNativeDriverPending("native_refusal_verification_pending", err)
		}
		return d.abortRefusal(ctx, s, e)
	case "restored":
	default:
		return hostNativeDriverPending("native_completion_unavailable", errors.New("native restoration unavailable"))
	}
	if _, err := registerHostNativeCompletion(ctx, d.directory, e.SessionID, *observed.Completion, d.deps.hostNativeRegistrationDependencies); err != nil {
		return hostNativeDriverPending("native_registration_pending", err)
	}
	if _, err := acknowledgeHostNativeCompletion(ctx, d.directory, e.SessionID, d.deps.hostNativeRegistrationDependencies); err != nil {
		return hostNativeDriverPending("native_ledger_ack_pending", err)
	}
	if _, err := retireHostNativeCompletion(ctx, d.directory, e.SessionID, d.deps.hostNativeRetirementDependencies); err != nil {
		return hostNativeDriverPending("native_retirement_pending", err)
	}
	if err := finalizeHostNativeCompletion(ctx, s, d.directory, e.SessionID,
		hostNativeFinalizationDependencies{hostNativeRegistrationDependencies: d.deps.hostNativeRegistrationDependencies}); err != nil {
		return hostNativeDriverPending("native_finalization_pending", err)
	}
	return hostNativeDriverResult{}, nil
}

// Load only descriptive completion evidence. completeObservation re-verifies
// the native files, physical owner, ledger and exact durable proof before use.
func readHostNativeDriverReceipt(directory string, input *hostNativeCompletionInput) (*nativeRotationCompletion, error) {
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeCompletionInputAt(root, directory, input.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return nil, errors.New("native recovery handoff changed")
	}
	raw, err := readHostNativeClaimFile(root, input.request.Epoch+".native_restored_verified.json")
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var proof hostNativeCompletionProof
	r := input.request
	if decodeHostNativeRecord(raw, &proof) != nil || proof.Version != 1 || proof.State != "native_restored_verified" ||
		proof.RequestSHA256 != input.journal.requestSHA256 || proof.HostSnapshotSHA256 != input.fingerprint ||
		!proof.Receipt.valid(r.Epoch, r.HostClaimID) || !proof.Receipt.Source.matches(r.Reservation.Native) ||
		proof.Receipt.CapsuleSHA256 != r.Capsule.SHA256 || proof.Receipt.ProcessID != uint32(r.Source.Enrollment.AgentPID) {
		return nil, errors.New("native recovery completion proof changed")
	}
	receipt := proof.Receipt
	return &receipt, nil
}

// Recovery only observes an existing commit or advances durable completion.
// It neither claims nor requests intent, and never invokes submitNativeCommit.
func (d *hostNativeTransactionDriver) recover(ctx context.Context, s *hostRotationSupervisor) (hostNativeDriverResult, error) {
	if d == nil || s == nil {
		return hostNativeDriverPending("native_recovery_unavailable", errors.New("native driver unavailable"))
	}
	if err := ctx.Err(); err != nil {
		return hostNativeDriverPending("native_recovery_cancelled", err)
	}
	saved := s.snapshot()
	if link := saved.NativeAbortTransition; link != nil && !link.Finalized {
		if err := finalizeHostNativeRefusal(ctx, s, d.directory, link.Source.SessionID,
			hostNativeAbortFinalizationDependencies{hostNativeAbortDependencies: hostNativeAbortDependencies{owner: d.deps.refusalOwner, ledger: d.deps.ledger}}); err != nil {
			return hostNativeDriverPending("native_abort_finalization_pending", err)
		}
		return hostNativeDriverResult{}, nil
	}
	if link := saved.NativeTransition; link != nil && !link.Finalized {
		if err := finalizeHostNativeCompletion(ctx, s, d.directory, link.Source.SessionID,
			hostNativeFinalizationDependencies{hostNativeRegistrationDependencies: d.deps.hostNativeRegistrationDependencies}); err != nil {
			return hostNativeDriverPending("native_finalization_pending", err)
		}
		return hostNativeDriverResult{}, nil
	}
	e := saved.Enrollment
	state := inspectHostNativeSupervisorJournal(d.directory, e)
	if state == "" {
		return hostNativeDriverResult{}, nil
	}
	if state != "claim_pending" && state != "commit_pending" {
		return hostNativeDriverPending("native_"+state, errors.New("native recovery journal unavailable"))
	}
	before, err := readHostNativeClaimSnapshot(d.directory, e.SessionID)
	if err != nil || before == nil || before.request.Source.Enrollment != e {
		return hostNativeDriverPending("native_journal_unavailable", errors.New("native recovery source changed"))
	}
	if !before.commitPending {
		result, err := reconcileHostNativeRelease(ctx, d.directory, e.SessionID, d.deps.ledger)
		if err == nil && (result.State == "release_reconciled" || result.State == "no_active_claim") {
			return hostNativeDriverResult{}, nil
		}
		return hostNativeDriverPending("native_claim_pending", err)
	}
	input, err := readHostNativeCompletionInput(d.directory, e.SessionID)
	if err != nil || input.request != before.request || input.journal.requestSHA256 != before.journal.requestSHA256 {
		return hostNativeDriverPending("native_handoff_pending", errors.New("native durable handoff unavailable"))
	}
	refusal, err := readHostNativeDriverRefusal(d.directory, input)
	if err != nil {
		return hostNativeDriverPending("native_refusal_verification_pending", err)
	}
	if refusal != nil {
		return d.abortRefusal(ctx, s, e)
	}
	receipt, err := readHostNativeDriverReceipt(d.directory, input)
	if err != nil {
		return hostNativeDriverPending("native_completion_unavailable", err)
	}
	var observed nativeRotationReply
	if receipt != nil {
		observed = nativeRotationReply{Version: 1, State: "restored", OperationID: receipt.OperationID, HostClaimID: receipt.HostClaimID, Completion: receipt}
	} else {
		if d.deps.observe == nil {
			return hostNativeDriverPending("native_observation_unavailable", errors.New("native observer unavailable"))
		}
		observed, err = d.deps.observe(ctx, e, input.request.Epoch, input.request.HostClaimID)
		if err != nil {
			return hostNativeDriverPending("native_observation_unavailable", err)
		}
	}
	return d.completeObservation(ctx, s, e, observed)
}

// Authenticate the current foreground bridge by the retained process and worker,
// allowing its binding to have advanced to the target. The returned observation
// still needs exact source/journal/target verification in completeObservation.
func (session *Session) observeNativeContextRotation(ctx context.Context, e hostRotationEnrollment,
	operationID, hostClaimID string) (nativeRotationReply, error) {
	if err := ctx.Err(); err != nil {
		return nativeRotationReply{}, err
	}
	if session == nil || e.Client != "codex" || e.PaneID != session.id || e.WorkerPID != os.Getpid() {
		return nativeRotationReply{}, errors.New("native recovery worker changed")
	}
	start, err := processStartTime(os.Getpid())
	if err != nil || start != e.WorkerStart {
		return nativeRotationReply{}, errors.New("native recovery worker incarnation changed")
	}
	boot, err := nodeBootID()
	if err != nil || boot != e.NodeBootID {
		return nativeRotationReply{}, errors.New("native recovery boot changed")
	}
	binding, err := ReadNativeAgentBinding(e.PaneID)
	if err != nil || binding.Producer.Provider != "codex" || binding.Producer.ProcessID != e.AgentPID ||
		binding.Producer.ProcessStart != e.AgentStart {
		return nativeRotationReply{}, errors.New("native recovery provider changed")
	}
	session.nativeRotationMu.Lock()
	bridge := session.nativeRotation
	session.nativeRotationMu.Unlock()
	if bridge == nil || bridge.providerPID != e.AgentPID || bridge.providerStart != e.AgentStart ||
		!nativeRotationCallerMatches(bridge.helperPID, e.AgentPID, e.AgentStart) {
		return nativeRotationReply{}, errors.New("native recovery foreground bridge unavailable")
	}
	return bridge.observeNativeCommit(ctx, e.SessionID, operationID, hostClaimID)
}

func (d *hostNativeTransactionDriver) abortRefusal(ctx context.Context, s *hostRotationSupervisor, e hostRotationEnrollment) (hostNativeDriverResult, error) {
	deps := hostNativeAbortDependencies{owner: d.deps.refusalOwner, ledger: d.deps.ledger}
	if _, err := abortHostNativeRefusal(ctx, d.directory, e.SessionID, deps); err != nil {
		return hostNativeDriverPending("native_abort_pending", err)
	}
	if _, err := retireHostNativeRefusal(ctx, d.directory, e.SessionID, hostNativeAbortRetirementDependencies{
		hostNativeAbortDependencies: deps, retire: d.deps.retireRefusal,
	}); err != nil {
		return hostNativeDriverPending("native_abort_retirement_pending", err)
	}
	if err := finalizeHostNativeRefusal(ctx, s, d.directory, e.SessionID, hostNativeAbortFinalizationDependencies{hostNativeAbortDependencies: deps}); err != nil {
		return hostNativeDriverPending("native_abort_finalization_pending", err)
	}
	return hostNativeDriverResult{}, nil
}
