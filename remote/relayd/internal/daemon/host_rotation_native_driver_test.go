package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Reset only fixture-created downstream phases, leaving the actual claim,
// intent, original handoff and four native journal records as the driver input.
func nativeDriverFixture(t *testing.T) (*nativeRetirementHarness, *hostRotationSupervisor, *hostNativeTransactionDriver, *int) {
	t.Helper()
	h := nativeRetirementFixture(t)
	for _, phase := range []string{"native_restored_verified", "registration_requested", "registration_received", "ledger_ack_requested", "ledger_ack_received"} {
		if err := os.Remove(h.phasePath(phase)); err != nil {
			t.Fatal(err)
		}
	}
	h.registered = nil
	h.ack = nil
	h.nativeRegistrationHarness.calls = 0
	h.nativeAckHarness.calls = 0
	s := &hostRotationSupervisor{path: filepath.Join(h.host.dir, "rotation-supervision", "fixture.json"),
		record: hostRotationRecord{Version: 1, OperationID: strings.Repeat("1", 32), Operation: "enroll",
			Enrollment: h.host.source.Enrollment, Enabled: true, State: "preparation_prepared", Generation: 10},
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}), updated: make(chan struct{}, 1)}
	if err := s.saveLocked(); err != nil {
		t.Fatal(err)
	}
	observations := 0
	d := &hostNativeTransactionDriver{directory: h.host.dir, deps: hostNativeDriverDependencies{
		hostNativeRetirementDependencies: h.deps,
		acquire: func(context.Context, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverClaim, error) {
			t.Fatal("recovery attempted a new claim")
			return nil, errors.New("forbidden")
		},
		observe: func(ctx context.Context, e hostRotationEnrollment, op, claim string) (nativeRotationReply, error) {
			if ctx.Err() != nil {
				return nativeRotationReply{}, ctx.Err()
			}
			observations++
			if e != h.host.source.Enrollment || op != h.claim.request.Epoch || claim != h.claim.request.HostClaimID {
				t.Fatal("changed observation identity")
			}
			return nativeRotationReply{Version: 1, State: "restored", OperationID: op, HostClaimID: claim, Completion: &h.receipt}, nil
		},
	}}
	return h, s, d, &observations
}

func TestHostNativeDriverCompletesDurableStages(t *testing.T) {
	for _, mode := range []string{"enabled", "disabled", "human_takeover"} {
		t.Run(mode, func(t *testing.T) {
			h, s, d, observations := nativeDriverFixture(t)
			if mode != "enabled" {
				s.record.Enabled = false
				s.record.State = mode
			}
			r, err := d.recover(context.Background(), s)
			if err != nil || r.Pending {
				t.Fatal("driver incomplete", r, err)
			}
			saved := s.snapshot()
			if saved.NativeTransition == nil || !saved.NativeTransition.Finalized || saved.Enrollment.SessionID != h.receipt.TargetThreadID {
				t.Fatal("target was not finalized")
			}
			if saved.Enabled != (mode == "enabled") || mode != "enabled" && saved.State != mode {
				t.Fatal("human control changed")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("source fence remains", err)
			}
			if *observations != 1 || h.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
				t.Fatal("wrong stage counts")
			}
			if r, err = d.recover(context.Background(), s); err != nil || r.Pending {
				t.Fatal("completed recovery", r, err)
			}
			if *observations != 1 || h.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
				t.Fatal("completed stages repeated")
			}
		})
	}
}

func TestHostNativeDriverResumesEveryDurableCompletionStage(t *testing.T) {
	for _, stage := range []string{"verified", "registration", "ack", "retirement"} {
		t.Run(stage, func(t *testing.T) {
			h, s, d, observations := nativeDriverFixture(t)
			ctx := context.Background()
			if _, err := h.record(ctx, h.verify); err != nil {
				t.Fatal(err)
			}
			if stage != "verified" {
				if _, err := registerHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.receipt, h.deps.hostNativeRegistrationDependencies); err != nil {
					t.Fatal(err)
				}
			}
			if stage == "ack" || stage == "retirement" {
				if _, err := acknowledgeHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.deps.hostNativeRegistrationDependencies); err != nil {
					t.Fatal(err)
				}
			}
			if stage == "retirement" {
				if _, err := h.run(); err != nil {
					t.Fatal(err)
				}
			}
			r, err := d.recover(ctx, s)
			if err != nil || r.Pending {
				t.Fatal("durable stage did not resume", r, err)
			}
			if *observations != 0 {
				t.Fatal("durable restoration unnecessarily queried native bridge")
			}
			if h.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
				t.Fatal("durable action replayed")
			}
		})
	}
}

func TestHostNativeDriverRetainsPendingAndConflictingEvidence(t *testing.T) {
	for _, mode := range []string{"pending", "source_retained", "wrong_id", "wrong_source", "partial_proof", "missing_handoff", "source_changed", "owner_changed", "disconnected"} {
		t.Run(mode, func(t *testing.T) {
			h, s, d, observations := nativeDriverFixture(t)
			observe := d.deps.observe
			switch mode {
			case "partial_proof":
				if err := os.WriteFile(h.proofPath(), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "missing_handoff":
				if err := os.Remove(h.phasePath("native_handoff_requested")); err != nil {
					t.Fatal(err)
				}
			case "source_changed":
				s.record.Enrollment.AgentStart++
			case "owner_changed":
				d.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					return "", errors.New("owner changed")
				}
			default:
				d.deps.observe = func(ctx context.Context, e hostRotationEnrollment, op, claim string) (nativeRotationReply, error) {
					reply, err := observe(ctx, e, op, claim)
					if err != nil {
						return reply, err
					}
					switch mode {
					case "pending":
						reply.State = "pending"
						reply.Completion = nil
					case "source_retained":
						reply.State = "source_retained"
						source := h.receipt.Source
						reply.Source = &source
						reply.Completion = nil
					case "wrong_id":
						reply.OperationID = claim
					case "wrong_source":
						copy := h.receipt
						copy.Source.AdmissionGeneration++
						reply.Completion = &copy
					case "disconnected":
						return nativeRotationReply{}, errors.New("disconnected")
					}
					return reply, nil
				}
			}
			r, err := d.recover(context.Background(), s)
			if !r.Pending {
				t.Fatal("unresolved transaction accepted", r, err)
			}
			if mode != "pending" && mode != "source_retained" && err == nil {
				t.Fatal("conflict not reported")
			}
			if h.calls != 0 || h.nativeAckHarness.calls != 0 || h.nativeRegistrationHarness.calls != 0 {
				t.Fatal("unverified mutation")
			}
			if mode == "partial_proof" || mode == "missing_handoff" || mode == "source_changed" {
				if *observations != 0 {
					t.Fatal("invalid local evidence queried native")
				}
			}
			if s.snapshot().NativeTransition != nil {
				t.Fatal("unverified supervisor transition")
			}
			h.unchangedFence(t)
		})
	}
}

func TestHostNativeDriverRetirementRetryUsesDurableCompletion(t *testing.T) {
	h, s, d, observations := nativeDriverFixture(t)
	h.mutation = "pending"
	r, err := d.recover(context.Background(), s)
	if err == nil || !r.Pending || r.State != "native_retirement_pending" {
		t.Fatal("pending native retirement accepted", r, err)
	}
	h.mutation = ""
	r, err = d.recover(context.Background(), s)
	if err != nil || r.Pending {
		t.Fatal("retirement did not resume", r, err)
	}
	if *observations != 1 || h.calls != 2 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
		t.Fatal("retry repeated wrong stages")
	}
}

type nativeDriverClaimDouble struct {
	intentCalls, submitCalls, releaseCalls int
	intentError, submitError               error
	reply                                  nativeRotationReply
}

func (c *nativeDriverClaimDouble) requestCommitIntent(context.Context) (hostNativeIntentReceipt, error) {
	c.intentCalls++
	return hostNativeIntentReceipt{}, c.intentError
}
func (c *nativeDriverClaimDouble) submitNativeCommit(context.Context) (nativeRotationReply, error) {
	c.submitCalls++
	return c.reply, c.submitError
}
func (c *nativeDriverClaimDouble) release(context.Context) error { c.releaseCalls++; return nil }

func TestHostNativeDriverPreparedSequenceAndFailures(t *testing.T) {
	for _, mode := range []string{"cancelled", "guard", "claim", "intent", "submit", "pending", "restored"} {
		t.Run(mode, func(t *testing.T) {
			h, s, d, observations := nativeDriverFixture(t)
			claim := &nativeDriverClaimDouble{reply: nativeRotationReply{Version: 1, State: "restored",
				OperationID: h.receipt.OperationID, HostClaimID: h.receipt.HostClaimID, Completion: &h.receipt}}
			claims := 0
			d.deps.acquire = func(_ context.Context, e hostRotationEnrollment, p hostRotationPreparation, g func() error) (hostNativeDriverClaim, error) {
				claims++
				if e != h.host.source.Enrollment || p.Capsule == nil || *p.Capsule != *h.host.prepared.Capsule {
					t.Fatal("preparation identity changed")
				}
				if mode == "claim" {
					return nil, errors.New("claim unavailable")
				}
				return claim, nil
			}
			if mode == "intent" {
				claim.intentError = errors.New("intent unavailable")
			}
			if mode == "submit" {
				claim.submitError = errors.New("handoff uncertain")
			}
			if mode == "pending" {
				claim.reply.State = "pending"
				claim.reply.Completion = nil
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "cancelled" {
				cancel()
			}
			guard := func() error {
				if mode == "guard" {
					return errors.New("generation changed")
				}
				return nil
			}
			r, err := d.start(ctx, s, h.host.source.Enrollment, h.host.prepared, guard)
			if mode == "restored" {
				if err != nil || r.Pending {
					t.Fatal("prepared rotation incomplete", r, err)
				}
			} else if !r.Pending {
				t.Fatal("failure accepted", mode, r)
			}
			if mode != "restored" && mode != "pending" && err == nil {
				t.Fatal("failure missing")
			}
			wantClaims := 1
			if mode == "cancelled" || mode == "guard" {
				wantClaims = 0
			}
			if claims != wantClaims {
				t.Fatal("unexpected claim count", claims)
			}
			if mode == "intent" && (claim.releaseCalls != 1 || claim.submitCalls != 0) {
				t.Fatal("intent failure was resubmitted")
			}
			if mode == "submit" && (claim.releaseCalls != 0 || claim.submitCalls != 1) {
				t.Fatal("uncertain native commit released/replayed")
			}
			if (mode == "pending" || mode == "restored") && (claim.intentCalls != 1 || claim.submitCalls != 1 || claim.releaseCalls != 0) {
				t.Fatal("wrong prepared stage order")
			}
			if *observations != 0 {
				t.Fatal("initial submit was replaced with observation")
			}
		})
	}
}

func TestHostNativeDriverRecoversFinalizationAfterFenceRemoval(t *testing.T) {
	h := nativeFinalizationFixture(t)
	h.deps.after = func(stage string) error {
		if stage == "fence_removed" {
			return errors.New("crash")
		}
		return nil
	}
	if h.run() == nil {
		t.Fatal("missing crash")
	}
	d := &hostNativeTransactionDriver{directory: h.host.dir, deps: hostNativeDriverDependencies{
		hostNativeRetirementDependencies: h.nativeRetirementHarness.deps}}
	d.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
		t.Fatal("historical recovery required live owner")
		return "", nil
	}
	d.deps.ledger = func(context.Context, string, any) (json.RawMessage, error) {
		t.Fatal("historical recovery called ledger")
		return nil, nil
	}
	r, err := d.recover(context.Background(), h.supervisor)
	if err != nil || r.Pending || !h.supervisor.snapshot().NativeTransition.Finalized {
		t.Fatal("historical recovery incomplete", r, err)
	}
}
