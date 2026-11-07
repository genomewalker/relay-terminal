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
