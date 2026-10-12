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

type nativeSupervisorDriverDouble struct {
	begin  func(context.Context, *hostRotationSupervisor, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverResult, error)
	resume func(context.Context, *hostRotationSupervisor) (hostNativeDriverResult, error)
}

func (d *nativeSupervisorDriverDouble) start(ctx context.Context, s *hostRotationSupervisor, e hostRotationEnrollment, p hostRotationPreparation, g func() error) (hostNativeDriverResult, error) {
	if d.begin == nil {
		return hostNativeDriverPending("unexpected_start", errors.New("unexpected start"))
	}
	return d.begin(ctx, s, e, p, g)
}
func (d *nativeSupervisorDriverDouble) recover(ctx context.Context, s *hostRotationSupervisor) (hostNativeDriverResult, error) {
	if d.resume == nil {
		return hostNativeDriverPending("unexpected_recovery", errors.New("unexpected recovery"))
	}
	return d.resume(ctx, s)
}
func awaitNativeSupervisorIntegration(t *testing.T, s *hostRotationSupervisor, predicate func(hostRotationRecord) bool) hostRotationRecord {
	t.Helper()
	deadline := time.NewTimer(15 * time.Second)
	defer deadline.Stop()
	for {
		record := s.snapshot()
		if predicate(record) {
			return record
		}
		select {
		case <-s.updated:
		case <-deadline.C:
			t.Fatalf("native supervisor did not reach expected state: %+v", s.snapshot())
		}
	}
}
func nativeSupervisorIntegrationPath(t *testing.T, h *nativeClaimHarness) string {
	t.Helper()
	path := filepath.Join(h.dir, "rotation-supervision", "fixture.json")
	saved := &hostRotationSupervisor{path: path, record: hostRotationRecord{Version: 1,
		OperationID: strings.Repeat("1", 32), Operation: "enroll", Enrollment: h.source.Enrollment,
		Enabled: true, State: "pending_evaluation", Generation: 1}, updated: make(chan struct{}, 1)}
	if err := saved.saveLocked(); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestHostNativeSupervisorAutomaticPreparedRotation(t *testing.T) {
	h, original, d, observations := nativeDriverFixture(t)
	active := filepath.Join(h.host.dir, hostNativeClaimDirectory)
	staged := filepath.Join(h.host.dir, "fixture-claim-awaiting-acquisition")
	if err := os.Rename(active, staged); err != nil {
		t.Fatal(err)
	}
	var acquisitions, preparations, sourceEvaluations, targetEvaluations atomic.Int32
	claim := &nativeDriverClaimDouble{reply: nativeRotationReply{Version: 1, State: "restored",
		OperationID: h.receipt.OperationID, HostClaimID: h.receipt.HostClaimID, Completion: &h.receipt}}
	d.deps.acquire = func(ctx context.Context, e hostRotationEnrollment, p hostRotationPreparation, guard func() error) (hostNativeDriverClaim, error) {
		acquisitions.Add(1)
		if ctx.Err() != nil || guard() != nil || e != h.host.source.Enrollment || p.Capsule == nil {
			t.Fatal("automatic preparation lost admission")
		}
		if err := os.Rename(staged, active); err != nil {
			t.Fatal(err)
		}
		return claim, nil
	}
	evaluate := func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
		if e.SessionID == h.receipt.TargetThreadID {
			targetEvaluations.Add(1)
			return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
		}
		sourceEvaluations.Add(1)
		return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
	}
	prepare := func(_ context.Context, e hostRotationEnrollment, g func() error, _ func(hostRotationPreparation) error) hostRotationPreparation {
		preparations.Add(1)
		if e != h.host.source.Enrollment || g() != nil {
			t.Fatal("automatic preparation source changed")
		}
		return h.host.prepared
	}
	s := newHostRotationSupervisorWithDriver(original.path, evaluate, nil, h.host.dir, d, prepare)
	defer s.close()
	r := awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool {
		return r.NativeTransition != nil && r.NativeTransition.Finalized && r.Enrollment.SessionID == h.receipt.TargetThreadID && r.State == "evaluated"
	})
	if !r.Enabled || r.Preparation != nil || r.NativeRecoveryState != "" {
		t.Fatal("source preparation leaked into target")
	}
	if acquisitions.Load() != 1 || preparations.Load() != 1 || sourceEvaluations.Load() != 1 || targetEvaluations.Load() != 1 {
		t.Fatal("automatic rotation did not execute once")
	}
	if claim.intentCalls != 1 || claim.submitCalls != 1 || claim.releaseCalls != 0 || *observations != 0 {
		t.Fatal("wrong original claim sequence")
	}
	if h.calls != 1 || h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
		t.Fatal("downstream actions repeated")
	}
}

func TestHostNativeSupervisorAutomaticAdmissionFailureDoesNotRedraft(t *testing.T) {
	h := newNativeClaimHarness(t)
	path := nativeSupervisorIntegrationPath(t, h)
	var preparations, starts, evaluations atomic.Int32
	d := &nativeSupervisorDriverDouble{begin: func(context.Context, *hostRotationSupervisor, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverResult, error) {
		starts.Add(1)
		return hostNativeDriverPending("native_claim_pending", errors.New("foreground unavailable"))
	}}
	s := newHostRotationSupervisorWithDriver(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		evaluations.Add(1)
		return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
	}, nil, h.dir, d, func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation {
		preparations.Add(1)
		return h.prepared
	})
	defer s.close()
	awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool { return r.State == "native_attempt_unavailable" })
	for i := 0; i < 3; i++ {
		s.notify()
	}
	// The barrier is a synchronous inspection; it must not arm a new evaluation.
	if s.gateNativeJournal() {
		t.Fatal("failed admission manufactured a journal")
	}
	if evaluations.Load() != 1 || preparations.Load() != 1 || starts.Load() != 1 {
		t.Fatal("unavailable admission redrafted")
	}
}

func TestHostNativeSupervisorDriverKeepsGenerationCancellation(t *testing.T) {
	for _, mode := range []string{"disable", "human", "activity", "close"} {
		t.Run(mode, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			path := nativeSupervisorIntegrationPath(t, h)
			started := make(chan struct{}, 1)
			cancelled := make(chan struct{}, 1)
			var starts atomic.Int32
			d := &nativeSupervisorDriverDouble{begin: func(ctx context.Context, _ *hostRotationSupervisor, _ hostRotationEnrollment, _ hostRotationPreparation, g func() error) (hostNativeDriverResult, error) {
				starts.Add(1)
				started <- struct{}{}
				<-ctx.Done()
				if g() == nil {
					t.Error("cancelled driver retained admission")
				}
				cancelled <- struct{}{}
				return hostNativeDriverPending("native_handoff_pending", ctx.Err())
			}}
			s := newHostRotationSupervisorWithDriver(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
				return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
			}, nil, h.dir, d, func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation {
				return h.prepared
			})
			defer s.close()
			select {
			case <-started:
			case <-time.After(3 * time.Second):
				t.Fatal("automatic driver did not start")
			}
			switch mode {
			case "disable":
				if err := s.configure(hostRotationRequest{Operation: "disable", ID: strings.Repeat("2", 32)}, hostRotationEnrollment{}); err != nil {
					t.Fatal(err)
				}
			case "human":
				s.humanInput()
			case "activity":
				s.event([]byte("{}"), true)
			case "close":
				s.close()
			}
			select {
			case <-cancelled:
			case <-time.After(time.Second):
				t.Fatal("driver did not cancel")
			}
			if mode != "close" {
				expected := map[string]string{"disable": "disabled", "human": "human_takeover", "activity": "awaiting_completed_turn"}[mode]
				r := awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool { return r.State == expected })
				if mode != "activity" && r.Enabled {
					t.Fatal("takeover re-enabled")
				}
			}
			if starts.Load() != 1 {
				t.Fatal("cancelled start repeated")
			}
		})
	}
}

func TestHostNativeSupervisorDriverRecoversBeforeEvaluation(t *testing.T) {
	for _, mode := range []string{"enabled", "disabled", "human_takeover"} {
		t.Run(mode, func(t *testing.T) {
			h, original, d, observations := nativeDriverFixture(t)
			if mode != "enabled" {
				original.record.Enabled = false
				original.record.State = mode
				if err := original.saveLocked(); err != nil {
					t.Fatal(err)
				}
			}
			var evaluations, preparations atomic.Int32
			s := newHostRotationSupervisorWithDriver(original.path, func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
				if e.SessionID != h.receipt.TargetThreadID {
					t.Error("unresolved source evaluated")
				}
				evaluations.Add(1)
				return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
			}, nil, h.host.dir, d, func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation {
				preparations.Add(1)
				return h.host.prepared
			})
			defer s.close()
			r := awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool {
				return r.NativeTransition != nil && r.NativeTransition.Finalized && (mode != "enabled" || r.State == "evaluated")
			})
			if mode != "enabled" && (r.Enabled || r.State != mode || evaluations.Load() != 0) {
				t.Fatal("disabled recovery resumed work")
			}
			if mode == "enabled" && evaluations.Load() != 1 {
				t.Fatal("target not evaluated once")
			}
			if preparations.Load() != 0 || *observations != 1 || h.calls != 1 {
				t.Fatal("recovery redrafted or replayed")
			}
		})
	}
}

func TestHostNativeSupervisorDriverPendingRecoveryWakeAndCancel(t *testing.T) {
	for _, mode := range []string{"wake", "disable", "human", "close"} {
		t.Run(mode, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			if _, err := h.acquire(context.Background()); err != nil {
				t.Fatal(err)
			}
			path := nativeSupervisorIntegrationPath(t, h)
			called := make(chan int32, 4)
			cancelled := make(chan struct{}, 4)
			var recoveries, evaluations atomic.Int32
			d := &nativeSupervisorDriverDouble{resume: func(ctx context.Context, _ *hostRotationSupervisor) (hostNativeDriverResult, error) {
				count := recoveries.Add(1)
				called <- count
				if mode == "wake" {
					return hostNativeDriverPending("fixture_pending", errors.New("pending"))
				}
				<-ctx.Done()
				cancelled <- struct{}{}
				return hostNativeDriverPending("fixture_pending", ctx.Err())
			}}
			s := newHostRotationSupervisorWithDriver(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
				evaluations.Add(1)
				return nil, errors.New("unexpected evaluation")
			}, nil, h.dir, d)
			defer s.close()
			select {
			case <-called:
			case <-time.After(3 * time.Second):
				t.Fatal("recovery did not start")
			}
			switch mode {
			case "wake":
				awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool { return r.NativeRecoveryState == "fixture_pending" })
				session := &Session{hostRotation: s}
				session.notifyNativeRotationRecovery()
				select {
				case n := <-called:
					if n != 2 {
						t.Fatal("unexpected recovery count", n)
					}
				case <-time.After(time.Second):
					t.Fatal("bridge wake waited for retry timer")
				}
			case "disable":
				if err := s.configure(hostRotationRequest{Operation: "disable", ID: strings.Repeat("2", 32)}, hostRotationEnrollment{}); err != nil {
					t.Fatal(err)
				}
			case "human":
				s.humanInput()
			case "close":
				s.close()
			}
			if mode != "wake" {
				select {
				case <-cancelled:
				case <-time.After(time.Second):
					t.Fatal("recovery did not cancel")
				}
			}
			if evaluations.Load() != 0 {
				t.Fatal("pending recovery evaluated")
			}
		})
	}
}

func TestHostNativeSupervisorDriverRecoversLinkedFinalizationWithoutFence(t *testing.T) {
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
	d := &hostNativeTransactionDriver{directory: h.host.dir, deps: hostNativeDriverDependencies{hostNativeRetirementDependencies: h.nativeRetirementHarness.deps}}
	d.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
		t.Error("historical owner query")
		return "", errors.New("unavailable")
	}
	d.deps.ledger = func(context.Context, string, any) (json.RawMessage, error) {
		t.Error("historical ledger query")
		return nil, errors.New("unavailable")
	}
	s := newHostRotationSupervisorWithDriver(h.supervisor.path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
	}, nil, h.host.dir, d)
	defer s.close()
	awaitNativeSupervisorIntegration(t, s, func(r hostRotationRecord) bool {
		return r.NativeTransition != nil && r.NativeTransition.Finalized && r.State == "evaluated"
	})
}

func TestHostNativeSupervisorDriverRequiresDurablePreparedState(t *testing.T) {
	h := newNativeClaimHarness(t)
	obstruction := filepath.Join(h.dir, "not-a-directory")
	if err := os.WriteFile(obstruction, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	d := &nativeSupervisorDriverDouble{begin: func(context.Context, *hostRotationSupervisor, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverResult, error) {
		starts.Add(1)
		return hostNativeDriverResult{}, nil
	}}
	s := &hostRotationSupervisor{path: filepath.Join(obstruction, "state.json"), nativeDriver: d,
		record: hostRotationRecord{Enrollment: h.source.Enrollment, Enabled: true, Generation: 1},
		done:   make(chan struct{}), prepare: func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation {
			return h.prepared
		}}
	s.prepareCurrent(1, h.source.Enrollment)
	if starts.Load() != 0 || s.snapshot().Enabled || s.snapshot().State != "persistence_failed" {
		t.Fatal("driver bypassed failed persistence")
	}
}
