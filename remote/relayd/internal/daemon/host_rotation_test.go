package daemon

import (
	"bytes"
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

func hostRotationFixture() hostRotationEnrollment {
	return hostRotationEnrollment{SessionID: "root-session", Client: "claude", CWD: "/work",
		PaneID: "fixture-pane", AgentPID: 200, AgentStart: 201, WorkerPID: 100, WorkerStart: 101, NodeBootID: "fixture-boot"}
}

func hostRotationTestDecision(fingerprint string, next *int64, pass int32) json.RawMessage {
	value, _ := json.Marshal(map[string]any{"v": 1, "decision": "hold", "pass": pass,
		"schedule": map[string]any{"fingerprint": fingerprint, "next_evaluation_ms": next}})
	return value
}

func awaitHostRotation(t *testing.T, s *hostRotationSupervisor, predicate func(hostRotationRecord) bool) hostRotationRecord {
	t.Helper()
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for {
		r := s.snapshot()
		if predicate(r) {
			return r
		}
		select {
		case <-s.updated:
		case <-timer.C:
			t.Fatalf("host rotation did not reach expected state: %+v", s.snapshot())
		}
	}
}

func enrollHostRotation(t *testing.T, s *hostRotationSupervisor) {
	t.Helper()
	if err := s.configure(hostRotationRequest{Operation: "enroll", ID: "11111111111111111111111111111111"},
		hostRotationFixture()); err != nil {
		t.Fatal(err)
	}
}

func TestHostRotationDeadlinesRunWithoutUIAndStop(t *testing.T) {
	var calls atomic.Int32
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	fingerprint := string(bytes.Repeat([]byte("a"), 64))
	evaluate := func(_ context.Context, _ hostRotationEnrollment, now time.Time) (json.RawMessage, error) {
		n := calls.Add(1)
		var next *int64
		if n < 3 {
			v := now.Add(150 * time.Millisecond).UnixMilli()
			next = &v
		}
		return hostRotationTestDecision(fingerprint, next, n), nil
	}
	s := newHostRotationSupervisor(path, evaluate)
	defer s.close()
	enrollHostRotation(t, s)
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool {
		var d struct {
			Pass int32 `json:"pass"`
		}
		_ = json.Unmarshal(r.Decision, &d)
		return d.Pass == 3 && r.NextEvaluationMS == 0
	})
	if calls.Load() != 3 || r.Lifecycle != "unavailable" || r.RefreshCapability != "unverified" {
		t.Fatalf("unexpected completion: %d %+v", calls.Load(), r)
	}
	data, err := privatePromptEditorBytes(path, 262144)
	if err != nil {
		t.Fatal(err)
	}
	var persisted hostRotationRecord
	if json.Unmarshal(data, &persisted) != nil || persisted.NextEvaluationMS != 0 || persisted.Generation != r.Generation {
		t.Fatalf("deadline was not durably exhausted: %s", data)
	}
	// An exhausted policy has no recurring wakeup.
	select {
	case <-s.updated:
	default:
	}
	select {
	case <-s.updated:
		t.Fatal("unexpected recurring evaluation")
	case <-time.After(200 * time.Millisecond):
	}
}

func TestHostRotationStaleFingerprintCancelsDeadline(t *testing.T) {
	var calls atomic.Int32
	s := newHostRotationSupervisor(filepath.Join(t.TempDir(), "rotation", "state.json"),
		func(_ context.Context, _ hostRotationEnrollment, now time.Time) (json.RawMessage, error) {
			n := calls.Add(1)
			char := byte('a')
			if n > 1 {
				char = 'b'
			}
			next := now.Add(150 * time.Millisecond).UnixMilli()
			return hostRotationTestDecision(string(bytes.Repeat([]byte{char}, 64)), &next, n), nil
		})
	defer s.close()
	enrollHostRotation(t, s)
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "stale_deadline_cancelled" })
	if calls.Load() != 2 || r.NextEvaluationMS != 0 || len(r.Decision) != 0 {
		t.Fatalf("stale timer accepted: %+v", r)
	}
}

func TestHostRotationHumanInputCancelsEvaluationAndPersists(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	s := newHostRotationSupervisor(path, func(ctx context.Context, _ hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	defer s.close()
	enrollHostRotation(t, s)
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("evaluation never started")
	}
	sink, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	session := &Session{pty: sink, hostRotation: s}
	if err := session.input([]byte("human draft")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("evaluation was not cancelled")
	}
	r := s.snapshot()
	if r.Enabled || r.State != "human_takeover" || r.NextEvaluationMS != 0 {
		t.Fatalf("takeover failed: %+v", r)
	}
	s.event([]byte(`{"agent":"claude","event":{"hook_event_name":"Stop","session_id":"root-session"}}`), true)
	if s.snapshot().Enabled {
		t.Fatal("agent completion re-enabled human-owned session")
	}
	data, err := privatePromptEditorBytes(path, 262144)
	if err != nil {
		t.Fatal(err)
	}
	var saved hostRotationRecord
	if json.Unmarshal(data, &saved) != nil || saved.Enabled || saved.State != "human_takeover" {
		t.Fatal("takeover not durable")
	}
}

func TestHostRotationRestartsRevalidateAndDoNotReplayDeadline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	first := newHostRotationSupervisor(path, func(_ context.Context, _ hostRotationEnrollment, now time.Time) (json.RawMessage, error) {
		next := now.Add(time.Hour).UnixMilli()
		return hostRotationTestDecision(string(bytes.Repeat([]byte("a"), 64)), &next, 1), nil
	})
	enrollHostRotation(t, first)
	awaitHostRotation(t, first, func(r hostRotationRecord) bool { return r.NextEvaluationMS > 0 })
	first.close()
	var calls atomic.Int32
	recovered := newHostRotationSupervisor(path, func(_ context.Context, _ hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
		calls.Add(1)
		return nil, errors.New("provider incarnation changed")
	})
	defer recovered.close()
	r := awaitHostRotation(t, recovered, func(r hostRotationRecord) bool { return r.State == "evaluation_unavailable" })
	if calls.Load() != 1 || r.NextEvaluationMS != 0 || r.Fingerprint != "" || len(r.Decision) != 0 {
		t.Fatalf("stale restart accepted: %+v", r)
	}
}

func TestHostRotationReloadPreservesPausedEnrollmentAndAdvancesEpoch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	saved := hostRotationRecord{Version: 1, OperationID: "11111111111111111111111111111111",
		Enrollment: hostRotationFixture(), State: "human_takeover", Enabled: false, Generation: 2,
		NextEvaluationMS: time.Now().Add(time.Hour).UnixMilli(), Fingerprint: strings.Repeat("a", 64),
		Decision: json.RawMessage(`{"decision":"hold"}`), Lifecycle: "quiet", RefreshCapability: "verified"}
	data, err := json.Marshal(saved)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	supervisor := newHostRotationSupervisor(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		calls.Add(1)
		return nil, errors.New("paused enrollment must not evaluate")
	})
	defer supervisor.close()
	r := supervisor.snapshot()
	if r.Enrollment != saved.Enrollment || r.Enabled || r.State != saved.State || r.Generation != saved.Generation+1 ||
		r.NextEvaluationMS != 0 || r.Fingerprint != "" || len(r.Decision) != 0 || r.Preparation != nil ||
		r.Lifecycle != "unavailable" || r.RefreshCapability != "unverified" || calls.Load() != 0 {
		t.Fatalf("paused reload violated the epoch fence: %+v", r)
	}
}

func TestHostRotationEventBindingAndOperationIdentity(t *testing.T) {
	e := hostRotationFixture()
	for _, raw := range []string{
		`{"agent":"claude","event":{"hook_event_name":"Stop","session_id":"other"}}`,
		`{"agent":"claude","event":{"hook_event_name":"Stop","session_id":"root-session","parent_session_id":"parent"}}`,
		`{"agent":"codex","event":{"hook_event_name":"Stop","session_id":"root-session"}}`,
		`{"agent":"claude","event":{"hook_event_name":"UserPromptSubmit","session_id":"root-session"}}`,
	} {
		if hostRotationCompletedEvent([]byte(raw), e) {
			t.Fatalf("unbound boundary accepted: %s", raw)
		}
	}
	if !hostRotationCompletedEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"Stop","session_id":"root-session"}}`), e) {
		t.Fatal("completed root turn missed")
	}
	codex := e
	codex.Client = "codex"
	if !hostRotationCompletedEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"turn/completed","thread_id":"root-session"}}`), codex) {
		t.Fatal("normalized native Codex completion missed")
	}
	s := newHostRotationSupervisor(filepath.Join(t.TempDir(), "rotation", "state.json"),
		func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
			return nil, errors.New("unavailable")
		})
	defer s.close()
	enrollHostRotation(t, s)
	if err := s.configure(hostRotationRequest{Operation: "disable", ID: "11111111111111111111111111111111"}, hostRotationEnrollment{}); err == nil {
		t.Fatal("operation ID was reused for a different action")
	}
	s.event([]byte("{}"), false)
	if r := s.snapshot(); r.Enabled || r.State != "event_journal_failed" {
		t.Fatalf("journal failure accepted: %+v", r)
	}
}

func TestHostRotationCoalescesRepeatedActivityButPersistsFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	supervisor := newHostRotationSupervisor(path,
		func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
			return hostRotationTestDecision("", nil, 1), nil
		})
	defer supervisor.close()
	enrollHostRotation(t, supervisor)
	awaitHostRotation(t, supervisor, func(r hostRotationRecord) bool { return r.State == "evaluated" })
	activity := []byte(`{"agent":"claude","event":{"hook_event_name":"PreToolUse","session_id":"root-session"}}`)
	supervisor.event(activity, true)
	first := supervisor.snapshot()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 1000; i++ {
		supervisor.event(activity, true)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) || supervisor.snapshot().Generation != first.Generation {
		t.Fatal("redundant activity rewrote durable invalidation", err)
	}
	supervisor.event(activity, false)
	failed := supervisor.snapshot()
	if failed.Enabled || failed.State != "event_journal_failed" || failed.Generation == first.Generation {
		t.Fatal("journal failure was coalesced")
	}
	data, err := os.ReadFile(path)
	if err != nil || !bytes.Contains(data, []byte("event_journal_failed")) {
		t.Fatal("journal failure not durable", err)
	}
}
