package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type nativeAbortFinalizationHarness struct {
	*nativeAbortRetirementHarness
	supervisor *hostRotationSupervisor
	deps       hostNativeAbortFinalizationDependencies
}

func nativeAbortFinalizationFixture(t *testing.T) *nativeAbortFinalizationHarness {
	t.Helper()
	h := &nativeAbortFinalizationHarness{nativeAbortRetirementHarness: nativeAbortRetirementFixture(t)}
	if _, err := h.nativeAbortRetirementHarness.run(); err != nil {
		t.Fatal(err)
	}
	h.supervisor = &hostRotationSupervisor{path: filepath.Join(h.host.dir, "rotation-supervision", "fixture.json"),
		record: hostRotationRecord{Version: 1, OperationID: strings.Repeat("1", 32), Operation: "enroll", Enrollment: h.host.source.Enrollment,
			Enabled: true, State: "preparation_prepared", Generation: 10},
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}), updated: make(chan struct{}, 1)}
	if err := h.supervisor.saveLocked(); err != nil {
		t.Fatal(err)
	}
	h.deps.hostNativeAbortDependencies = h.nativeAbortHarness.deps
	return h
}
func (h *nativeAbortFinalizationHarness) run() error {
	return finalizeHostNativeRefusal(context.Background(), h.supervisor, h.host.dir, h.claim.request.SessionID, h.deps)
}
func (h *nativeAbortFinalizationHarness) activePath() string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")
}
func (h *nativeAbortFinalizationHarness) assertFinal(t *testing.T, enabled bool) {
	t.Helper()
	r := h.supervisor.snapshot()
	if r.NativeAbortTransition == nil || !r.NativeAbortTransition.Finalized || !r.NativeAbortTransition.valid() ||
		r.Enrollment != h.host.source.Enrollment || r.Enabled != enabled || r.NativeTransition != nil {
		t.Fatal("source abort finalization changed enrollment or control", r)
	}
	if _, err := os.Stat(h.activePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("source fence remains", err)
	}
	raw, err := os.ReadFile(h.phase("host_abort_finalized"))
	if err != nil || !hostNativeRegistrationExactShape(raw, hostNativeAbortFinalizationPhase(*r.NativeAbortTransition, "host_abort_finalized")) {
		t.Fatal("source finalization not durable", err)
	}
	if h.retireCalls != 1 || h.calls != 1 {
		t.Fatal("finalization repeated external work")
	}
}
func TestHostNativeAbortFinalizationKeepsSourceAndIsDescriptive(t *testing.T) {
	h := nativeAbortFinalizationFixture(t)
	if err := h.run(); err != nil {
		t.Fatal(err)
	}
	h.assertFinal(t, true)
	before := h.supervisor.snapshot()
	h.deps.hostNativeAbortDependencies = hostNativeAbortDependencies{}
	if err := h.run(); err != nil {
		t.Fatal("completed finalization needed provider", err)
	}
	if h.supervisor.snapshot().Generation != before.Generation {
		t.Fatal("repeat changed supervisor")
	}
	clone := h.supervisor.snapshot()
	clone.NativeAbortTransition.Source.SessionID = "changed"
	if h.supervisor.snapshot().NativeAbortTransition.Source.SessionID != h.claim.request.SessionID {
		t.Fatal("snapshot aliases transition")
	}
}
func TestHostNativeAbortFinalizationRecoversEveryDurableBoundary(t *testing.T) {
	for _, stage := range []string{"supervisor_pending", "intent", "completion", "fence_removed", "supervisor_complete"} {
		t.Run(stage, func(t *testing.T) {
			h := nativeAbortFinalizationFixture(t)
			h.deps.after = func(at string) error {
				if at == stage {
					return errors.New("simulated process loss")
				}
				return nil
			}
			if h.run() == nil {
				t.Fatal("fault did not interrupt")
			}
			var evaluations atomic.Int32
			deps := h.deps
			deps.after = nil
			if stage == "completion" || stage == "fence_removed" {
				deps.hostNativeAbortDependencies = hostNativeAbortDependencies{}
			}
			resumed := newHostRotationSupervisorWithFinalizer(h.supervisor.path,
				func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
					if e != h.host.source.Enrollment {
						t.Error("another source evaluated")
					}
					if _, err := os.Stat(h.activePath()); !errors.Is(err, os.ErrNotExist) {
						t.Error("source evaluated before fence cleanup")
					}
					evaluations.Add(1)
					return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
				},
				func(ctx context.Context, s *hostRotationSupervisor) error {
					return finalizeHostNativeRefusal(ctx, s, h.host.dir, h.claim.request.SessionID, deps)
				})
			defer resumed.close()
			h.supervisor = resumed
			awaitHostRotation(t, resumed, func(r hostRotationRecord) bool {
				return r.NativeAbortTransition != nil && r.NativeAbortTransition.Finalized && r.State == "native_refused"
			})
			h.assertFinal(t, true)
			if evaluations.Load() != 0 {
				t.Fatal("unexpected evaluations", evaluations.Load())
			}
		})
	}
}
func TestHostNativeAbortFinalizationPreservesHumanControl(t *testing.T) {
	for _, mode := range []string{"disabled", "human_takeover"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortFinalizationFixture(t)
			h.deps.after = func(stage string) error {
				if stage == "intent" {
					return errors.New("pause")
				}
				return nil
			}
			if h.run() == nil {
				t.Fatal("pause")
			}
			if mode == "disabled" {
				if err := h.supervisor.configure(hostRotationRequest{Operation: "disable", ID: strings.Repeat("2", 32)}, hostRotationEnrollment{}); err != nil {
					t.Fatal(err)
				}
			} else {
				h.supervisor.humanInput()
			}
			before := h.supervisor.snapshot()
			if err := h.supervisor.configure(hostRotationRequest{Operation: "enroll", ID: strings.Repeat("3", 32)}, h.host.source.Enrollment); err == nil {
				t.Fatal("pending abort re-enrolled")
			}
			var evaluations atomic.Int32
			deps := h.deps
			deps.after = nil
			resumed := newHostRotationSupervisorWithFinalizer(h.supervisor.path,
				func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
					evaluations.Add(1)
					return nil, errors.New("must not evaluate")
				},
				func(ctx context.Context, s *hostRotationSupervisor) error {
					return finalizeHostNativeRefusal(ctx, s, h.host.dir, h.claim.request.SessionID, deps)
				})
			defer resumed.close()
			h.supervisor = resumed
			r := awaitHostRotation(t, resumed, func(r hostRotationRecord) bool {
				return r.NativeAbortTransition != nil && r.NativeAbortTransition.Finalized
			})
			if r.Enabled || r.State != mode || r.OperationID != before.OperationID || r.Operation != before.Operation || evaluations.Load() != 0 {
				t.Fatal("human control lost", r)
			}
			h.assertFinal(t, false)
		})
	}
}
func TestHostNativeAbortFinalizationWithoutRecoveryNeverEvaluates(t *testing.T) {
	h := nativeAbortFinalizationFixture(t)
	h.deps.after = func(stage string) error {
		if stage == "supervisor_pending" {
			return errors.New("pause")
		}
		return nil
	}
	if h.run() == nil {
		t.Fatal("pause")
	}
	evaluated := make(chan struct{}, 1)
	resumed := newHostRotationSupervisor(h.supervisor.path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		evaluated <- struct{}{}
		return nil, errors.New("must not evaluate")
	})
	defer resumed.close()
	select {
	case <-evaluated:
		t.Fatal("pending abort evaluated")
	case <-time.After(50 * time.Millisecond):
	}
	r := resumed.snapshot()
	if r.NativeAbortTransition == nil || r.NativeAbortTransition.Finalized {
		t.Fatal("pending abort lost")
	}
}
func TestHostNativeAbortFinalizationRequiresVerifiedRetirement(t *testing.T) {
	for _, mode := range []string{"missing_retired", "missing_ack", "partial_retired", "partial_intent", "partial_complete", "owner", "ledger", "supervisor_owner", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortFinalizationFixture(t)
			ctx := context.Background()
			switch mode {
			case "missing_retired":
				if err := os.Remove(h.phase("native_abort_retired")); err != nil {
					t.Fatal(err)
				}
			case "missing_ack":
				if err := os.Remove(h.phase("native_abort_ack_requested")); err != nil {
					t.Fatal(err)
				}
			case "partial_retired":
				if err := os.WriteFile(h.phase("native_abort_retired"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "partial_intent":
				writeNativeCompletionJSON(t, h.phase("host_abort_finalization_requested"), map[string]any{})
			case "partial_complete":
				writeNativeCompletionJSON(t, h.phase("host_abort_finalized"), map[string]any{})
			case "owner":
				h.deps.owner = func(hostRotationEnrollment, hostNativeRefusalRecord) error { return errors.New("owner changed") }
			case "ledger":
				h.nativeAbortHarness.mutation = "claim_open"
			case "supervisor_owner":
				h.supervisor.record.Enrollment.SessionID = "00000000-0000-0000-0000-000000000999"
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if err := finalizeHostNativeRefusal(ctx, h.supervisor, h.host.dir, h.claim.request.SessionID, h.deps); err == nil {
				t.Fatal("unverified abort finalized")
			}
			if h.supervisor.snapshot().NativeAbortTransition != nil {
				t.Fatal("unverified supervisor link")
			}
			if _, err := os.Stat(h.activePath()); err != nil {
				t.Fatal("source fence removed")
			}
		})
	}
}
func TestHostNativeAbortFinalizationNeverRemovesNewerFenceOrChangedHistory(t *testing.T) {
	for _, mode := range []string{"other_active", "retired", "ack", "request", "intent", "completion", "supervisor"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortFinalizationFixture(t)
			h.deps.after = func(stage string) error {
				if stage == "completion" {
					return errors.New("pause")
				}
				return nil
			}
			if h.run() == nil {
				t.Fatal("pause")
			}
			switch mode {
			case "other_active":
				raw, _ := os.ReadFile(h.activePath())
				var a hostNativeClaimActive
				if json.Unmarshal(raw, &a) != nil {
					t.Fatal("fixture")
				}
				a.OperationID = "00000000-0000-0000-0000-000000000999"
				writeNativeCompletionJSON(t, h.activePath(), a)
			case "retired":
				writeNativeCompletionJSON(t, h.phase("native_abort_retired"), map[string]any{})
			case "ack":
				writeNativeCompletionJSON(t, h.phase("native_abort_ack_requested"), map[string]any{})
			case "request":
				writeNativeCompletionJSON(t, h.phase("request"), map[string]any{})
			case "intent":
				writeNativeCompletionJSON(t, h.phase("host_abort_finalization_requested"), map[string]any{})
			case "completion":
				writeNativeCompletionJSON(t, h.phase("host_abort_finalized"), map[string]any{})
			case "supervisor":
				h.supervisor.record.Enrollment.SessionID = "00000000-0000-0000-0000-000000000999"
			}
			h.deps.after = nil
			h.deps.hostNativeAbortDependencies = hostNativeAbortDependencies{}
			if h.run() == nil {
				t.Fatal("changed history finalized")
			}
			if _, err := os.Stat(h.activePath()); err != nil {
				t.Fatal("conflicting fence removed")
			}
			if h.supervisor.snapshot().NativeAbortTransition.Finalized {
				t.Fatal("conflict marked complete")
			}
		})
	}
}
func TestHostNativeAbortDriverCompletesRefusalWithoutCommitReplay(t *testing.T) {
	for _, mode := range []string{"enabled", "disabled", "human_takeover", "observation"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortFinalizationFixture(t)
			// Preserve the claim/intent/handoff/refusal, remove only fixture-created
			// downstream receipts so production recovery drives the entire stage.
			for _, phase := range []string{"ledger_abort_requested", "ledger_abort_received", "native_abort_ack_requested", "native_abort_retired"} {
				if err := os.Remove(h.phase(phase)); err != nil {
					t.Fatal(err)
				}
			}
			h.aborted = nil
			h.calls = 0
			h.retireCalls = 0
			h.retired = false
			if mode == "disabled" || mode == "human_takeover" {
				h.supervisor.record.Enabled = false
				h.supervisor.record.State = mode
			}
			d := &hostNativeTransactionDriver{directory: h.host.dir, deps: hostNativeDriverDependencies{
				hostNativeRetirementDependencies: hostNativeRetirementDependencies{hostNativeRegistrationDependencies: hostNativeRegistrationDependencies{ledger: h.nativeAbortHarness.deps.ledger}},
				refusalOwner:                     h.owner, retireRefusal: h.depsRetire(),
				acquire: func(context.Context, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverClaim, error) {
					t.Fatal("recovery claimed")
					return nil, errors.New("forbidden")
				},
				observe: func(context.Context, hostRotationEnrollment, string, string) (nativeRotationReply, error) {
					t.Fatal("durable refusal re-observed")
					return nativeRotationReply{}, errors.New("forbidden")
				},
			}}
			var result hostNativeDriverResult
			var err error
			if mode == "observation" {
				reply := nativeRotationReply{Version: 1, State: "source_retained", OperationID: h.claim.request.Epoch, HostClaimID: h.claim.request.HostClaimID, Source: &h.receipt.Source, JournalDirectory: h.path}
				result, err = d.completeObservation(context.Background(), h.supervisor, h.host.source.Enrollment, reply)
			} else {
				result, err = d.recover(context.Background(), h.supervisor)
			}
			if err != nil || result.Pending {
				t.Fatal("source recovery incomplete", result, err)
			}
			h.assertFinal(t, mode == "enabled" || mode == "observation")
			if mode == "disabled" || mode == "human_takeover" {
				if h.supervisor.snapshot().State != mode {
					t.Fatal("human state changed")
				}
			}
		})
	}
}
func (h *nativeAbortFinalizationHarness) depsRetire() func(context.Context, hostRotationEnrollment, hostNativeRefusalRecord) (nativeRotationReply, error) {
	return h.nativeAbortRetirementHarness.deps.retire
}
func TestHostNativeAbortDriverRecoversAfterFenceRemovalWithoutProvider(t *testing.T) {
	h := nativeAbortFinalizationFixture(t)
	h.deps.after = func(stage string) error {
		if stage == "fence_removed" {
			return errors.New("pause")
		}
		return nil
	}
	if h.run() == nil {
		t.Fatal("pause")
	}
	d := &hostNativeTransactionDriver{directory: h.host.dir}
	r, err := d.recover(context.Background(), h.supervisor)
	if err != nil || r.Pending {
		t.Fatal("historical cleanup needed provider", r, err)
	}
	h.assertFinal(t, true)
}

func TestHostNativeAbortFinalizationDoesNotReevaluateRefusedTurnOnRestart(t *testing.T) {
	h := nativeAbortFinalizationFixture(t)
	if err := h.run(); err != nil {
		t.Fatal(err)
	}
	var evaluations atomic.Int32
	resumed := newHostRotationSupervisor(h.supervisor.path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		evaluations.Add(1)
		return nil, errors.New("must wait for another completed turn")
	})
	defer resumed.close()
	if r := resumed.snapshot(); !r.Enabled || r.State != "native_refused" || r.NextEvaluationMS != 0 {
		t.Fatal("restart armed refused turn", r)
	}
	select {
	case <-resumed.updated:
	case <-time.After(50 * time.Millisecond):
	}
	if evaluations.Load() != 0 {
		t.Fatal("refused turn reevaluated")
	}
	h.supervisor = resumed
	h.assertFinal(t, true)
}
func TestHostNativeAbortDriverRequiresNewTurnOrExplicitReenrollment(t *testing.T) {
	h := nativeAbortFinalizationFixture(t)
	if err := h.run(); err != nil {
		t.Fatal(err)
	}
	acquired := 0
	d := &hostNativeTransactionDriver{directory: h.host.dir, deps: hostNativeDriverDependencies{
		acquire: func(context.Context, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverClaim, error) {
			acquired++
			return nil, errors.New("fixture admission boundary")
		},
	}}
	p := hostRotationPreparation{State: "prepared", Capsule: &h.claim.request.Capsule, TurnID: h.claim.request.Source.TurnID, TurnSeq: h.claim.request.Source.TurnSeq}
	for _, mutation := range []string{"same", "new_id_old_seq", "same_id_new_seq"} {
		q := p
		if mutation == "new_id_old_seq" {
			q.TurnID = "new-turn"
		}
		if mutation == "same_id_new_seq" {
			q.TurnSeq++
		}
		result, err := d.start(context.Background(), h.supervisor, h.host.source.Enrollment, q, func() error { return nil })
		if err == nil || result.State != "native_retry_requires_new_turn" || acquired != 0 {
			t.Fatal("refused turn reacquired", mutation, result, err)
		}
	}
	fresh := p
	fresh.TurnID = "new-turn"
	fresh.TurnSeq++
	result, _ := d.start(context.Background(), h.supervisor, h.host.source.Enrollment, fresh, func() error { return nil })
	if acquired != 1 || result.State != "native_claim_pending" {
		t.Fatal("fresh turn was not admitted")
	}
	if err := h.supervisor.configure(hostRotationRequest{Operation: "enroll", ID: strings.Repeat("4", 32)}, h.host.source.Enrollment); err != nil {
		t.Fatal(err)
	}
	if h.supervisor.snapshot().NativeAbortTransition != nil {
		t.Fatal("explicit enrollment did not arm fresh admission")
	}
	result, _ = d.start(context.Background(), h.supervisor, h.host.source.Enrollment, p, func() error { return nil })
	if acquired != 2 || result.State != "native_claim_pending" {
		t.Fatal("explicit retry was not admitted")
	}
	if _, err := os.Stat(h.phase("host_abort_finalized")); err != nil {
		t.Fatal("explicit enrollment lost durable history")
	}
}
