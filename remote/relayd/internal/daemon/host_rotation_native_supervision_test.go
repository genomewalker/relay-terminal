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

func TestHostNativeSupervisorJournalGate(t *testing.T) {
	for _, mode := range []string{"clean", "claim", "commit", "missing_request", "partial_active", "missing_lock", "source", "symlink_root", "missing_worker", "invalid_source"} {
		t.Run(mode, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			e := h.source.Enrollment
			want := "claim_pending"
			if mode != "clean" && mode != "symlink_root" && mode != "missing_worker" && mode != "invalid_source" {
				if _, err := h.acquire(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			root := filepath.Join(h.dir, hostNativeClaimDirectory)
			switch mode {
			case "clean":
				want = ""
			case "commit":
				if err := os.WriteFile(filepath.Join(root, h.request.Epoch+".commit_requested.json"), []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
				want = "commit_pending"
			case "missing_request":
				if err := os.Remove(filepath.Join(root, h.request.Epoch+".request.json")); err != nil {
					t.Fatal(err)
				}
				want = "journal_unavailable"
			case "partial_active":
				if err := os.WriteFile(filepath.Join(root, e.SessionID+".active.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
				want = "journal_unavailable"
			case "missing_lock":
				if err := os.Remove(filepath.Join(root, "lock")); err != nil {
					t.Fatal(err)
				}
				want = "journal_unavailable"
			case "source":
				e.AgentStart++
				want = "source_mismatch"
			case "symlink_root":
				if err := os.Symlink(t.TempDir(), root); err != nil {
					t.Fatal(err)
				}
				want = "journal_unavailable"
			case "missing_worker":
				h.dir = filepath.Join(h.dir, "missing")
				want = "journal_unavailable"
			case "invalid_source":
				e.SessionID = "../source"
				want = "invalid_source"
			}
			claims, releases := h.claimCalls, h.releaseCalls
			if got := inspectHostNativeSupervisorJournal(h.dir, e); got != want {
				t.Fatalf("got %q want %q", got, want)
			}
			if h.claimCalls != claims || h.releaseCalls != releases {
				t.Fatal("inspection mutated ledger")
			}
		})
	}
}

func TestHostNativeSupervisorRestartGatesUnlinkedTransaction(t *testing.T) {
	for _, mode := range []string{"enabled", "disabled", "human_takeover"} {
		t.Run(mode, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			claim, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(h.dir, "rotation-supervision", "fixture.json")
			state := mode
			if mode == "enabled" {
				state = "preparation_prepared"
			}
			saved := &hostRotationSupervisor{path: path, record: hostRotationRecord{Version: 1,
				OperationID: strings.Repeat("1", 32), Operation: "enroll", Enrollment: h.source.Enrollment,
				Enabled: mode == "enabled", State: state}, updated: make(chan struct{}, 1)}
			if err := saved.saveLocked(); err != nil {
				t.Fatal(err)
			}
			var evaluations atomic.Int32
			s := newHostRotationSupervisorWithNativeJournal(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
				evaluations.Add(1)
				return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
			}, nil, h.dir)
			defer s.close()
			r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.NativeRecoveryState == "claim_pending" })
			if evaluations.Load() != 0 || r.NativeTransition != nil || r.NextEvaluationMS != 0 || r.Preparation != nil {
				t.Fatal("pending source evaluated")
			}
			if mode != "enabled" && (r.Enabled || r.State != mode) {
				t.Fatal("disable state changed")
			}
			other := h.source.Enrollment
			other.SessionID = "00000000-0000-0000-0000-000000000999"
			if s.configure(hostRotationRequest{Operation: "enroll", ID: strings.Repeat("2", 32)}, other) == nil {
				t.Fatal("pending source replaced")
			}
			if err := claim.release(context.Background()); err != nil {
				t.Fatal(err)
			}
			s.notify()
			r = awaitHostRotation(t, s, func(r hostRotationRecord) bool {
				return r.NativeRecoveryState == "" && (mode != "enabled" || r.State == "evaluated")
			})
			if mode == "enabled" && evaluations.Load() != 1 {
				t.Fatal("source did not resume once")
			}
			if mode != "enabled" && (r.Enabled || r.State != mode || evaluations.Load() != 0) {
				t.Fatal("disabled source resumed")
			}
		})
	}
}

func TestHostNativeSupervisorRejectsEnrollmentIntoPendingJournal(t *testing.T) {
	h := newNativeClaimHarness(t)
	if _, err := h.acquire(context.Background()); err != nil {
		t.Fatal(err)
	}
	s := newHostRotationSupervisorWithNativeJournal(filepath.Join(h.dir, "rotation-supervision", "fixture.json"), nil, nil, h.dir)
	defer s.close()
	if s.configure(hostRotationRequest{Operation: "enroll", ID: strings.Repeat("1", 32)}, h.source.Enrollment) == nil {
		t.Fatal("pending source enrolled")
	}
	if s.snapshot().Enabled {
		t.Fatal("refused enrollment enabled")
	}
}

func TestHostNativeSupervisorRecoveryCancellation(t *testing.T) {
	for _, mode := range []string{"close", "disable", "human"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeFinalizationFixture(t)
			h.deps.after = func(stage string) error {
				if stage == "supervisor_pending" {
					return errors.New("pause")
				}
				return nil
			}
			if h.run() == nil {
				t.Fatal("missing pause")
			}
			started := make(chan struct{}, 1)
			cancelled := make(chan struct{}, 1)
			s := newHostRotationSupervisorWithFinalizer(h.supervisor.path, nil, func(ctx context.Context, _ *hostRotationSupervisor) error {
				select {
				case started <- struct{}{}:
				default:
				}
				<-ctx.Done()
				select {
				case cancelled <- struct{}{}:
				default:
				}
				return ctx.Err()
			})
			defer s.close()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("recovery did not start")
			}
			switch mode {
			case "close":
				s.close()
			case "disable":
				if err := s.configure(hostRotationRequest{Operation: "disable", ID: strings.Repeat("2", 32)}, hostRotationEnrollment{}); err != nil {
					t.Fatal(err)
				}
			case "human":
				s.humanInput()
			}
			select {
			case <-cancelled:
			case <-time.After(time.Second):
				t.Fatal("recovery was not cancelled")
			}
			if mode != "close" && s.snapshot().Enabled {
				t.Fatal("takeover lost")
			}
		})
	}
}
