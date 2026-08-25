package daemon

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClassifyAgentProcess(t *testing.T) {
	tests := []struct {
		command   string
		arguments string
		want      string
	}{
		{"codex", "/home/me/.local/bin/codex\x00resume\x00thr_1", "codex"},
		{"node", "/opt/tools/claude --dangerously-skip-permissions", "claude"},
		{"bash", "bash -l", ""},
	}
	for _, test := range tests {
		if got := classifyAgentProcess(test.command, test.arguments); got != test.want {
			t.Fatalf("classifyAgentProcess(%q, %q) = %q, want %q", test.command, test.arguments, got, test.want)
		}
	}
}

func TestAcknowledgedInputIsAppliedOnceAcrossRetry(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{pty: writer, inputSequences: make(map[[16]byte]uint64)}
	clientID := [16]byte{7, 8, 9}
	if err := session.acknowledgedInput(clientID, 1, []byte("a")); err != nil {
		t.Fatal(err)
	}
	if err := session.acknowledgedInput(clientID, 1, []byte("a")); err != nil {
		t.Fatal(err)
	}
	if err := session.acknowledgedInput(clientID, 2, []byte("b")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "ab" {
		t.Fatalf("retried input was duplicated: %q", data)
	}
}

func TestAgentJournalSurvivesReopenAndRestoresCursor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events", "pane.jsonl")
	first := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	if err := first.enableEventJournal(path); err != nil {
		t.Fatal(err)
	}
	first.agentEvent([]byte(`{"agent":"codex","event":{"type":"thread.started"}}`))
	first.agentEvent([]byte(`{"agent":"codex","event":{"type":"item.completed"}}`))
	if err := first.eventJournal.file.Close(); err != nil {
		t.Fatal(err)
	}

	restored := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	if err := restored.enableEventJournal(path); err != nil {
		t.Fatal(err)
	}
	defer restored.eventJournal.file.Close()
	observer, frames := restored.observeAgents(1)
	defer restored.detachAgentObserver(observer)
	if restored.eventSequence != 2 || len(frames) != 1 || indexedAgentSequence(frames[0].Payload) != 2 {
		t.Fatalf("journal cursor was not restored: sequence=%d frames=%#v", restored.eventSequence, frames)
	}
}

func TestCodexTranscriptSubagentLifecycle(t *testing.T) {
	start := []byte(`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"SubAgentActivity","id":"call-1","kind":"started","agent_thread_id":"thread-1","agent_path":"/root/logic_retest"}}}`)
	events := codexTranscriptEvents(start)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStart" ||
		events[0].Event.AgentID != "/root/logic_retest" || events[0].Event.ThreadID != "thread-1" {
		t.Fatalf("unexpected Codex start event: %#v", events)
	}
	progress := []byte(`{"type":"response_item","payload":{"type":"agent_message","author":"/root/logic_retest","recipient":"/root","content":[{"type":"input_text","text":"Message Type: MESSAGE"}]}}`)
	if events := codexTranscriptEvents(progress); len(events) != 0 {
		t.Fatalf("progress message stopped an active agent: %#v", events)
	}
	update := []byte(`{"timestamp":"2026-08-25T14:41:32Z","type":"response_item","payload":{"type":"agent_message","author":"/root/logic_retest","recipient":"/root","content":[{"type":"input_text","text":"Message Type: MESSAGE\nTask name: /root\nSender: /root/logic_retest\nPayload:\nChecked 42 cases."}]}}`)
	events = codexTranscriptEvents(update)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentUpdate" ||
		events[0].Event.Message != "Checked 42 cases." {
		t.Fatalf("unexpected Codex progress event: %#v", events)
	}
	stop := []byte(`{"type":"response_item","payload":{"type":"agent_message","author":"/root/logic_retest","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER"}]}}`)
	events = codexTranscriptEvents(stop)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStop" ||
		events[0].Event.AgentID != "/root/logic_retest" {
		t.Fatalf("unexpected Codex stop event: %#v", events)
	}
}

func TestClaudeTranscriptSubagentLifecycle(t *testing.T) {
	start := []byte(`{"type":"user","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent-123","description":"Smoke test explore agent"},"message":{"role":"user","content":[]}}`)
	events := claudeTranscriptEvents(start)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStart" ||
		events[0].Event.AgentID != "agent-123" || events[0].Event.AgentType != "Smoke test explore agent" {
		t.Fatalf("unexpected Claude start event: %#v", events)
	}
	stop := []byte(`{"timestamp":"2026-08-25T14:41:32Z","type":"user","message":{"role":"user","content":"<task-notification><task-id>agent-123</task-id><status>completed</status><summary>Agent \"Smoke test explore agent\" finished</summary><result>Checked the workspace.</result></task-notification>"}}`)
	events = claudeTranscriptEvents(stop)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStop" ||
		events[0].Event.AgentID != "agent-123" || events[0].Event.AgentType != "Smoke test explore agent" ||
		events[0].Event.Message != "Checked the workspace." {
		t.Fatalf("unexpected Claude stop event: %#v", events)
	}
}

func TestReplayStartUsesLatestFullScreenRedrawOnlyForFreshRenderer(t *testing.T) {
	replay := []record{
		{sequence: 1, data: []byte("old output\x1b[2Jfirst redraw")},
		{sequence: 2, data: []byte("more\x1b[2Jcurrent screen")},
		{sequence: 3, data: []byte(" tail")},
	}

	recordIndex, byteOffset := replayStart(replay, 0)
	if recordIndex != 1 || byteOffset != len("more") {
		t.Fatalf("fresh replay starts at (%d, %d), want (1, %d)", recordIndex, byteOffset, len("more"))
	}
	recordIndex, byteOffset = replayStart(replay, 1)
	if recordIndex != 0 || byteOffset != 0 {
		t.Fatalf("incremental replay must remain exact, got (%d, %d)", recordIndex, byteOffset)
	}
}

func TestAgentObserverReplaysIndexedHistoryAfterCursor(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SessionStart"}}`))
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"research-1","agent_type":"Explore"}}`))
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Read"}}`))

	observer, snapshot := session.observeAgents(0)
	defer session.detachAgentObserver(observer)
	if len(snapshot) != 3 {
		t.Fatalf("observer snapshot has %d frames, want complete indexed history", len(snapshot))
	}
	if indexedAgentSequence(snapshot[0].Payload) != 1 || indexedAgentSequence(snapshot[2].Payload) != 3 {
		t.Fatalf("observer history is not indexed: %#v", snapshot)
	}
	cursorObserver, cursorSnapshot := session.observeAgents(2)
	defer session.detachAgentObserver(cursorObserver)
	if len(cursorSnapshot) != 1 || indexedAgentSequence(cursorSnapshot[0].Payload) != 3 {
		t.Fatalf("cursor replay returned the wrong suffix: %#v", cursorSnapshot)
	}

	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"research-1"}}`))
	secondObserver, secondSnapshot := session.observeAgents(3)
	defer session.detachAgentObserver(secondObserver)
	if len(secondSnapshot) != 1 || !bytes.Contains(secondSnapshot[0].Payload, []byte(`"SubagentStop"`)) {
		t.Fatalf("new lifecycle event was not replayed after cursor: %#v", secondSnapshot)
	}
}

func TestEnvironmentOverridesReplaceHotPathVariables(t *testing.T) {
	environment := environmentWithOverrides(
		[]string{"PATH=/old", "TERM=old", "UNCHANGED=yes"},
		map[string]string{"PATH": "/relay:/old", "TERM": "xterm-256color"},
	)
	values := make(map[string]string)
	for _, entry := range environment {
		for index := range entry {
			if entry[index] == '=' {
				values[entry[:index]] = entry[index+1:]
				break
			}
		}
	}
	if values["PATH"] != "/relay:/old" || values["TERM"] != "xterm-256color" || values["UNCHANGED"] != "yes" {
		t.Fatalf("unexpected environment: %#v", values)
	}
}

func TestBashIntegrationKeepsRelayShimsAheadOfUserPathChanges(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	home := t.TempDir()
	realDirectory := filepath.Join(home, "real")
	shimDirectory := filepath.Join(home, "relay shims")
	for _, directory := range []string{realDirectory, shimDirectory} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, directory := range []string{realDirectory, shimDirectory} {
		if err := os.WriteFile(filepath.Join(directory, "codex"), []byte("#!/bin/sh\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, ".bashrc"), []byte("export PATH='"+realDirectory+":'$PATH\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rcPath, err := writeBashIntegration(home, shimDirectory)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(bash, "--rcfile", rcPath, "-i", "-c", "command -v codex")
	command.Env = append(os.Environ(), "HOME="+home, "PATH="+realDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("bash integration failed: %v: %s", err, output)
	}
	if !strings.Contains(string(output), filepath.Join(shimDirectory, "codex")) {
		t.Fatalf("Relay shim did not win command lookup: %s", output)
	}
}

func TestExitedSessionIsReplacedOnNextAttach(t *testing.T) {
	first, err := startSession("restart-test", "exit 0", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	// Login-shell startup can include user initialization and is measurably
	// slower on loaded CI/HPC nodes. This tests replacement, not startup latency.
	deadline := time.Now().Add(5 * time.Second)
	for !first.hasExited() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !first.hasExited() {
		t.Fatal("first session did not exit")
	}

	second, err := startSession("restart-test", "sleep 5", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("exited session was reused")
	}
	_ = second.signal(15)
}
