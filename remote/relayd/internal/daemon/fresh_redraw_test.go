package daemon

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type freshRedrawFrames struct {
	states []string
	done   protocol.StatusPayload
	// output before begin, between begin and done, with sequence-zero bytes marked.
	beforeBegin, after []byte
	resetIndex         int
	resetSequenceZero  bool
}

func collectFreshRedraw(t *testing.T, viewer *client) freshRedrawFrames {
	t.Helper()
	var got freshRedrawFrames
	got.resetIndex = -1
	begun := false
	deadline := time.After(5 * time.Second)
	for {
		select {
		case frame := <-viewer.frames:
			switch frame.Type {
			case protocol.Status:
				var status protocol.StatusPayload
				if err := json.Unmarshal(frame.Payload, &status); err != nil {
					t.Fatal(err)
				}
				switch status.State {
				case freshRedrawBegin:
					begun = true
					got.states = append(got.states, status.State)
				case freshRedrawDone, freshRedrawRefused:
					got.states = append(got.states, status.State)
					got.done = status
					return got
				}
			case protocol.Output:
				sequence, data, err := protocol.ParseOutput(frame)
				if err != nil {
					t.Fatal(err)
				}
				if !begun {
					got.beforeBegin = append(got.beforeBegin, data...)
					continue
				}
				if got.resetIndex < 0 && bytes.HasPrefix(data, []byte("\x1bc")) {
					got.resetIndex = len(got.after)
					got.resetSequenceZero = sequence == 0
				}
				got.after = append(got.after, data...)
			}
		case <-deadline:
			t.Fatalf("no fresh redraw outcome; states %v", got.states)
		}
	}
}

func startFreshRedrawSession(t *testing.T, name string, agent bool) *Session {
	t.Helper()
	session, err := startSession(name, attachRepaintScript, "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.terminate)
	waitForRingBytes(t, session, "READY")
	if agent {
		session.mu.Lock()
		session.activeAgentRoots["fixture-agent"] = []byte(`{"agent":"claude"}`)
		session.mu.Unlock()
	}
	return session
}

// The viewer receives begin, then a sequence-zero reset as the first output
// after it, then only the agent's repaint, then done. Retained output is never
// resent, the reset never enters the replay ring, and the grid is unchanged.
func TestFreshRedrawSendsResetThenAgentRepaintWithoutRetainedOutput(t *testing.T) {
	session := startFreshRedrawSession(t, "fresh-redraw-test", true)
	current, _, _, _ := session.snapshot()
	viewer, replay, _, _, _ := session.attach(current, 0, false)
	defer session.detach(viewer)
	for _, frame := range replay {
		// Sequence zero is the input-mode prelude every attach resends.
		if sequence, _, err := protocol.ParseOutput(frame); frame.Type == protocol.Output && (err != nil || sequence != 0) {
			t.Fatalf("attach at the current cursor replayed output: %v", frame)
		}
	}
	session.freshRedraw(viewer)
	got := collectFreshRedraw(t, viewer)
	if len(got.states) != 2 || got.states[0] != freshRedrawBegin || got.states[1] != freshRedrawDone {
		t.Fatalf("states = %v, want begin then done", got.states)
	}
	if got.done.Message != "repainted" || got.done.Sequence <= current {
		t.Fatalf("done = %+v, want repainted after %d", got.done, current)
	}
	if got.resetIndex != 0 || !got.resetSequenceZero {
		t.Fatalf("first output after begin is not a sequence-zero reset: index %d zero %v %q",
			got.resetIndex, got.resetSequenceZero, got.after)
	}
	if !bytes.Contains(got.after, []byte("row-twenty")) {
		t.Fatalf("no agent repaint after the reset: %q", got.after)
	}
	if bytes.Contains(got.after, []byte("transcript line one")) || bytes.Contains(got.beforeBegin, []byte("transcript line one")) {
		t.Fatalf("retained output was resent: %q", got.after)
	}
	if bytes.Contains(ringBytesAfter(session, 0), []byte("\x1bc")) {
		t.Fatal("the presentation reset entered the replay ring")
	}
}

func TestFreshRedrawRefusesWithoutAnAgentOrWithAnotherViewer(t *testing.T) {
	t.Run("no agent", func(t *testing.T) {
		session := startFreshRedrawSession(t, "fresh-redraw-shell-test", false)
		current, _, _, _ := session.snapshot()
		viewer, _, _, _, _ := session.attach(current, 0, false)
		defer session.detach(viewer)
		session.freshRedraw(viewer)
		got := collectFreshRedraw(t, viewer)
		if len(got.states) != 1 || got.states[0] != freshRedrawRefused || len(got.after) != 0 {
			t.Fatalf("got %v %q, want only a refusal", got.states, got.after)
		}
	})
	t.Run("two viewers", func(t *testing.T) {
		session := startFreshRedrawSession(t, "fresh-redraw-two-test", true)
		current, _, _, _ := session.snapshot()
		viewer, _, _, _, _ := session.attach(current, 0, false)
		defer session.detach(viewer)
		other, _, _, _, _ := session.attach(current, 0, false)
		defer session.detach(other)
		session.freshRedraw(viewer)
		got := collectFreshRedraw(t, viewer)
		if len(got.states) != 1 || got.done.Message != "another viewer is attached" || len(got.after) != 0 {
			t.Fatalf("got %v %+v %q, want a refusal", got.states, got.done, got.after)
		}
	})
}
