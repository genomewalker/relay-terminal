package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var usageT0 = time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)

func usageAt(minutes int) time.Time { return usageT0.Add(time.Duration(minutes) * time.Minute) }

// usageLine is one journal record in the workers' format, with private
// fields that must never reach the summary.
func usageLine(sequence int, minutes int, agent, event string, extra string) string {
	at := usageAt(minutes).Format(time.RFC3339Nano)
	return fmt.Sprintf(`{"sequence":%d,"payload":{"agent":%q,"relay_recorded_at":%q,"event":{"hook_event_name":%q,"occurred_at":%q,"prompt":"private prompt","tool_input":{"command":"echo bearer-secret"},"message":"private message"%s}}}`,
		sequence, agent, at, event, at, extra)
}

type usageFixture struct {
	t        *testing.T
	stateDir string
	bootID   string
}

func newUsageFixture(t *testing.T) *usageFixture {
	root := t.TempDir()
	stateDir := filepath.Join(root, "workers")
	for _, dir := range []string{stateDir, filepath.Join(root, "events")} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return &usageFixture{t: t, stateDir: stateDir, bootID: "boot-here"}
}

func (f *usageFixture) journal(pane string, lines ...string) string {
	path := filepath.Join(filepath.Dir(f.stateDir), "events", pane+".jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
	return path
}

func (f *usageFixture) manifest(pane, bootID string, pid int) {
	data, _ := json.Marshal(workerManifest{Version: 1, SessionID: pane, WorkerPID: pid, WorkerStartTime: 7,
		NodeBootID: bootID, Token: "secret-token", WorkingDirectory: "/work/kapk"})
	if err := os.WriteFile(filepath.Join(f.stateDir, pane+".json"), data, 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *usageFixture) build(since, until, now time.Time) UsageSummary {
	f.t.Helper()
	live := func(m workerManifest) bool { return m.WorkerPID == 100 }
	summary, err := BuildUsageSummary(f.stateDir, "host", f.bootID, since, until, now, live)
	if err != nil {
		f.t.Fatal(err)
	}
	return summary
}

func usageSegments(pane UsagePane) string {
	parts := make([]string, 0, len(pane.Segments))
	for _, s := range pane.Segments {
		label := s.State
		if s.Reason != "" {
			label += "/" + s.Reason
		}
		parts = append(parts, fmt.Sprintf("%s %v-%v", label,
			int(s.Start.Sub(usageT0).Minutes()), int(s.End.Sub(usageT0).Minutes())))
	}
	return strings.Join(parts, ", ")
}

func TestUsageSummaryStatesFromHookEvents(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-a", "boot-here", 100)
	f.journal("pane-a",
		usageLine(1, 0, "claude", "SessionStart", ""),
		usageLine(2, 5, "claude", "UserPromptSubmit", ""),
		usageLine(3, 6, "claude", "PreToolUse", `,"tool_name":"Bash"`),
		// A subagent's events never change the pane's state.
		usageLine(4, 7, "claude", "PreToolUse", `,"agent_id":"sub","tool_name":"Read"`),
		usageLine(5, 8, "claude", "PermissionRequest", `,"tool_name":"Bash"`),
		usageLine(6, 8, "claude", "Notification", `,"notification_type":"permission_prompt"`),
		usageLine(7, 12, "claude", "PostToolUse", `,"tool_name":"Bash"`),
		usageLine(8, 15, "claude", "PreToolUse", `,"tool_name":"AskUserQuestion"`),
		usageLine(9, 15, "claude", "PermissionRequest", `,"tool_name":"AskUserQuestion"`),
		usageLine(10, 15, "claude", "Notification", `,"notification_type":"permission_prompt"`),
		usageLine(11, 20, "claude", "PostToolUse", `,"tool_name":"AskUserQuestion"`),
		usageLine(12, 30, "claude", "Stop", `,"session_id":"s"`),
		usageLine(13, 31, "claude", "SubagentStop", `,"agent_id":"sub"`),
		usageLine(14, 90, "claude", "Notification", `,"notification_type":"idle_prompt"`),
	)
	summary := f.build(usageAt(0), usageAt(120), usageAt(120))
	if summary.SchemaVersion != 1 || len(summary.Panes) != 1 {
		t.Fatalf("summary %+v", summary)
	}
	pane := summary.Panes[0]
	want := "idle_after_start 0-5, working 5-8, needs_you/approval 8-12, working 12-15, needs_you/question 15-20, working 20-30, your_turn 30-120"
	if got := usageSegments(pane); got != want {
		t.Fatalf("segments\n got %s\nwant %s", got, want)
	}
	if !pane.Live || !pane.NodeVerified || pane.CurrentState != "your_turn" || pane.Agent != "claude" ||
		pane.WorkingDirectory != "/work/kapk" {
		t.Fatalf("pane %+v", pane)
	}
	if pane.Asks.Opened != 2 || pane.Asks.Answered != 2 || pane.Asks.Open != 0 ||
		fmt.Sprint(pane.Asks.WaitSeconds) != "[240 300]" {
		t.Fatalf("asks %+v", pane.Asks)
	}
}

func TestUsageSummaryCodexTurns(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-c", "boot-here", 100)
	f.journal("pane-c",
		usageLine(1, 0, "codex", "UserPromptSubmit", ""),
		usageLine(2, 1, "codex", "PreToolUse", `,"tool_name":"exec_command","turn_id":"t"`),
		usageLine(3, 10, "codex", "Stop", `,"session_id":"s"`),
	)
	pane := f.build(usageAt(0), usageAt(60), usageAt(60)).Panes[0]
	if got := usageSegments(pane); got != "working 0-10, your_turn 10-60" || pane.Agent != "codex" {
		t.Fatalf("got %s %+v", got, pane)
	}
}

// The state at the window start comes from the last event before it, and an
// open segment of a live pane runs to until (clipped to now).
func TestUsageSummaryWindowClipping(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-a", "boot-here", 100)
	f.journal("pane-a",
		usageLine(1, 0, "claude", "UserPromptSubmit", ""),
		usageLine(2, 10, "claude", "Stop", `,"session_id":"s"`),
		usageLine(3, 50, "claude", "UserPromptSubmit", ""),
	)
	pane := f.build(usageAt(20), usageAt(200), usageAt(70)).Panes[0]
	if got := usageSegments(pane); got != "your_turn 20-50, working 50-70" {
		t.Fatalf("got %s", got)
	}
}

// A pane whose worker is gone ends at its newest record; a pending ask then
// counts as unanswered, not open. SessionEnd closes the last state.
func TestUsageSummaryDeadWorkerAndSessionEnd(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-dead", "boot-here", 200) // manifest left behind, worker not live
	f.journal("pane-dead",
		usageLine(1, 0, "claude", "UserPromptSubmit", ""),
		usageLine(2, 5, "claude", "PermissionRequest", `,"tool_name":"Bash"`),
		`{"sequence":3,"payload":{"agent":"relay","relay_recorded_at":"`+usageAt(9).Format(time.RFC3339Nano)+`","event":{}}}`,
	)
	f.journal("pane-ended",
		usageLine(1, 0, "claude", "Stop", `,"session_id":"s"`),
		usageLine(2, 30, "claude", "SessionEnd", ""),
	)
	summary := f.build(usageAt(0), usageAt(100), usageAt(100))
	if len(summary.Panes) != 2 {
		t.Fatalf("panes %+v", summary.Panes)
	}
	dead, ended := summary.Panes[0], summary.Panes[1]
	if dead.Live || usageSegments(dead) != "working 0-5, needs_you/approval 5-9" ||
		dead.Asks.Opened != 1 || dead.Asks.Unanswered != 1 || dead.Asks.Open != 0 || dead.CurrentState != "" {
		t.Fatalf("dead %s %+v", usageSegments(dead), dead)
	}
	if ended.Live || ended.NodeVerified || usageSegments(ended) != "your_turn 0-30" {
		t.Fatalf("ended %s %+v", usageSegments(ended), ended)
	}
}

// The state directory is shared over NFS between cluster nodes: a pane whose
// manifest names another boot is that node's, never reported here.
func TestUsageSummaryExcludesOtherNodesAndUnsafeFiles(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-other", "boot-elsewhere", 100)
	f.journal("pane-other", usageLine(1, 0, "claude", "UserPromptSubmit", ""))
	open := f.journal("pane-open", usageLine(1, 0, "claude", "UserPromptSubmit", ""))
	if err := os.Chmod(open, 0o644); err != nil {
		t.Fatal(err)
	}
	target := f.journal("target", usageLine(1, 0, "claude", "UserPromptSubmit", ""))
	if err := os.Symlink(target, filepath.Join(filepath.Dir(target), "pane-link.jsonl")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	f.journal("not a pane", usageLine(1, 0, "claude", "UserPromptSubmit", ""))
	summary := f.build(usageAt(0), usageAt(10), usageAt(10))
	if len(summary.Panes) != 0 || summary.OtherBootPanes != 1 || summary.RejectedFiles != 2 {
		t.Fatalf("summary %+v", summary)
	}
}

func TestUsageSummaryRejectsBadWindows(t *testing.T) {
	f := newUsageFixture(t)
	for _, window := range [][2]time.Time{{usageAt(10), usageAt(10)}, {usageAt(10), usageAt(0)},
		{usageT0, usageT0.Add(UsageSummaryMaxWindow + time.Minute)}} {
		if _, err := BuildUsageSummary(f.stateDir, "h", "b", window[0], window[1], usageAt(0), nil); err == nil {
			t.Fatalf("window %v accepted", window)
		}
	}
}

// Garbage lines are skipped; a journal larger than one read chunk is read
// backwards across chunk boundaries without losing or splitting records.
func TestUsageSummaryGarbageAndLargeJournal(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-big", "boot-here", 100)
	lines := []string{"not json", usageLine(1, 0, "claude", "UserPromptSubmit", ""), `{"sequence":0}`}
	padding := strings.Repeat("x", 900)
	for i := 0; i < 1200; i++ { // ~1.2 MB of working-state tool events
		lines = append(lines, usageLine(i+2, 1, "claude", "PreToolUse", `,"tool_name":"Bash","pad":"`+padding+`"`))
	}
	lines = append(lines, usageLine(5000, 40, "claude", "Stop", `,"session_id":"s"`))
	f.journal("pane-big", lines...)
	pane := f.build(usageAt(0), usageAt(60), usageAt(60)).Panes[0]
	if got := usageSegments(pane); got != "working 0-40, your_turn 40-60" || pane.Truncated {
		t.Fatalf("got %s truncated=%v", got, pane.Truncated)
	}
	// Starting mid-history reads only back to the last event before since.
	pane = f.build(usageAt(30), usageAt(60), usageAt(60)).Panes[0]
	if got := usageSegments(pane); got != "working 30-40, your_turn 40-60" {
		t.Fatalf("got %s", got)
	}
}

// The output carries only the allowed fields: no prompt, tool input,
// message, token or other journal content.
func TestUsageSummaryCarriesNoPrivateContent(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-a", "boot-here", 100)
	f.journal("pane-a",
		usageLine(1, 0, "claude", "UserPromptSubmit", ""),
		usageLine(2, 5, "claude", "PreToolUse", `,"tool_name":"AskUserQuestion"`),
	)
	data, err := json.Marshal(f.build(usageAt(0), usageAt(10), usageAt(10)))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"private", "bearer-secret", "secret-token", "AskUserQuestion", "tool_input", "prompt"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("summary leaked %q: %s", secret, data)
		}
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(data, &fields)
	var panes []map[string]json.RawMessage
	_ = json.Unmarshal(fields["panes"], &panes)
	allowed := map[string]bool{"pane_id": true, "agent": true, "working_directory": true, "live": true, "node_verified": true,
		"current_state": true, "current_reason": true, "last_event_at": true, "segments": true, "asks": true, "truncated": true}
	for key := range panes[0] {
		if !allowed[key] {
			t.Fatalf("unexpected pane field %q", key)
		}
	}
}

// A restart (process end, then start) is idle_after_start, not your turn,
// and Claude's idle_prompt does not turn it into one.
func TestUsageSummaryRestartIsIdleAfterStart(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-r", "boot-here", 100)
	f.journal("pane-r",
		usageLine(1, 0, "claude", "UserPromptSubmit", ""),
		usageLine(2, 10, "claude", "Stop", `,"session_id":"s"`),
		usageLine(3, 20, "claude", "SessionEnd", `,"source":"process-tree","root_id":"r1"`),
		usageLine(4, 21, "claude", "SessionStart", `,"source":"process-tree","root_id":"r2"`),
		usageLine(5, 25, "claude", "Notification", `,"notification_type":"idle_prompt"`),
		usageLine(6, 40, "claude", "UserPromptSubmit", ""),
		// An interrupted turn has no Stop; idle_prompt after work is your turn.
		usageLine(7, 50, "claude", "Notification", `,"notification_type":"idle_prompt"`),
	)
	pane := f.build(usageAt(0), usageAt(60), usageAt(60)).Panes[0]
	want := "working 0-10, your_turn 10-20, no_agent 20-21, idle_after_start 21-40, working 40-50, your_turn 50-60"
	if got := usageSegments(pane); got != want || pane.CurrentState != "your_turn" {
		t.Fatalf("segments\n got %s\nwant %s (%s)", got, want, pane.CurrentState)
	}
}

// A live pane whose agent exited has no agent running: its current state and
// remaining time are no_agent, and an ask it left is unanswered.
func TestUsageSummaryNoAgentRunning(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-n", "boot-here", 100)
	f.journal("pane-n",
		usageLine(1, 0, "codex", "SessionStart", `,"source":"process-tree","root_id":"r1"`),
		usageLine(2, 5, "codex", "UserPromptSubmit", ""),
		usageLine(3, 8, "claude", "PermissionRequest", `,"tool_name":"Bash"`),
		usageLine(4, 15, "codex", "SessionEnd", `,"source":"process-tree","root_id":"r1"`),
	)
	pane := f.build(usageAt(0), usageAt(60), usageAt(60)).Panes[0]
	want := "idle_after_start 0-5, working 5-8, needs_you/approval 8-15, no_agent 15-60"
	if got := usageSegments(pane); got != want || pane.CurrentState != "no_agent" ||
		pane.Asks.Unanswered != 1 || pane.Asks.Answered != 0 || pane.Asks.Open != 0 {
		t.Fatalf("segments\n got %s\nwant %s (%+v)", got, want, pane)
	}
}

// Hook SessionStart/SessionEnd (on /clear or compaction) do not change the
// state, and one of several agent processes ending leaves an agent running.
func TestUsageSummaryIgnoresHookSessionEventsAndNestedRoots(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-h", "boot-here", 100)
	f.journal("pane-h",
		usageLine(1, 0, "claude", "SessionStart", `,"source":"process-tree","root_id":"main"`),
		usageLine(2, 2, "claude", "UserPromptSubmit", ""),
		usageLine(3, 4, "claude", "SessionStart", `,"source":"hook"`),
		usageLine(4, 5, "claude", "SessionEnd", `,"source":"hook"`),
		usageLine(5, 6, "claude", "SessionStart", `,"source":"process-tree","root_id":"nested"`),
		usageLine(6, 7, "claude", "SessionEnd", `,"source":"process-tree","root_id":"nested"`),
		usageLine(7, 9, "claude", "Stop", `,"session_id":"s"`),
	)
	pane := f.build(usageAt(0), usageAt(20), usageAt(20)).Panes[0]
	if got := usageSegments(pane); got != "idle_after_start 0-2, working 2-9, your_turn 9-20" {
		t.Fatalf("got %s", got)
	}
}

// Each rule on its own: /clear's hook SessionEnd/SessionStart after a turn
// (agent start not in view), and a nested agent starting during your turn.
func TestUsageSummaryHookClearAndNestedStartDuringYourTurn(t *testing.T) {
	f := newUsageFixture(t)
	f.manifest("pane-clear", "boot-here", 100)
	f.journal("pane-clear",
		usageLine(1, 0, "claude", "UserPromptSubmit", ""),
		usageLine(2, 5, "claude", "Stop", `,"session_id":"s"`),
		usageLine(3, 7, "claude", "SessionEnd", `,"source":"hook"`),
		usageLine(4, 8, "claude", "SessionStart", `,"source":"hook"`),
	)
	f.manifest("pane-nest", "boot-here", 100)
	f.journal("pane-nest",
		usageLine(1, 0, "claude", "SessionStart", `,"source":"process-tree","root_id":"main"`),
		usageLine(2, 1, "claude", "UserPromptSubmit", ""),
		usageLine(3, 3, "claude", "Stop", `,"session_id":"s"`),
		usageLine(4, 5, "claude", "SessionStart", `,"source":"process-tree","root_id":"nested"`),
	)
	panes := f.build(usageAt(0), usageAt(20), usageAt(20)).Panes
	if got := usageSegments(panes[0]); got != "working 0-5, your_turn 5-20" {
		t.Fatalf("clear: got %s", got)
	}
	if got := usageSegments(panes[1]); got != "idle_after_start 0-1, working 1-3, your_turn 3-20" {
		t.Fatalf("nested: got %s", got)
	}
}
