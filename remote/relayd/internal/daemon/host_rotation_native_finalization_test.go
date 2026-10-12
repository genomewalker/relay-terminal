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

type nativeFinalizationHarness struct {
	*nativeRetirementHarness
	supervisor *hostRotationSupervisor
	deps       hostNativeFinalizationDependencies
}

func nativeFinalizationFixture(t *testing.T) *nativeFinalizationHarness {
	t.Helper()
	h := &nativeFinalizationHarness{nativeRetirementHarness: nativeRetirementFixture(t)}
	if _, err := h.nativeRetirementHarness.run(); err != nil {
		t.Fatal(err)
	}
	h.supervisor = &hostRotationSupervisor{
		path: filepath.Join(h.host.dir, "rotation-supervision", "fixture.json"),
		record: hostRotationRecord{Version: 1, OperationID: strings.Repeat("1", 32), Operation: "enroll",
			Enrollment: h.host.source.Enrollment, Enabled: true, State: "preparation_prepared", Generation: 10},
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}), updated: make(chan struct{}, 1),
	}
	if err := h.supervisor.saveLocked(); err != nil {
		t.Fatal(err)
	}
	h.deps.hostNativeRegistrationDependencies = h.nativeRetirementHarness.deps.hostNativeRegistrationDependencies
	return h
}
func (h *nativeFinalizationHarness) run() error {
	return finalizeHostNativeCompletion(context.Background(), h.supervisor, h.host.dir, h.claim.request.SessionID, h.deps)
}
func (h *nativeFinalizationHarness) activePath() string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")
}
func (h *nativeFinalizationHarness) assertFinal(t *testing.T, enabled bool) {
	t.Helper()
	r := h.supervisor.snapshot()
	if r.NativeTransition == nil || !r.NativeTransition.Finalized || !r.NativeTransition.valid() ||
		r.Enrollment != r.NativeTransition.Target || r.Enrollment.SessionID != h.receipt.TargetThreadID || r.Enabled != enabled {
		t.Fatal("supervisor did not complete exact target transition", r)
	}
	if _, err := os.Stat(h.activePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("old source fence remains", err)
	}
	raw, err := os.ReadFile(h.phasePath("host_finalized"))
	if err != nil || !hostNativeRegistrationExactShape(raw, hostNativeFinalizationPhase(*r.NativeTransition, "host_finalized")) {
		t.Fatal("finalization not durable")
	}
}
func TestHostNativeFinalizationCompletesTargetAndIsDescriptive(t *testing.T) {
	h := nativeFinalizationFixture(t)
	if err := h.run(); err != nil {
		t.Fatal(err)
	}
	h.assertFinal(t, true)
	before := h.supervisor.snapshot()
	h.deps.hostNativeRegistrationDependencies = hostNativeRegistrationDependencies{}
	if err := h.run(); err != nil {
		t.Fatal("completed finalization needed native authority", err)
	}
	after := h.supervisor.snapshot()
	if after.Generation != before.Generation || after.OperationID != before.OperationID {
		t.Fatal("repeat mutated supervisor")
	}
	clone := h.supervisor.snapshot()
	clone.NativeTransition.Source.SessionID = "changed"
	if h.supervisor.snapshot().NativeTransition.Source.SessionID != h.claim.request.SessionID {
		t.Fatal("snapshot aliases transition")
	}
	if h.nativeRetirementHarness.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
		t.Fatal("finalization replayed external work")
	}
}
func TestHostNativeFinalizationRecoversEveryDurableBoundary(t *testing.T) {
	for _, stage := range []string{"supervisor_pending", "intent", "supervisor_target", "completion", "fence_removed", "supervisor_complete"} {
		t.Run(stage, func(t *testing.T) {
			h := nativeFinalizationFixture(t)
			h.deps.after = func(at string) error {
				if at == stage {
					return errors.New("simulated process loss")
				}
				return nil
			}
			if err := h.run(); err == nil {
				t.Fatal("fault did not interrupt")
			}
			var evaluations atomic.Int32
			evaluate := func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
				if e.SessionID != h.receipt.TargetThreadID {
					t.Error("source evaluated during finalization")
				}
				if _, err := os.Stat(h.activePath()); !errors.Is(err, os.ErrNotExist) {
					t.Error("target evaluated before source fence cleanup")
				}
				evaluations.Add(1)
				return json.RawMessage("{\"v\":1,\"decision\":\"hold\"}"), nil
			}
			deps := h.deps
			deps.after = nil
			if stage == "completion" || stage == "fence_removed" {
				deps.hostNativeRegistrationDependencies = hostNativeRegistrationDependencies{}
			}
			resumed := newHostRotationSupervisorWithFinalizer(h.supervisor.path, evaluate,
				func(ctx context.Context, s *hostRotationSupervisor) error {
					return finalizeHostNativeCompletion(ctx, s, h.host.dir, h.claim.request.SessionID, deps)
				})
			defer resumed.close()
			h.supervisor = resumed
			awaitHostRotation(t, resumed, func(r hostRotationRecord) bool {
				return r.NativeTransition != nil && r.NativeTransition.Finalized && r.State == "evaluated"
			})
			h.assertFinal(t, true)
			if evaluations.Load() != 1 {
				t.Fatal("unexpected evaluations", evaluations.Load())
			}
			if h.nativeRetirementHarness.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
				t.Fatal("restart repeated external mutation")
			}
		})
	}
}
func TestHostNativeFinalizationPreservesDisableAndHumanTakeover(t *testing.T) {
	for _, mode := range []string{"disabled", "human_takeover"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeFinalizationFixture(t)
			h.deps.after = func(stage string) error {
				if stage == "supervisor_target" {
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
			if err := h.supervisor.configure(hostRotationRequest{Operation: "enroll", ID: strings.Repeat("3", 32)}, h.host.source.Enrollment); err == nil {
				t.Fatal("pending transition re-enrolled")
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
					return finalizeHostNativeCompletion(ctx, s, h.host.dir, h.claim.request.SessionID, deps)
				})
			defer resumed.close()
			h.supervisor = resumed
			r := awaitHostRotation(t, resumed, func(r hostRotationRecord) bool { return r.NativeTransition != nil && r.NativeTransition.Finalized })
			if r.State != mode || r.Enabled || evaluations.Load() != 0 {
				t.Fatal("takeover was lost", r.State, r.Enabled, evaluations.Load())
			}
			h.assertFinal(t, false)
		})
	}
}
func TestHostNativeFinalizationWithoutRecoveryDoesNotEvaluate(t *testing.T) {
	h := nativeFinalizationFixture(t)
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
		t.Fatal("pending transition evaluated")
	case <-time.After(50 * time.Millisecond):
	}
	r := resumed.snapshot()
	if r.NativeTransition == nil || r.NativeTransition.Finalized {
		t.Fatal("pending transition lost")
	}
}
func TestHostNativeFinalizationRefusesUnverifiedInitialEvidence(t *testing.T) {
	for _, name := range []string{"missing_retired", "partial_retired", "partial_intent", "partial_complete", "owner", "ledger", "supervisor_owner", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			h := nativeFinalizationFixture(t)
			switch name {
			case "missing_retired":
				if err := os.Remove(h.phasePath("native_retired")); err != nil {
					t.Fatal(err)
				}
			case "partial_retired":
				if err := os.WriteFile(h.phasePath("native_retired"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "partial_intent":
				writeNativeCompletionJSON(t, h.phasePath("host_finalization_requested"), map[string]any{})
			case "partial_complete":
				writeNativeCompletionJSON(t, h.phasePath("host_finalized"), map[string]any{})
			case "owner":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					return "", errors.New("changed")
				}
			case "ledger":
				h.nativeAckHarness.mutation = "claim_open"
			case "supervisor_owner":
				h.supervisor.record.Enrollment.SessionID = "00000000-0000-0000-0000-000000000999"
			case "cancelled":
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				if finalizeHostNativeCompletion(ctx, h.supervisor, h.host.dir, h.claim.request.SessionID, h.deps) == nil {
					t.Fatal("cancelled")
				}
				if _, err := os.Stat(h.activePath()); err != nil {
					t.Fatal("fence removed")
				}
				return
			}
			if err := h.run(); err == nil {
				t.Fatal("unverified finalization accepted")
			}
			if h.supervisor.snapshot().NativeTransition != nil {
				t.Fatal("unverified supervisor transition recorded")
			}
			if _, err := os.Stat(h.activePath()); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeFinalizationNeverRemovesChangedFenceOrProof(t *testing.T) {
	for _, name := range []string{"other_active", "changed_retired", "changed_request", "changed_intent", "changed_complete", "changed_supervisor"} {
		t.Run(name, func(t *testing.T) {
			h := nativeFinalizationFixture(t)
			h.deps.after = func(stage string) error {
				if stage == "completion" {
					return errors.New("pause")
				}
				return nil
			}
			if h.run() == nil {
				t.Fatal("pause")
			}
			switch name {
			case "other_active":
				raw, _ := os.ReadFile(h.activePath())
				var active hostNativeClaimActive
				if json.Unmarshal(raw, &active) != nil {
					t.Fatal("active")
				}
				active.OperationID = "00000000-0000-0000-0000-000000000999"
				writeNativeCompletionJSON(t, h.activePath(), active)
			case "changed_retired":
				writeNativeCompletionJSON(t, h.phasePath("native_retired"), map[string]any{})
			case "changed_request":
				writeNativeCompletionJSON(t, h.phasePath("request"), map[string]any{})
			case "changed_intent":
				writeNativeCompletionJSON(t, h.phasePath("host_finalization_requested"), map[string]any{})
			case "changed_complete":
				writeNativeCompletionJSON(t, h.phasePath("host_finalized"), map[string]any{})
			case "changed_supervisor":
				h.supervisor.record.Enrollment.SessionID = "00000000-0000-0000-0000-000000000999"
			}
			h.deps.after = nil
			if h.run() == nil {
				t.Fatal("changed finalization accepted")
			}
			if _, err := os.Stat(h.activePath()); err != nil {
				t.Fatal("conflicting fence removed")
			}
			if h.supervisor.snapshot().NativeTransition.Finalized {
				t.Fatal("conflict marked complete")
			}
		})
	}
}
