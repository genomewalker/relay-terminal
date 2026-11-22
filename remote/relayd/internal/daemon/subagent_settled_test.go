package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A team teammate is recorded as teammate_spawned and never gets a completion
// notification, so its lifecycle stays at "start" forever. On 2026-11-08 that
// held every account move of two Mac panes over teammates that had ended at
// end_turn days before. A started subagent whose own transcript ends at an
// assistant end_turn and has been quiet for the settle period is no longer
// working; anything else that started still holds.
func TestStartedSubagentSettledAtEndTurnNoLongerHoldsAMove(t *testing.T) {
	const session = "ac8eb580-5ca3-4717-b637-9efce723f26e"
	project := filepath.Join(t.TempDir(), "projects/-Users-kbd606")
	path := filepath.Join(project, session+".jsonl")
	subagents := filepath.Join(project, session, "subagents")
	if err := os.MkdirAll(subagents, 0700); err != nil {
		t.Fatal(err)
	}
	phWrite(t, path, mrJSONLines(mrRows(mrLaunched("t1", "teammate_spawned"))...), 0o644)
	endTurn := `{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}` + "\n"
	toolUse := `{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}` + "\n"
	toolResult := `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}` + "\n"
	old, recent := time.Now().Add(-3*24*time.Hour), time.Now().Add(-time.Minute)
	for _, c := range []struct {
		name, transcript string
		modified         time.Time
		want             any
	}{
		{"ended_and_quiet", toolUse + toolResult + endTurn, old, false},
		{"ended_but_recent", toolUse + toolResult + endTurn, recent, true},
		{"mid_tool_call", endTurn + toolUse, old, true},
		{"waiting_on_tool_result", endTurn + toolUse + toolResult, old, true},
		{"unparseable_tail", endTurn + "{not json\n", old, true},
		{"empty", "", old, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := phWrite(t, filepath.Join(subagents, "agent-t1.jsonl"), c.transcript, 0o644)
			if err := os.Chtimes(p, c.modified, c.modified); err != nil {
				t.Fatal(err)
			}
			mrEq(t, phSubagentWork(path, session), c.want)
		})
	}
}

// An in-process subagent cannot outlive its agent process. On 2026-11-22 the
// main Relay dev pane's account move was refused for subagent_work by seven
// subagents interrupted on 2026-11-08/09, before the session was resumed by
// a later process: their lifecycle stayed at "start" and their transcripts
// ended mid-turn, so they counted as working forever. A subagent last written
// before the current process started is an earlier incarnation's leftover.
func TestSubagentFromEarlierProcessIncarnationDoesNotHoldAMove(t *testing.T) {
	const session = "174df850-82c8-42d2-af27-2101ec45b309"
	project := filepath.Join(t.TempDir(), "projects/-Users-kbd606-dev-term")
	path := filepath.Join(project, session+".jsonl")
	subagents := filepath.Join(project, session, "subagents")
	if err := os.MkdirAll(subagents, 0700); err != nil {
		t.Fatal(err)
	}
	phWrite(t, path, mrJSONLines(mrRows(mrLaunched("t1", "teammate_spawned"))...), 0o644)
	// Interrupted mid-turn: the last record is the user's tool result.
	interrupted := `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}` + "\n"
	p := phWrite(t, filepath.Join(subagents, "agent-t1.jsonl"), interrupted, 0o644)
	written := time.Now().Add(-14 * 24 * time.Hour)
	if err := os.Chtimes(p, written, written); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name    string
		started time.Time
		want    any
	}{
		// Without a process start the old rule applies and it still holds.
		{"no_process_start", time.Time{}, true},
		{"process_started_after_last_write", time.Now().Add(-time.Hour), false},
		// Within the clock-skew allowance it may belong to this process.
		{"process_started_just_after_last_write", written.Add(time.Minute), true},
		{"process_started_before_last_write", written.Add(-time.Hour), true},
	} {
		t.Run(c.name, func(t *testing.T) {
			mrEq(t, phSubagentWorkSince(path, session, c.started), c.want)
		})
	}
	// A subagent of the current process still holds next to a leftover.
	current := phWrite(t, filepath.Join(subagents, "agent-t2.jsonl"), interrupted, 0o644)
	_ = current
	phWrite(t, path, mrJSONLines(mrRows(mrLaunched("t1", "teammate_spawned"), mrLaunched("t2", "teammate_spawned"))...), 0o644)
	mrEq(t, phSubagentWorkSince(path, session, time.Now().Add(-time.Hour)), true)
}
