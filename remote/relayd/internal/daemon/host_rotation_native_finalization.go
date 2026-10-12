package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"time"

	"golang.org/x/sys/unix"
)

// Retained after completion as the last transition receipt. Pending transitions
// gate evaluation on restart, including when supervision has been disabled.
type hostRotationNativeTransition struct {
	Version          int                       `json:"v"`
	Source           hostRotationEnrollment    `json:"source"`
	Target           hostRotationEnrollment    `json:"target"`
	RequestSHA256    string                    `json:"request_sha256"`
	RetirementSHA256 string                    `json:"retirement_sha256"`
	Retirement       hostNativeRetirementProof `json:"retirement"`
	Finalized        bool                      `json:"finalized"`
}
type hostNativeFinalizationProof struct {
	Version    int                          `json:"v"`
	State      string                       `json:"state"`
	Transition hostRotationNativeTransition `json:"transition"`
}
type hostNativeFinalizationDependencies struct {
	hostNativeRegistrationDependencies
	after func(string) error
}

func (t hostRotationNativeTransition) identity() hostRotationNativeTransition {
	t.Finalized = false
	return t
}
func (t hostRotationNativeTransition) valid() bool {
	r := t.Retirement
	target := t.Source
	target.SessionID = r.TargetSessionID
	return t.Version == 1 && t.Source.Client == "codex" && t.Source.SessionID == r.SessionID &&
		validHostNativeUUID(t.Source.SessionID) && validHostNativeUUID(r.TargetSessionID) && r.TargetSessionID != r.SessionID &&
		t.Target == target && t.Source.AgentPID > 1 && t.Source.WorkerPID > 1 && t.Source.AgentStart != 0 && t.Source.WorkerStart != 0 &&
		r.Version == 1 && r.State == "native_retired" && validHostNativeUUID(r.OperationID) && validHostNativeUUID(r.HostClaimID) &&
		r.OperationID != r.HostClaimID && nativeWireHash(r.AckSnapshotSHA256) &&
		nativeWireHash(t.RequestSHA256) && nativeWireHash(t.RetirementSHA256)
}
func hostNativeFinalizationPhase(link hostRotationNativeTransition, state string) hostNativeFinalizationProof {
	return hostNativeFinalizationProof{1, state, link.identity()}
}
func readHostNativeFinalizationPhase(root *os.File, link hostRotationNativeTransition, state string) (bool, error) {
	raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+"."+state+".json")
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	expected := hostNativeFinalizationPhase(link, state)
	if !hostNativeRegistrationExactShape(raw, expected) {
		return false, errors.New("native finalization record changed")
	}
	return true, nil
}

// Read historical proof without recreating an active marker or a native owner.
// Used only after host_finalized was made durable, before fence cleanup.
func verifyHostNativeFinalizationHistoryAt(root *os.File, link hostRotationNativeTransition) error {
	if !link.valid() {
		return errors.New("invalid native finalization transition")
	}
	for _, state := range []string{"host_finalization_requested", "host_finalized"} {
		exists, err := readHostNativeFinalizationPhase(root, link, state)
		if err != nil {
			return err
		}
		if !exists {
			return errors.New("native finalization history is incomplete")
		}
	}
	raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+".native_retired.json")
	if err != nil || hostRotationCapsuleHash(raw) != link.RetirementSHA256 ||
		!hostNativeRegistrationExactShape(raw, link.Retirement) {
		return errors.New("native finalization retirement proof changed")
	}
	raw, err = readHostNativeClaimFile(root, link.Retirement.OperationID+".request.json")
	var request hostNativeClaimRequest
	if err != nil || hostRotationCapsuleHash(raw) != link.RequestSHA256 || decodeHostNativeRecord(raw, &request) != nil ||
		validateHostNativeStoredRequest(request) != nil || request.SessionID != link.Source.SessionID ||
		request.Epoch != link.Retirement.OperationID || request.HostClaimID != link.Retirement.HostClaimID ||
		request.Source.Enrollment != link.Source {
		return errors.New("native finalization source changed")
	}
	return nil
}
func readHostNativeFinalizationInput(workerDirectory, sessionID string) (*hostNativeRetirementInput, hostRotationNativeTransition, error) {
	var empty hostRotationNativeTransition
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, empty, err
	}
	defer root.Close()
	defer lock.Close()
	input, err := readHostNativeRetirementInputAt(root, workerDirectory, sessionID)
	if err != nil {
		return nil, empty, err
	}
	for _, state := range []string{"native_ack_requested", "native_retired"} {
		raw, err := readHostNativeClaimFile(root, input.receipt.Epoch+"."+state+".json")
		if err != nil || !hostNativeRegistrationExactShape(raw, hostNativeRetirementPhase(input, state)) {
			return nil, empty, errors.New("native finalization requires durable retirement")
		}
		if state == "native_retired" {
			empty = hostRotationNativeTransition{Version: 1, Source: input.ack.completion.request.Source.Enrollment,
				Target: input.ack.registration.Request.Target.Enrollment, RequestSHA256: input.ack.completion.journal.requestSHA256,
				RetirementSHA256: hostRotationCapsuleHash(raw), Retirement: hostNativeRetirementPhase(input, "native_retired")}
		}
	}
	if !empty.valid() {
		return nil, empty, errors.New("native finalization identity unavailable")
	}
	for _, state := range []string{"host_finalization_requested", "host_finalized"} {
		if _, err := readHostNativeFinalizationPhase(root, empty, state); err != nil {
			return nil, empty, err
		}
	}
	return input, empty, nil
}
func writeHostNativeFinalizationPhase(workerDirectory string, input *hostNativeRetirementInput, link hostRotationNativeTransition, state string) error {
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeRetirementInputAt(root, workerDirectory, link.Source.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return errors.New("native finalization durable ACK changed")
	}
	raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+".native_retired.json")
	if err != nil || hostRotationCapsuleHash(raw) != link.RetirementSHA256 ||
		!hostNativeRegistrationExactShape(raw, link.Retirement) {
		return errors.New("native finalization retirement changed")
	}
	if state == "host_finalized" {
		exists, err := readHostNativeFinalizationPhase(root, link, "host_finalization_requested")
		if err != nil {
			return err
		}
		if !exists {
			return errors.New("native finalization intent unavailable")
		}
	}
	raw, err = json.Marshal(hostNativeFinalizationPhase(link, state))
	if err != nil {
		return err
	}
	return writeHostNativeClaimFile(root, link.Retirement.OperationID+"."+state+".json", raw, true)
}
func finishHostNativeFinalizationFence(workerDirectory string, link hostRotationNativeTransition) error {
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := verifyHostNativeFinalizationHistoryAt(root, link); err != nil {
		return err
	}
	raw, err := readHostNativeClaimFile(root, link.Source.SessionID+".active.json")
	if errors.Is(err, os.ErrNotExist) {
		return root.Sync()
	}
	if err != nil {
		return err
	}
	expected := hostNativeClaimActive{Version: 1, OperationID: link.Retirement.OperationID, RequestSHA256: link.RequestSHA256}
	if !hostNativeRegistrationExactShape(raw, expected) {
		return errors.New("native finalization will not remove another active operation")
	}
	if err := unix.Unlinkat(int(root.Fd()), link.Source.SessionID+".active.json", 0); err != nil {
		return err
	}
	return root.Sync()
}
func (s *hostRotationSupervisor) completeNativeTransitionLocked(link hostRotationNativeTransition) error {
	if s.record.NativeTransition == nil || s.record.NativeTransition.identity() != link.identity() {
		return errors.New("native supervisor transition changed")
	}
	if s.record.NativeTransition.Finalized {
		return nil
	}
	if s.record.Enrollment != link.Target {
		return errors.New("native target supervision was not persisted")
	}
	completed := link
	completed.Finalized = true
	s.record.NativeTransition = &completed
	s.record.NativeRecoveryState = ""
	s.record.Generation++
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.record.Decision = nil
	s.record.Preparation = nil
	if s.record.Enabled {
		s.record.State = "pending_evaluation"
	}
	if err := s.saveLocked(); err != nil {
		s.record.NativeTransition = &link
		s.record.Enabled = false
		s.record.State = "persistence_failed"
		return err
	}
	return nil
}

// Recover only durable finalization. This path needs no live provider and never
// re-enables supervision disabled by human input or a user request.
func recoverHostNativeFinalizedTransition(s *hostRotationSupervisor, workerDirectory string, link hostRotationNativeTransition) (bool, error) {
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return false, err
	}
	exists, err := readHostNativeFinalizationPhase(root, link, "host_finalized")
	if err == nil && exists {
		err = verifyHostNativeFinalizationHistoryAt(root, link)
	}
	lock.Close()
	root.Close()
	if err != nil || !exists {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.record.NativeTransition == nil || s.record.NativeTransition.identity() != link.identity() {
		return false, errors.New("native supervisor recovery identity changed")
	}
	if s.record.NativeTransition.Finalized {
		return true, nil
	}
	if s.record.Enrollment != link.Target {
		return false, errors.New("native supervisor target was not recorded")
	}
	if err := finishHostNativeFinalizationFence(workerDirectory, link); err != nil {
		return false, err
	}
	if err := s.completeNativeTransitionLocked(link); err != nil {
		return false, err
	}
	s.notify()
	return true, nil
}
func finalizeHostNativeCompletion(ctx context.Context, s *hostRotationSupervisor, workerDirectory, sessionID string,
	deps hostNativeFinalizationDependencies) error {
	if s == nil || !validHostNativeUUID(sessionID) {
		return errors.New("native finalization source unavailable")
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	saved := s.snapshot()
	if link := saved.NativeTransition; link != nil && link.Source.SessionID == sessionID {
		if !link.valid() {
			return errors.New("invalid saved native transition")
		}
		done, err := recoverHostNativeFinalizedTransition(s, workerDirectory, *link)
		if err != nil || done {
			return err
		}
	}
	if deps.binding == nil || deps.ledger == nil {
		return errors.New("native finalization evidence unavailable")
	}
	input, link, err := readHostNativeFinalizationInput(workerDirectory, sessionID)
	if err != nil {
		return err
	}
	if err := verifyHostNativeAckEvidence(ctx, deps.hostNativeRegistrationDependencies, input.ack); err != nil {
		return err
	}
	ack, err := reconcileHostNativeAck(ctx, deps.hostNativeRegistrationDependencies, input.ack)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(ack, input.receipt) {
		return errors.New("native finalization ledger ACK changed")
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.record.NativeAbortTransition != nil && !s.record.NativeAbortTransition.Finalized {
		return errors.New("native abort finalization is pending")
	}
	old := s.record.NativeTransition
	if old != nil && !old.Finalized && old.identity() != link.identity() {
		return errors.New("another native transition is pending")
	}
	if old == nil || old.identity() != link.identity() {
		if s.record.Enrollment != link.Source {
			return errors.New("native source supervision changed")
		}
	} else if s.record.Enrollment != link.Source && s.record.Enrollment != link.Target {
		return errors.New("native supervision owner changed")
	}
	step := func(name string) error {
		if deps.after != nil {
			return deps.after(name)
		}
		return nil
	}
	// Link first: a crash at any later point gates evaluation at construction.
	if old == nil || old.identity() != link.identity() {
		pending := link
		s.record.NativeTransition = &pending
		s.record.Generation++
		s.record.NextEvaluationMS = 0
		s.record.Fingerprint = ""
		s.record.Decision = nil
		s.record.Preparation = nil
		if s.record.Enabled {
			s.record.State = "native_finalization_pending"
		}
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			return err
		}
	}
	if err := step("supervisor_pending"); err != nil {
		return err
	}
	if err := writeHostNativeFinalizationPhase(workerDirectory, input, link, "host_finalization_requested"); err != nil {
		return err
	}
	if err := step("intent"); err != nil {
		return err
	}
	if s.record.Enrollment != link.Target {
		s.record.Enrollment = link.Target
		s.record.Generation++
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			return err
		}
	}
	if err := step("supervisor_target"); err != nil {
		return err
	}
	if err := writeHostNativeFinalizationPhase(workerDirectory, input, link, "host_finalized"); err != nil {
		return err
	}
	if err := step("completion"); err != nil {
		return err
	}
	if err := finishHostNativeFinalizationFence(workerDirectory, link); err != nil {
		return err
	}
	if err := step("fence_removed"); err != nil {
		return err
	}
	if err := s.completeNativeTransitionLocked(link); err != nil {
		return err
	}
	if err := step("supervisor_complete"); err != nil {
		return err
	}
	s.notify()
	return nil
}
func nativeHostRotationFinalizer(workerDirectory string) func(context.Context, *hostRotationSupervisor) error {
	return func(ctx context.Context, s *hostRotationSupervisor) error {
		r := s.snapshot()
		if r.NativeAbortTransition != nil && !r.NativeAbortTransition.Finalized {
			return finalizeHostNativeRefusal(ctx, s, workerDirectory, r.NativeAbortTransition.Source.SessionID,
				hostNativeAbortFinalizationDependencies{hostNativeAbortDependencies: hostNativeAbortDependencies{owner: verifyHostNativeRefusalOwner, ledger: callHostNativeLedger}})
		}
		if r.NativeTransition == nil || r.NativeTransition.Finalized {
			return nil
		}
		return finalizeHostNativeCompletion(ctx, s, workerDirectory, r.NativeTransition.Source.SessionID,
			hostNativeFinalizationDependencies{hostNativeRegistrationDependencies: hostNativeRegistrationDependencies{
				binding: readHostNativeRegistrationBinding, ledger: callHostNativeLedger,
			}})
	}
}

// Called ahead of normal enabled/timer checks. Pending cleanup cannot evaluate
// either source or target, and it remains recoverable while disabled.
func (s *hostRotationSupervisor) recoverNativeTransition() bool {
	r := s.snapshot()
	if (r.NativeTransition == nil || r.NativeTransition.Finalized) &&
		(r.NativeAbortTransition == nil || r.NativeAbortTransition.Finalized) {
		return false
	}
	if s.finalizeNative == nil {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s.mu.Lock()
	select {
	case <-s.done:
		s.mu.Unlock()
		return true
	default:
	}
	s.cancel = cancel
	s.mu.Unlock()
	err := s.finalizeNative(ctx, s)
	s.mu.Lock()
	s.cancel = nil
	state := ""
	if err != nil {
		state = "finalization_unavailable"
	}
	if s.record.NativeRecoveryState != state {
		s.record.NativeRecoveryState = state
		if s.saveLocked() != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
		}
	}
	s.mu.Unlock()
	return true
}
