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

	"github.com/relay-terminal/relayd/internal/protocol"
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

func TestAcknowledgedInputAcceptsFreshProcessIdentity(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{pty: writer, inputSequences: make(map[[16]byte]uint64)}
	previousProcess := [16]byte{1}
	freshProcess := [16]byte{2}
	if err := session.acknowledgedInput(previousProcess, 41, []byte("old")); err != nil {
		t.Fatal(err)
	}
	if err := session.acknowledgedInput(previousProcess, 1, []byte("dropped")); err != nil {
		t.Fatal(err)
	}
	if err := session.acknowledgedInput(freshProcess, 1, []byte("fresh")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "oldfresh" {
		t.Fatalf("fresh process input was not applied: %q", data)
	}
}

func TestInputControlLeaseAllowsOneClientAndReconnectGrace(t *testing.T) {
	session := &Session{}
	if !session.acquireControl("client-a") {
		t.Fatal("first client was not granted control")
	}
	if session.acquireControl("client-b") {
		t.Fatal("second client was granted simultaneous control")
	}
	session.releaseControl("client-a", false)
	if session.acquireControl("client-b") {
		t.Fatal("reconnect grace was not respected")
	}
	session.mu.Lock()
	session.controlGraceUntil = time.Now().Add(-time.Second)
	session.mu.Unlock()
	if !session.acquireControl("client-b") {
		t.Fatal("expired lease was not transferred")
	}
}

func TestCleanDetachReleasesInputControlImmediately(t *testing.T) {
	session := &Session{}
	if !session.acquireControl("client-a") {
		t.Fatal("first client was not granted control")
	}
	session.releaseControl("client-a", true)
	if !session.acquireControl("client-b") {
		t.Fatal("clean detach retained the reconnect grace lease")
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
	observer, frames, _ := restored.observeAgents(1)
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
	if len(events) != 1 || events[0].Event.HookEventName != "PeerMessage" ||
		events[0].Event.Message != "Checked 42 cases." ||
		events[0].Event.FromPeerID != "/root/logic_retest" || events[0].Event.ToPeerID != "/root" {
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

func TestStalledViewerIsDisconnectedBeforeSequenceGap(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), eventHashes: make(map[[32]byte]struct{}),
	}
	viewer := newClient(1)
	viewer.frames <- protocol.Frame{Type: protocol.Ping}
	session.clients[viewer] = struct{}{}
	session.publish([]byte("contiguous output"))
	select {
	case <-viewer.lagged:
	default:
		t.Fatal("stalled viewer was not marked lagged")
	}
	if _, exists := session.clients[viewer]; exists {
		t.Fatal("stalled viewer remained registered for later sequences")
	}
	if session.sequence != 1 || len(session.replay) != 1 {
		t.Fatalf("output was not retained for reconnect: sequence=%d replay=%d", session.sequence, len(session.replay))
	}
}

func TestOldOutputCursorForcesCleanReplay(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), sequence: 11,
		replay: []record{{sequence: 10, data: []byte("\x1b[2Jscreen")}, {sequence: 11, data: []byte(" tail")}},
	}
	viewer, frames, outputReset, _ := session.attach(3, 0, true)
	defer session.detach(viewer)
	if !outputReset || len(frames) < 2 {
		t.Fatalf("old cursor did not force replay reset: reset=%v frames=%d", outputReset, len(frames))
	}
	sequence, output, err := protocol.ParseOutput(frames[0])
	if err != nil || sequence != 10 ||
		(!bytes.HasPrefix(output, []byte("\x1bc")) && !bytes.HasPrefix(output, []byte("\x1b[2J"))) {
		t.Fatalf("clean replay was not emitted: sequence=%d output=%q err=%v", sequence, output, err)
	}
}

func TestTerminalOnlyAttachExcludesAgentHistory(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeAgentRoots: map[string][]byte{"codex:1": []byte(`{"agent":"codex","event":{"hook_event_name":"SessionStart"}}`)},
		activeSubagents:  make(map[string][]byte),
		eventSequence:    1,
		eventHistory: []protocol.Frame{{
			Type: protocol.AgentEvent, Payload: indexedAgentPayload([]byte(`{"agent":"codex","event":{"hook_event_name":"PreToolUse"}}`), 1),
		}},
	}
	viewer, frames, _, eventReset := session.attach(0, 0, false)
	defer session.detach(viewer)
	if eventReset {
		t.Fatal("terminal-only attach reported an irrelevant agent reset")
	}
	for _, frame := range frames {
		if frame.Type == protocol.AgentEvent {
			t.Fatal("terminal-only attach replayed agent history")
		}
	}
}

func TestOldAgentCursorGetsStateSnapshot(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeAgentRoots: map[string][]byte{"codex:42": []byte(`{"agent":"codex","event":{"hook_event_name":"SessionStart","root_id":"codex:42"}}`)},
		activeSubagents:  map[string][]byte{"codex\x00child": []byte(`{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"child"}}`)},
		eventSequence:    7,
		eventHistory:     []protocol.Frame{{Type: protocol.AgentEvent, Payload: indexedAgentPayload([]byte(`{"agent":"codex","event":{"hook_event_name":"PreToolUse"}}`), 6)}},
	}
	observer, frames, reset := session.observeAgents(1)
	defer session.detachAgentObserver(observer)
	if !reset || len(frames) < 2 || !bytes.Contains(frames[0].Payload, []byte(`"RelayStateSnapshot"`)) ||
		!bytes.Contains(frames[0].Payload, []byte(`"root_id":"codex:42"`)) ||
		!bytes.Contains(frames[0].Payload, []byte(`"agent_id":"child"`)) {
		t.Fatalf("agent gap did not return active state: reset=%v frames=%#v", reset, frames)
	}
}

func TestTranscriptReaderSkipsOversizedRecordAndContinues(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	oversized := bytes.Repeat([]byte("x"), maxTranscriptRecordBytes+1024)
	data := append(append(oversized, '\n'), []byte(`{"type":"valid"}`)...)
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	var offset int64
	var discarding bool
	var identity [2]uint64
	var lines [][]byte
	readTranscriptLines(path, &offset, &discarding, &identity, func(line []byte) {
		lines = append(lines, append([]byte(nil), line...))
	})
	if len(lines) != 1 || string(lines[0]) != `{"type":"valid"}` || offset != int64(len(data)) || discarding {
		t.Fatalf("reader did not recover after oversized row: lines=%q offset=%d discard=%v", lines, offset, discarding)
	}
}

func TestTranscriptReaderCommitsGrowingOversizedRecord(t *testing.T) {
	path := filepath.Join(t.TempDir(), "growing.jsonl")
	oversized := bytes.Repeat([]byte("x"), maxTranscriptRecordBytes+1024)
	if err := os.WriteFile(path, oversized, 0o600); err != nil {
		t.Fatal(err)
	}
	var offset int64
	var discarding bool
	var identity [2]uint64
	readTranscriptLines(path, &offset, &discarding, &identity, func([]byte) {})
	if offset != int64(len(oversized)) || !discarding {
		t.Fatalf("growing oversized record was not committed: offset=%d discard=%v", offset, discarding)
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("\n{\"type\":\"valid\"}\n"); err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	var lines [][]byte
	readTranscriptLines(path, &offset, &discarding, &identity, func(line []byte) {
		lines = append(lines, append([]byte(nil), line...))
	})
	if len(lines) != 1 || string(lines[0]) != `{"type":"valid"}` || discarding {
		t.Fatalf("reader did not resume after growing oversized row: lines=%q discard=%v", lines, discarding)
	}
}

func TestIndexedAgentPayloadDropsRawToolAndPromptData(t *testing.T) {
	payload := indexedAgentPayload([]byte(`{"agent":"codex","event":{"hook_event_name":"PreToolUse","tool_name":"exec_command","tool_input":{"command":"echo bearer-secret"},"prompt":"private prompt","message":"safe summary"}}`), 1)
	if bytes.Contains(payload, []byte("bearer-secret")) || bytes.Contains(payload, []byte("private prompt")) {
		t.Fatalf("raw provider payload leaked into indexed event: %s", payload)
	}
	if !bytes.Contains(payload, []byte(`"tool_name":"exec_command"`)) || !bytes.Contains(payload, []byte(`"message":"safe summary"`)) {
		t.Fatalf("structured provider fields were removed: %s", payload)
	}
}

func TestCodexPeerDirectionsAndInterruptions(t *testing.T) {
	outbound := []byte(`{"timestamp":"2026-08-25T14:41:32Z","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/worker","content":[{"text":"Message Type: MESSAGE\nPayload:\nCheck the edge case."}]}}`)
	events := codexTranscriptEvents(outbound)
	if len(events) != 1 || events[0].Event.HookEventName != "PeerMessage" ||
		events[0].Event.FromPeerID != "/root" || events[0].Event.ToPeerID != "/root/worker" {
		t.Fatalf("outbound peer message was not preserved: %#v", events)
	}
	interrupted := []byte(`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"SubAgentActivity","kind":"interrupted","agent_path":"/root/worker"}}}`)
	events = codexTranscriptEvents(interrupted)
	if len(events) != 1 || events[0].Event.HookEventName != "SubagentStop" || events[0].Event.Status != "interrupted" {
		t.Fatalf("interrupted peer was not captured: %#v", events)
	}
}

func TestCodexPeerMessageOmitsInternalHookContext(t *testing.T) {
	message := codexCollaboratorMessage("Message Type: MESSAGE\nPayload:\nUseful result.\n  hook context: [internal]\n    hidden")
	if message != "Useful result." {
		t.Fatalf("internal hook context leaked into peer message: %q", message)
	}
}

func TestClaudePeerToolMessage(t *testing.T) {
	line := []byte(`{"timestamp":"2026-08-25T14:41:32Z","type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage","input":{"recipient":"researcher","message":"Check chromosome 1."}}]}}`)
	events := claudeTranscriptEvents(line)
	if len(events) != 1 || events[0].Event.HookEventName != "PeerMessage" ||
		events[0].Event.FromPeerID != "claude-root" || events[0].Event.ToPeerID != "researcher" {
		t.Fatalf("Claude peer message was not captured: %#v", events)
	}
}

func TestClaudeCapturesEveryPeerToolMessage(t *testing.T) {
	line := []byte(`{"timestamp":"2026-08-25T14:41:32Z","type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage","input":{"recipient":"one","message":"First"}},{"type":"tool_use","name":"SendMessage","input":{"recipient":"two","message":"Second"}}]}}`)
	events := claudeTranscriptEvents(line)
	if len(events) != 2 || events[0].Event.ToPeerID != "one" || events[1].Event.ToPeerID != "two" {
		t.Fatalf("Claude peer message batch was incomplete: %#v", events)
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

	observer, snapshot, _ := session.observeAgents(0)
	defer session.detachAgentObserver(observer)
	if len(snapshot) != 4 || !bytes.Contains(snapshot[0].Payload, []byte(`"RelayStateSnapshot"`)) {
		t.Fatalf("observer snapshot has %d frames, want state plus complete indexed history", len(snapshot))
	}
	if indexedAgentSequence(snapshot[1].Payload) != 1 || indexedAgentSequence(snapshot[3].Payload) != 3 {
		t.Fatalf("observer history is not indexed: %#v", snapshot)
	}
	cursorObserver, cursorSnapshot, _ := session.observeAgents(2)
	defer session.detachAgentObserver(cursorObserver)
	if len(cursorSnapshot) != 1 || indexedAgentSequence(cursorSnapshot[0].Payload) != 3 {
		t.Fatalf("cursor replay returned the wrong suffix: %#v", cursorSnapshot)
	}

	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"research-1"}}`))
	secondObserver, secondSnapshot, _ := session.observeAgents(3)
	defer session.detachAgentObserver(secondObserver)
	if len(secondSnapshot) != 1 || !bytes.Contains(secondSnapshot[0].Payload, []byte(`"SubagentStop"`)) {
		t.Fatalf("new lifecycle event was not replayed after cursor: %#v", secondSnapshot)
	}
}

func TestEndingOneProviderRootPreservesOtherRootAndChildren(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), activeAgentRoots: make(map[string][]byte),
		eventHashes: make(map[[32]byte]struct{}),
	}
	session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"SessionStart","root_id":"codex:1"}}`))
	session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"SessionStart","root_id":"codex:2"}}`))
	session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"SubagentStart","agent_id":"worker"}}`))
	session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"SessionEnd","root_id":"codex:1"}}`))
	if len(session.activeAgentRoots) != 1 || len(session.activeSubagents) != 1 {
		t.Fatalf("ending one root removed live provider state: roots=%d children=%d", len(session.activeAgentRoots), len(session.activeSubagents))
	}
	session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"SessionEnd","root_id":"codex:2"}}`))
	if len(session.activeAgentRoots) != 0 || len(session.activeSubagents) != 0 {
		t.Fatalf("ending the last root retained stale state: roots=%d children=%d", len(session.activeAgentRoots), len(session.activeSubagents))
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

func TestShellIntegrationsEnableSemanticPrompts(t *testing.T) {
	home := t.TempDir()
	shimDirectory := filepath.Join(home, "shims")

	bashPath, err := writeBashIntegration(home, shimDirectory)
	if err != nil {
		t.Fatal(err)
	}
	bashContents, err := os.ReadFile(bashPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{"133;A;redraw=last;cl=line", "133;B", "133;C", "133;D", "7;file://"} {
		if !strings.Contains(string(bashContents), marker) {
			t.Fatalf("bash integration is missing %q", marker)
		}
	}
	if bash, err := exec.LookPath("bash"); err == nil {
		if output, err := exec.Command(bash, "-n", bashPath).CombinedOutput(); err != nil {
			t.Fatalf("invalid bash integration: %v: %s", err, output)
		}
	}

	zshDirectory, err := writeZshIntegration(home, shimDirectory)
	if err != nil {
		t.Fatal(err)
	}
	zshPath := filepath.Join(zshDirectory, ".zshrc")
	zshContents, err := os.ReadFile(zshPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{"133;A;cl=line", "133;B", "133;C", "133;D"} {
		if !strings.Contains(string(zshContents), marker) {
			t.Fatalf("zsh integration is missing %q", marker)
		}
	}
	if zsh, err := exec.LookPath("zsh"); err == nil {
		if output, err := exec.Command(zsh, "-n", zshPath).CombinedOutput(); err != nil {
			t.Fatalf("invalid zsh integration: %v: %s", err, output)
		}
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
