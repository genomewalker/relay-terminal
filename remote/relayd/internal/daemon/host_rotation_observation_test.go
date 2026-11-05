package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func observationTestSupervisor(t *testing.T) (*hostRotationSupervisor, string, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	s := newHostRotationSupervisor(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		calls.Add(1)
		return nil, nil
	})
	t.Cleanup(s.close)
	return s, path, &calls
}

// journaledRotationSession is a worker session with a real event journal, so
// events take the same canonicalize → filter → journal → supervisor path as
// `relayd event` hook deliveries in a pane.
func journaledRotationSession(t *testing.T, s *hostRotationSupervisor) (*Session, string) {
	t.Helper()
	journal := filepath.Join(t.TempDir(), "events.jsonl")
	session := &Session{hostRotation: s}
	if err := session.enableEventJournal(journal); err != nil {
		t.Fatal(err)
	}
	return session, journal
}

// deliverHook sends provider input exactly as `relayd event --agent <provider>` does.
func deliverHook(t *testing.T, session *Session, provider, source, raw string) {
	t.Helper()
	envelope, err := CanonicalAgentEnvelope(provider, []byte(raw), source)
	if err != nil {
		t.Fatalf("canonicalize %s: %v", raw, err)
	}
	session.agentEvent(envelope)
}

func TestHostRotationObservesRootCompletionsThroughEventPath(t *testing.T) {
	s, path, calls := observationTestSupervisor(t)
	session, journal := journaledRotationSession(t, s)
	deliverHook(t, session, "claude", "hook", `{"hook_event_name":"Stop","session_id":"claude-session",
		"transcript_path":"/private/transcript.jsonl","cwd":"/work","last_assistant_message":"private answer"}`)
	deliverHook(t, session, "codex", "hook", `{"hook_event_name":"Stop","session_id":"codex-thread",
		"turn_id":"turn-1","transcript_path":"/private/rollout.jsonl","last_assistant_message":"private answer"}`)
	deliverHook(t, session, "codex", "codex-app-server", `{"method":"turn/completed",
		"params":{"threadId":"codex-thread","turn":{"id":"turn-2","status":"completed"}}}`)

	status := s.status()
	if status.CompletedTurns != 3 || status.LastCompletedAgent != "codex" || status.LastCompletedAt == nil {
		t.Fatalf("root completions not observed: %+v", status.hostRotationObservation)
	}
	// Observation explains status only; it never enrolls or evaluates.
	if status.Enabled || status.State != "not_enrolled" || calls.Load() != 0 {
		t.Fatalf("observation changed supervision: %+v calls=%d", status.hostRotationRecord, calls.Load())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("observation persisted a record for an unenrolled pane")
	}
	// The journal keeps the conversation identity, so replayed events can
	// still be matched, and still drops provider content.
	data, err := os.ReadFile(journal)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"session_id":"claude-session"`)) ||
		!bytes.Contains(data, []byte(`"session_id":"codex-thread"`)) {
		t.Fatalf("journal lost session identity: %s", data)
	}
	for _, private := range []string{"transcript_path", "last_assistant_message", "private answer", "cwd"} {
		if bytes.Contains(data, []byte(private)) {
			t.Fatalf("journal kept provider content %q: %s", private, data)
		}
	}
}

func TestHostRotationObservationSkipsSubagentAndUnidentifiedCompletions(t *testing.T) {
	s, _, _ := observationTestSupervisor(t)
	session, _ := journaledRotationSession(t, s)
	for _, hook := range []struct{ provider, source, raw string }{
		{"claude", "hook", `{"hook_event_name":"Stop","session_id":"child","parent_session_id":"root"}`},
		{"claude", "hook", `{"hook_event_name":"SubagentStop","session_id":"root","agent_id":"a1"}`},
		{"claude", "hook", `{"hook_event_name":"PreToolUse","session_id":"root","tool_name":"Bash"}`},
		// Older clients stripped session_id; such a Stop can never be evaluated.
		{"claude", "hook", `{"hook_event_name":"Stop"}`},
		{"codex", "codex-app-server", `{"method":"turn/completed","params":{"turn":{"id":"t"}}}`},
		{"codex", "codex-app-server", `{"method":"turn/started","params":{"threadId":"thread"}}`},
	} {
		deliverHook(t, session, hook.provider, hook.source, hook.raw)
	}
	// An event the journal could not record never counts.
	s.event([]byte(`{"agent":"claude","event":{"hook_event_name":"Stop","session_id":"root"}}`), false)
	if status := s.status(); status.CompletedTurns != 0 || status.LastCompletedAt != nil {
		t.Fatalf("subagent or unidentified completion observed: %+v", status.hostRotationObservation)
	}
}

// Regression: session_id used to be dropped by both copyAgentMetadata and the
// journal filter, so an enrolled pane never matched a Stop and never evaluated.
func TestHostRotationEnrolledPaneEvaluatesAfterRealStopHook(t *testing.T) {
	var calls atomic.Int32
	fingerprint := strings.Repeat("a", 64)
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	s := newHostRotationSupervisor(path, func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		return hostRotationTestDecision(fingerprint, nil, calls.Add(1)), nil
	})
	defer s.close()
	enrollHostRotation(t, s) // enrolls Claude session "root-session"
	awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "evaluated" })
	session, _ := journaledRotationSession(t, s)

	// Another conversation's Stop and a subagent Stop are activity, not completions.
	deliverHook(t, session, "claude", "hook", `{"hook_event_name":"Stop","session_id":"other-session"}`)
	deliverHook(t, session, "claude", "hook", `{"hook_event_name":"Stop","session_id":"child","parent_session_id":"root-session"}`)
	awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "awaiting_completed_turn" })
	time.Sleep(100 * time.Millisecond)
	if n := calls.Load(); n != 1 {
		t.Fatalf("non-root or foreign Stop started an evaluation: calls=%d", n)
	}

	deliverHook(t, session, "claude", "hook", `{"hook_event_name":"Stop","session_id":"root-session",
		"transcript_path":"/private/transcript.jsonl"}`)
	awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "evaluated" })
	if n := calls.Load(); n != 2 {
		t.Fatalf("root Stop did not start exactly one evaluation: calls=%d", n)
	}
}

func TestHostRotationStatusReplyFlattensObservation(t *testing.T) {
	s, _, _ := observationTestSupervisor(t)
	s.event([]byte(`{"agent":"codex","event":{"hook_event_name":"turn/completed","thread_id":"t"}}`), true)
	encoded, err := json.Marshal(s.status())
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if json.Unmarshal(encoded, &fields) != nil {
		t.Fatal("status did not encode as one object")
	}
	if fields["v"] != float64(1) || fields["state"] != "not_enrolled" || fields["enabled"] != false ||
		fields["observed_completed_turns"] != float64(1) || fields["last_completed_turn_agent"] != "codex" ||
		fields["last_completed_turn_at"] == nil {
		t.Fatalf("unexpected status fields: %s", encoded)
	}
	// The record a status reply embeds is unchanged for older readers.
	var record hostRotationRecord
	if err := json.Unmarshal(encoded, &record); err != nil || record.State != "not_enrolled" || record.Version != 1 {
		t.Fatalf("record shape changed: %+v %v", record, err)
	}
}
