package nativechat

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func readyState(t testing.TB) *State {
	t.Helper()
	s, e := NewState(Identity{"pane-1", "instance-1", "codex"}, "/workspace", "")
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Ready("session-1"); e != nil {
		t.Fatal(e)
	}
	return s
}
func approvalState(t testing.TB) *State {
	s := readyState(t)
	if e := s.Running("turn-1"); e != nil {
		t.Fatal(e)
	}
	if e := s.AddRequest(Request{ID: "request-1", TurnID: "turn-1", Kind: "approval", Title: "Write file"}); e != nil {
		t.Fatal(e)
	}
	return s
}
func cloneState(s *State) *State {
	b, _ := json.Marshal(s)
	var n State
	_ = json.Unmarshal(b, &n)
	return &n
}
func TestActionsAreOwnedAndOnceOnly(t *testing.T) {
	s := readyState(t)
	a := Action{ID: "send-1", Identity: s.View.Identity, Kind: "send", Text: "hello"}
	stale := a
	stale.Identity.Instance = "old-instance"
	before, _ := json.Marshal(s)
	if _, _, e := s.Claim(stale); e == nil {
		t.Fatal("stale owner admitted")
	}
	after, _ := json.Marshal(s)
	if string(before) != string(after) {
		t.Fatal("rejected action changed state")
	}
	r, fresh, e := s.Claim(a)
	if e != nil || !fresh || r.State != "claimed" {
		t.Fatalf("%+v %v %v", r, fresh, e)
	}
	if _, fresh, e = s.Claim(a); e != nil || fresh {
		t.Fatal("same action executed twice")
	}
	changed := a
	changed.Text = "different"
	if _, _, e = s.Claim(changed); e == nil {
		t.Fatal("action ID rebound")
	}
	if e = s.RecordOutcome(a.ID, "uncertain", "write outcome unknown"); e != nil {
		t.Fatal(e)
	}
	a.ID = "send-2"
	if _, _, e = s.Claim(a); e == nil {
		t.Fatal("uncertain send replayed under fresh ID")
	}
}
func TestApprovalsPreserveTurnAndDecision(t *testing.T) {
	s := approvalState(t)
	a := Action{ID: "answer-1", Identity: s.View.Identity, Kind: "respond", RequestID: "request-1", TurnID: "old-turn", Decision: "allow"}
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("wrong turn answered")
	}
	a.TurnID = "turn-1"
	a.Decision = "allowForSession"
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("permission scope widened")
	}
	a.Decision = "allow"
	if _, fresh, e := s.Claim(a); e != nil || !fresh {
		t.Fatal("valid approval refused", e)
	}
	a.ID = "answer-2"
	a.Decision = "deny"
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("two replies to one request")
	}
}
func TestBackgroundRequestOutlivesTopLevelResult(t *testing.T) {
	s := approvalState(t)
	if e := s.Complete("turn-1", "completed", ""); e != nil {
		t.Fatal(e)
	}
	if len(s.View.Requests) != 1 || !s.Snapshot().Capabilities.Respond || s.Snapshot().Capabilities.Send {
		t.Fatal("background approval lost or new send enabled")
	}
	a := Action{ID: "answer-1", Identity: s.View.Identity, Kind: "respond", RequestID: "request-1", TurnID: "turn-1", Decision: "deny"}
	if _, fresh, e := s.Claim(a); e != nil || !fresh {
		t.Fatal("background answer refused", e)
	}
	s.ResolveRequest("request-1")
	if !s.Snapshot().Capabilities.Send {
		t.Fatal("conversation never became ready")
	}
	s.Exit("process ended")
	if s.Snapshot().Capabilities.Send || s.Snapshot().Capabilities.Respond {
		t.Fatal("dead worker retained controls")
	}
}
func TestQuestionAndHistoryBounds(t *testing.T) {
	s := readyState(t)
	_ = s.Running("turn-1")
	r := Request{ID: "question-1", TurnID: "turn-1", Kind: "question", Questions: []Question{{ID: "q1", Text: "Choose", Multiple: true, Options: []Option{{ID: "Alpha", Label: "A"}, {ID: "Beta", Label: "B"}}}}}
	if e := s.AddRequest(r); e != nil {
		t.Fatal(e)
	}
	a := Action{ID: "answer-1", Identity: s.View.Identity, Kind: "respond", TurnID: "turn-1", RequestID: r.ID, Answers: map[string][]string{"other": {"Alpha"}}}
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("wrong question answered")
	}
	a.Answers = map[string][]string{"q1": {"Alpha", "Beta"}}
	if _, fresh, e := s.Claim(a); e != nil || !fresh {
		t.Fatal("multi-selection lost", e)
	}
	for i := 0; i < MaxItems+2; i++ {
		id := strings.Repeat("x", i%5+1) + string(rune('a'+i/5%26)) + string(rune('a'+i/130))
		_ = s.AddItem(Item{ID: id, Role: "assistant", Text: strings.Repeat("z", MaxItemBytes+1)}, false)
	}
	if len(s.View.Items) > MaxItems {
		t.Fatal("history grew past bound")
	}
	for _, i := range s.View.Items {
		if len(i.Text) > MaxItemBytes || !i.Truncated {
			t.Fatal("item bound not visible")
		}
	}
	caps := s.Snapshot().Capabilities
	if caps.Maintenance || caps.ScheduledTasks != "unknown" {
		t.Fatal("OS idleness invented scheduled-task safety")
	}
}
func TestInterruptTargetsActiveTurn(t *testing.T) {
	s := readyState(t)
	_ = s.Running("turn-1")
	a := Action{ID: "interrupt-1", Identity: s.View.Identity, Kind: "interrupt", TurnID: "turn-2"}
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("wrong turn interrupted")
	}
	a.TurnID = "turn-1"
	if _, fresh, e := s.Claim(a); e != nil || !fresh {
		t.Fatal("valid interruption refused", e)
	}
	if e := s.Complete("turn-2", "interrupted", ""); e == nil {
		t.Fatal("stale completion settled active turn")
	}
	if e := s.Complete("turn-1", "interrupted", ""); e != nil {
		t.Fatal(e)
	}
	if !s.Snapshot().Capabilities.Send {
		t.Fatal("cannot start next turn after interrupt")
	}
}

// Both actors use the actual Claim implementation; every sequence through
// depth five includes every two-actor interleaving at that bound.
func TestBoundedApprovalInterleavings(t *testing.T) {
	visited := 0
	var walk func(*State, int, int)
	walk = func(s *State, depth, accepted int) {
		visited++
		if accepted > 1 {
			t.Fatal("more than one provider response admitted")
		}
		if s.Snapshot().Capabilities.Maintenance {
			t.Fatal("unknown tasks admitted retirement")
		}
		if depth == 5 {
			return
		}
		for op := 0; op < 8; op++ {
			n := cloneState(s)
			count := accepted
			switch op {
			case 0, 1, 2, 3:
				actor := "actor-a"
				if op >= 2 {
					actor = "actor-b"
				}
				decision := "allow"
				if op%2 == 1 {
					decision = "deny"
				}
				a := Action{ID: actor + "-" + decision, Identity: n.View.Identity, Kind: "respond", TurnID: "turn-1", RequestID: "request-1", Decision: decision}
				_, fresh, e := n.Claim(a)
				if e == nil && fresh {
					count++
				}
			case 4:
				n.Exit("disconnected provider")
			case 5:
				n.ResolveRequest("request-1")
			case 6:
				a := Action{ID: "stale", Identity: Identity{"pane-1", "old", "codex"}, Kind: "respond", TurnID: "turn-1", RequestID: "request-1", Decision: "allow"}
				if _, _, e := n.Claim(a); e == nil {
					t.Fatal("stale owner in model")
				}
			case 7:
				a := Action{ID: "wrong-turn", Identity: n.View.Identity, Kind: "respond", TurnID: "turn-0", RequestID: "request-1", Decision: "allow"}
				if _, _, e := n.Claim(a); e == nil {
					t.Fatal("wrong turn in model")
				}
			}
			walk(n, depth+1, count)
		}
	}
	walk(approvalState(t), 0, 0)
	if visited != 37449 {
		t.Fatalf("unexpected explored state count %d", visited)
	}
	t.Logf("bound=5 operations=8 actors=2 states_explored=%d; at most one reply, exact ownership/turn, no automatic retirement with unknown tasks", visited)
}

func TestUncertainCompletionCannotReopenInput(t *testing.T) {
	s := readyState(t)
	a := Action{ID: "send", Identity: s.View.Identity, Kind: "send", Text: "hello"}
	if _, _, e := s.Claim(a); e != nil {
		t.Fatal(e)
	}
	_ = s.Running("turn")
	if e := s.RecordOutcome(a.ID, "uncertain", "unknown write"); e != nil {
		t.Fatal(e)
	}
	_ = s.Complete("turn", "completed", "")
	caps := s.Snapshot().Capabilities
	if caps.Send || caps.Steer || caps.Interrupt || caps.Respond {
		t.Fatal("completion reopened input after uncertain outcome")
	}
	a.ID = "another"
	if _, _, e := s.Claim(a); e == nil {
		t.Fatal("new action bypassed uncertainty hold")
	}
}
func TestReceiptStorageBound(t *testing.T) {
	s := readyState(t)
	for i := 0; i < MaxReceipts; i++ {
		a := Action{ID: fmt.Sprintf("action-%d", i), Identity: s.View.Identity, Kind: "send", Text: "hello"}
		if _, fresh, e := s.Claim(a); e != nil || !fresh {
			t.Fatal("early receipt refusal", i, e)
		}
		_ = s.RecordOutcome(a.ID, "sent", "written")
		_ = s.Running("turn")
		_ = s.Complete("turn", "completed", "")
	}
	if _, _, e := s.Claim(Action{ID: "overflow", Identity: s.View.Identity, Kind: "send", Text: "hello"}); e == nil {
		t.Fatal("receipt storage exceeded bound")
	}
}
