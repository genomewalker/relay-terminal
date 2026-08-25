package daemon

import (
	"bytes"
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
	stop := []byte(`{"type":"user","message":{"role":"user","content":"<task-notification><task-id>agent-123</task-id><status>completed</status><summary>Agent \"Smoke test explore agent\" finished</summary></task-notification>"}}`)
	events = claudeTranscriptEvents(stop)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStop" ||
		events[0].Event.AgentID != "agent-123" || events[0].Event.AgentType != "Smoke test explore agent" {
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

func TestAgentObserverSnapshotsActiveSubagents(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SessionStart"}}`))
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"research-1","agent_type":"Explore"}}`))
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Read"}}`))

	observer, snapshot := session.observeAgents()
	defer session.detachAgentObserver(observer)
	if len(snapshot) != 2 {
		t.Fatalf("observer snapshot has %d frames, want root state plus active subagent", len(snapshot))
	}
	if !bytes.Contains(snapshot[1].Payload, []byte(`"agent_id":"research-1"`)) {
		t.Fatalf("active subagent missing from snapshot: %s", snapshot[1].Payload)
	}

	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"research-1"}}`))
	secondObserver, secondSnapshot := session.observeAgents()
	defer session.detachAgentObserver(secondObserver)
	if len(secondSnapshot) != 1 {
		t.Fatalf("stopped subagent remained in snapshot: %#v", secondSnapshot)
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
	deadline := time.Now().Add(2 * time.Second)
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
