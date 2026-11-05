package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// A native maintenance restart resumes the same conversation in a new agent
// process. Rotation must follow that process instead of failing every
// evaluation on the old identity, and must never adopt another conversation.
func TestHostRotationFollowsResumedConversationIntoNewProcess(t *testing.T) {
	fixture := hostRotationFixture()
	original := readHostRotationResumedBinding
	t.Cleanup(func() { readHostRotationResumedBinding = original })
	readHostRotationResumedBinding = func(e hostRotationEnrollment) (AgentBindingRecord, error) {
		var b AgentBindingRecord
		b.SessionID = e.SessionID
		b.Producer.Provider = e.Client
		b.Producer.ProcessID = fixture.AgentPID + 1000
		b.Producer.ProcessStart = fixture.AgentStart + 1000
		return b, nil
	}
	var mu sync.Mutex
	var seen []hostRotationEnrollment
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	s := newHostRotationSupervisor(path, func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
		mu.Lock()
		seen = append(seen, e)
		mu.Unlock()
		return hostRotationTestDecision("", nil, 1), nil
	})
	defer s.close()
	enrollHostRotation(t, s)
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return len(r.Decision) > 0 })
	if !r.Enabled || r.Enrollment.AgentPID != fixture.AgentPID+1000 || r.Enrollment.AgentStart != fixture.AgentStart+1000 ||
		r.Enrollment.SessionID != fixture.SessionID || r.Enrollment.WorkerPID != fixture.WorkerPID {
		t.Fatalf("enrollment did not follow the resumed process: %+v", r)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 1 || seen[0].AgentPID != fixture.AgentPID+1000 {
		t.Fatalf("evaluation used the old process identity: %+v", seen)
	}
	data, err := privatePromptEditorBytes(path, 262144)
	var saved hostRotationRecord
	if err != nil || json.Unmarshal(data, &saved) != nil || saved.Enrollment.AgentPID != fixture.AgentPID+1000 {
		t.Fatalf("rebind was not durable: %s %v", data, err)
	}
}

func TestHostRotationNeverAdoptsAnotherConversationOrWorker(t *testing.T) {
	original := readHostRotationResumedBinding
	t.Cleanup(func() { readHostRotationResumedBinding = original })
	readHostRotationResumedBinding = func(hostRotationEnrollment) (AgentBindingRecord, error) {
		return AgentBindingRecord{}, errors.New("host rotation conversation changed")
	}
	fixture := hostRotationFixture()
	var mu sync.Mutex
	var seen []hostRotationEnrollment
	s := newHostRotationSupervisor(filepath.Join(t.TempDir(), "rotation", "state.json"),
		func(_ context.Context, e hostRotationEnrollment, _ time.Time) (json.RawMessage, error) {
			mu.Lock()
			seen = append(seen, e)
			mu.Unlock()
			return nil, errors.New("host rotation provider identity changed")
		})
	defer s.close()
	enrollHostRotation(t, s)
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "evaluation_unavailable" })
	if r.Enrollment != fixture {
		t.Fatalf("enrollment changed without a matching conversation: %+v", r.Enrollment)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 1 || seen[0] != fixture {
		t.Fatalf("unexpected evaluation identity: %+v", seen)
	}
}

func TestHostRotationKeepsEnrollmentForTheSameProcess(t *testing.T) {
	fixture := hostRotationFixture()
	original := readHostRotationResumedBinding
	t.Cleanup(func() { readHostRotationResumedBinding = original })
	readHostRotationResumedBinding = func(e hostRotationEnrollment) (AgentBindingRecord, error) {
		var b AgentBindingRecord
		b.SessionID, b.Producer.Provider = e.SessionID, e.Client
		b.Producer.ProcessID, b.Producer.ProcessStart = e.AgentPID, e.AgentStart
		return b, nil
	}
	s := newHostRotationSupervisor(filepath.Join(t.TempDir(), "rotation", "state.json"),
		func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
			return hostRotationTestDecision("", nil, 1), nil
		})
	defer s.close()
	enrollHostRotation(t, s)
	before := s.snapshot().Generation
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return len(r.Decision) > 0 })
	if r.Enrollment != fixture || r.Generation != before {
		t.Fatalf("same process caused a rebind: before=%d %+v", before, r)
	}
}
