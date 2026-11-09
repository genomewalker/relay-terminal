package daemon

import (
	"bytes"
	"github.com/creack/pty"
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

func TestSessionDefaultsToHomeDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SHELL", "/bin/sh")
	session, err := startSession("home-default-test", "true", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.pty.Close()
	if session.process.Dir != home {
		t.Fatalf("working directory = %q, want home %q", session.process.Dir, home)
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

func TestBlockedAcknowledgedInputDoesNotHoldSessionStateLock(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	session := &Session{pty: writer, inputSequences: make(map[[16]byte]uint64)}
	started := make(chan struct{})
	finished := make(chan error, 1)
	go func() {
		close(started)
		finished <- session.acknowledgedInput([16]byte{1}, 1, bytes.Repeat([]byte("x"), 8<<20))
	}()
	<-started
	// Give the pipe enough time to fill so the PTY writer is definitely blocked.
	time.Sleep(25 * time.Millisecond)
	snapshot := make(chan struct{})
	go func() {
		session.snapshot()
		close(snapshot)
	}()
	select {
	case <-snapshot:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("a blocked PTY write held the session state lock")
	}
	_ = reader.Close()
	_ = writer.Close()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("blocked input writer did not stop after its pipe closed")
	}
}

func TestAcknowledgedInputDoesNotForgetOlderClientHighWater(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{pty: writer, inputSequences: make(map[[16]byte]uint64)}
	const clients = 128
	for index := 0; index < clients; index++ {
		clientID := [16]byte{byte(index), byte(index >> 8), 0xA5}
		if err := session.acknowledgedInput(clientID, 1, []byte{'x'}); err != nil {
			t.Fatal(err)
		}
	}
	for index := 0; index < clients; index++ {
		clientID := [16]byte{byte(index), byte(index >> 8), 0xA5}
		if err := session.acknowledgedInput(clientID, 1, []byte{'x'}); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != clients {
		t.Fatalf("old client dedupe state was evicted: got %d writes, want %d", len(data), clients)
	}
}

func TestWorkerOutputSequenceSpacesDoNotStartFromZero(t *testing.T) {
	first := outputSequenceFromEntropy(100)
	second := outputSequenceFromEntropy(10_000)
	if first < 1<<62 || second < 1<<62 || first == second {
		t.Fatalf("worker sequence epochs are not distinct high-water values: %d %d", first, second)
	}
	replay := []record{{sequence: second + 1, data: []byte("new shell")}}
	if !outputCursorNeedsReset(replay, first, second+1) {
		t.Fatal("cursor from an older worker aliased into the replacement worker")
	}
}

func TestEventCursorAheadOfRestartedWorkerRequestsReset(t *testing.T) {
	session := &Session{eventSequence: 10}
	if !session.eventCursorHasGap(500) {
		t.Fatal("event cursor from an older worker did not request a reset")
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
	if err := first.eventJournal.close(); err != nil {
		t.Fatal(err)
	}

	restored := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	if err := restored.enableEventJournal(path); err != nil {
		t.Fatal(err)
	}
	defer restored.eventJournal.close()
	observer, frames, _ := restored.observeAgents(1)
	defer restored.detachAgentObserver(observer)
	if restored.eventSequence != 2 || len(frames) != 1 || indexedAgentSequence(frames[0].Payload) != 2 {
		t.Fatalf("journal cursor was not restored: sequence=%d frames=%#v", restored.eventSequence, frames)
	}
}

type blockingAgentEventWriter struct {
	started chan struct{}
	release chan struct{}
}

func (journal *blockingAgentEventWriter) append(uint64, []byte) error {
	journal.started <- struct{}{}
	<-journal.release
	return nil
}

func (*blockingAgentEventWriter) close() error { return nil }

func TestBlockedAgentJournalDoesNotHoldTerminalStateLock(t *testing.T) {
	journal := &blockingAgentEventWriter{started: make(chan struct{}, 1), release: make(chan struct{})}
	session := &Session{
		eventJournal: journal,
		clients:      make(map[*client]struct{}),
		agentClients: make(map[*client]struct{}),
	}
	finished := make(chan struct{})
	go func() {
		session.agentEvent([]byte(`{"agent":"codex","event":{"type":"item.completed"}}`))
		close(finished)
	}()
	select {
	case <-journal.started:
	case <-time.After(time.Second):
		t.Fatal("agent event did not enter journal append")
	}
	snapshotDone := make(chan struct{})
	go func() {
		session.snapshot()
		close(snapshotDone)
	}()
	select {
	case <-snapshotDone:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("blocked journal append held terminal session state")
	}
	close(journal.release)
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("agent event did not resume after journal became writable")
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

func TestReplayStartRetainsVisibleCellsBeforeScrollbackErase(t *testing.T) {
	stream := []byte("visible transcript\x1b[3J\x1b[Hpartial update")
	if got := safePrimaryScreenReplayStart(stream); got != -1 {
		t.Fatalf("scrollback erase discarded visible cell history at %d", got)
	}
}

func TestReplayStartDoesNotCutIntoAlternateScreen(t *testing.T) {
	replay := []record{
		{sequence: 1, data: []byte("old\x1b[2Jshell prompt")},
		{sequence: 2, data: []byte("\x1b[?1049h\x1b[2Jhtop")},
		{sequence: 3, data: []byte("\x1b[?1049lafter")},
	}

	recordIndex, byteOffset := replayStart(replay, 0)
	if recordIndex != 0 || byteOffset != len("old") {
		t.Fatalf("alternate screen lost its primary owner: start=(%d, %d)", recordIndex, byteOffset)
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
	viewer, frames, outputReset, _, _ := session.attach(3, 0, true)
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
	viewer, frames, _, eventReset, _ := session.attach(0, 0, false)
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

func TestTerminalClientCountTracksAttachAndDetach(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), activeAgentRoots: make(map[string][]byte),
	}
	first, _, _, _, firstCount := session.attach(0, 0, false)
	if firstCount != 1 {
		t.Fatalf("first client count = %d, want 1", firstCount)
	}
	second, _, _, _, secondCount := session.attach(0, 0, false)
	if secondCount != 2 {
		t.Fatalf("second client count = %d, want 2", secondCount)
	}
	if got := latestClientCount(first.frames); got != 2 {
		t.Fatalf("first viewer saw client count %d, want 2", got)
	}

	session.detach(second)
	if got := latestClientCount(first.frames); got != 1 {
		t.Fatalf("remaining viewer saw client count %d after detach, want 1", got)
	}
	session.detach(first)
}

func latestClientCount(frames <-chan protocol.Frame) int {
	latest := -1
	for {
		select {
		case frame := <-frames:
			if frame.Type != protocol.Status {
				continue
			}
			var status protocol.StatusPayload
			if protocol.DecodeJSON(frame, &status) == nil && status.State == "clients" {
				latest = status.ClientCount
			}
		default:
			return latest
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

// A pane opened from inside another pane inherits that pane's identity
// variables; the new pane must export only its own id under both names.
func TestSessionEnvironmentExportsOwnPaneID(t *testing.T) {
	const pane = "57c1dd5b-f283-4933-834b-d01625280261"
	const parent = "0e3d2a1c-0000-4000-8000-000000000001"
	environment := sessionEnvironment([]string{
		"HOME=/home/user", "RELAY_PANE_ID=" + parent, "RELAY_SESSION=" + parent, "PATH=/usr/bin",
	}, pane, "/shims")
	counts := make(map[string]int)
	values := make(map[string]string)
	for _, entry := range environment {
		name, value, _ := strings.Cut(entry, "=")
		counts[name]++
		values[name] = value
	}
	for _, name := range []string{"RELAY_PANE_ID", "RELAY_SESSION"} {
		if counts[name] != 1 || values[name] != pane {
			t.Fatalf("%s: count %d value %q, want exactly one %q in %q", name, counts[name], values[name], pane, environment)
		}
	}
	if values["HOME"] != "/home/user" {
		t.Fatalf("unrelated variable lost: %q", environment)
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
	command := exec.Command(bash, "--rcfile", rcPath, "-i", "-c", "type codex")
	command.Env = append(os.Environ(), "HOME="+home, "PATH="+realDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("bash integration failed: %v: %s", err, output)
	}
	if !strings.Contains(string(output), filepath.Join(shimDirectory, "codex")) {
		t.Fatalf("Relay shim did not win command lookup: %s", output)
	}
}

func TestBashCodexShimSurvivesEnvironmentPathReorder(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	home := t.TempDir()
	shimDirectory := filepath.Join(home, "relay shims")
	condaDirectory := filepath.Join(home, "environment")
	for directory, marker := range map[string]string{shimDirectory: "managed", condaDirectory: "unmanaged"} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, "codex"), []byte("#!/bin/sh\nprintf '"+marker+":%s\\n' \"$1\"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	rcPath, err := writeBashIntegration(home, shimDirectory)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(bash, "--rcfile", rcPath, "-i", "-c", "export PATH="+shellQuote(condaDirectory)+":$PATH; codex 'literal argument'")
	command.Env = append(os.Environ(), "HOME="+home)
	output, err := command.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "managed:literal argument") || strings.Contains(string(output), "unmanaged:") {
		t.Fatalf("environment bypassed the managed launcher: %v: %s", err, output)
	}
}

func TestBashSessionPreservesProfileFunctions(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	home := t.TempDir()
	profile := "relay_profile_function() { printf PROFILE_FUNCTION_OK; }\nexport PROMPT_COMMAND=relay_profile_function\n"
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte(profile), 0o600); err != nil {
		t.Fatal(err)
	}
	command, err := sessionCommand(bash, "", home, filepath.Join(home, "shims"))
	if err != nil {
		t.Fatal(err)
	}
	command.Args = append(command.Args, "-c", "relay_profile_function")
	command.Env = append(os.Environ(), "HOME="+home)
	output, err := command.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "PROFILE_FUNCTION_OK") {
		t.Fatalf("profile function lost: %v: %s", err, output)
	}
}

func TestBashSessionSourcesUserBashrcOnce(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte(". \"$HOME/.bashrc\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".bashrc"), []byte("RELAY_RC_COUNT=$(( ${RELAY_RC_COUNT:-0} + 1 ))\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command, err := sessionCommand(bash, "", home, filepath.Join(home, "shims"))
	if err != nil {
		t.Fatal(err)
	}
	command.Args = append(command.Args, "-c", "printf '%s' \"$RELAY_RC_COUNT\"")
	command.Env = append(os.Environ(), "HOME="+home)
	output, err := command.CombinedOutput()
	if err != nil || !strings.HasSuffix(strings.TrimSpace(string(output)), "1") {
		t.Fatalf("bashrc should run once: %v: %s", err, output)
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
	// Replacement behavior must not depend on the caller's login-shell startup.
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SHELL", "/bin/sh")
	first, err := startSession("restart-test", "", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer first.pty.Close()
	defer first.signal(15)
	// Startup commands return to the retained shell. Exit that shell itself.
	if _, err := first.pty.Write([]byte("exit 0\n")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
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

func TestIdleWorkerPollingBacksOffWithoutSlowingActiveAgents(t *testing.T) {
	if agentProcessPollInterval(0) != 5*time.Second {
		t.Fatal("idle process polling did not back off")
	}
	if agentProcessPollInterval(1) != time.Second {
		t.Fatal("active process polling lost its responsive interval")
	}
	if transcriptPollInterval(0, 0) != 5*time.Second ||
		transcriptPollInterval(1, 0) != 250*time.Millisecond ||
		transcriptPollInterval(1, 3) != 2*time.Second {
		t.Fatal("transcript polling policy is not activity-adaptive")
	}
	if workerManifestPollInterval(0) != 5*time.Second || workerManifestPollInterval(2) != 30*time.Second {
		t.Fatal("idle manifest persistence did not back off")
	}
}

func TestAgentProcessSnapshotBroadcastsOnlyRealChanges(t *testing.T) {
	session := &Session{
		agentProcesses:        map[int]string{41: "codex"},
		agentProcessesChanged: make(chan struct{}),
	}
	snapshot, changed := session.agentProcessSnapshot()
	snapshot[41] = "claude"
	if current, _ := session.agentProcessSnapshot(); current[41] != "codex" {
		t.Fatal("agent process snapshot exposed mutable session state")
	}
	session.updateAgentProcesses(map[int]string{41: "codex"})
	select {
	case <-changed:
		t.Fatal("unchanged process set triggered transcript work")
	default:
	}
	session.updateAgentProcesses(map[int]string{42: "claude"})
	select {
	case <-changed:
	case <-time.After(time.Second):
		t.Fatal("process change was not broadcast to transcript observers")
	}
}

func TestAttachRepaintNeverIntroducesAnotherGrid(t *testing.T) {
	unchanged := attachResizeSteps(120, 38, 120, 38, true)
	if len(unchanged) != 1 || unchanged[0] != (terminalGridSize{cols: 120, rows: 38}) {
		t.Fatalf("unchanged attach resize = %#v", unchanged)
	}
	changed := attachResizeSteps(80, 24, 120, 38, true)
	if len(changed) != 1 || changed[0] != (terminalGridSize{cols: 120, rows: 38}) {
		t.Fatalf("changed attach resize = %#v", changed)
	}
	if shell := attachResizeSteps(120, 38, 120, 38, false); len(shell) != 0 {
		t.Fatalf("unchanged shell attach unexpectedly pulsed: %#v", shell)
	}
}

func TestViewportResizeSignalsExactlyOnce(t *testing.T) {
	if viewportResizeNeedsExplicitSignal(80, 24, 120, 38, true) {
		t.Fatal("changed TIOCSWINSZ would receive a duplicate explicit SIGWINCH")
	}
	if !viewportResizeNeedsExplicitSignal(120, 38, 120, 38, true) {
		t.Fatal("unchanged viewport commit did not request its explicit SIGWINCH")
	}
	if !viewportResizeNeedsExplicitSignal(0, 0, 120, 38, false) {
		t.Fatal("unknown current viewport did not request a safe explicit SIGWINCH")
	}
}

// bashPromptMarkers runs three prompts in a Relay bash session with bashrc
// and counts the prompt-start and input-start markers it printed.
func bashPromptMarkers(t *testing.T, bashrc string) (starts, inputs int, output string) {
	t.Helper()
	output = bashSessionOutput(t, bashrc, "true\ntrue\nexit\n")
	return strings.Count(output, "\x1b]133;A;"), strings.Count(output, "\x1b]133;B\a"), output
}

// bashSessionOutput types input into a Relay bash session with bashrc and
// returns everything it wrote.
func bashSessionOutput(t *testing.T, bashrc, input string) string {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	requireBash44(t, bash)
	return bashSessionOutputWith(t, bash, map[string]string{".bashrc": bashrc}, input)
}

// The integration needs Bash 4.4 or later.
func requireBash44(t *testing.T, bash string) {
	t.Helper()
	if exec.Command(bash, "-c", "(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))").Run() != nil {
		t.Skip("bash is older than 4.4")
	}
}

// bashSessionOutputWith runs bash with the given home files.
func bashSessionOutputWith(t *testing.T, bash string, files map[string]string, input string) string {
	t.Helper()
	home := t.TempDir()
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(home, name), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	command, err := sessionCommand(bash, "", home, filepath.Join(home, "shims"))
	if err != nil {
		t.Fatal(err)
	}
	// The test runner's own prompt settings must not reach the session.
	for _, entry := range os.Environ() {
		if name, _, _ := strings.Cut(entry, "="); name != "PROMPT_COMMAND" && name != "PS0" && name != "PS1" && name != "BASH_ENV" {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "HOME="+home)
	command.Stdin = strings.NewReader(input)
	raw, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("bash session failed: %v: %q", err, raw)
	}
	return string(raw)
}

// Each command is marked started, then finished with its own status, in the
// shell's output itself (no terminal is needed for PS0).
func TestBashMarksEachCommandStartedAndFinished(t *testing.T) {
	for name, bashrc := range map[string]string{
		"plain":        "",
		"bash-preexec": bashPreexecReplacingPromptCommand,
	} {
		t.Run(name, func(t *testing.T) {
			output := bashSessionOutput(t, bashrc, "true\nfalse\n(exit 7)\nexit 0\n")
			starts := strings.Count(output, "\x1b]133;C\a")
			finished := []string{"\x1b]133;D;0\a", "\x1b]133;D;1\a", "\x1b]133;D;7\a"}
			last := -1
			for _, marker := range finished {
				index := strings.Index(output, marker)
				if index <= last || strings.Count(output, marker) != 1 {
					t.Fatalf("want %q once, after the previous command: %q", marker, output)
				}
				last = index
			}
			// The started mark adds nothing visible around a silent command.
			if !strings.Contains(output, "true\n\x1b]133;C\a\x1b]133;D;0\a") {
				t.Fatalf("stray output around the started mark: %q", output)
			}
			// Started: the three commands and the final exit.
			if starts != 4 || strings.Count(output, "\x1b]133;D;") != 3 {
				t.Fatalf("starts %d (want 4), finishes %d (want 3): %q", starts, strings.Count(output, "\x1b]133;D;"), output)
			}
		})
	}
}

// An empty command line runs nothing, so it is not reported as finished.
func TestBashDoesNotFinishAnEmptyCommandLine(t *testing.T) {
	output := bashSessionOutput(t, "", "\ntrue\n\ntrue\nexit 0\n")
	if strings.Count(output, "\x1b]133;D;") != 2 {
		t.Fatalf("want two finished commands: %q", output)
	}
}

// Old bash-preexec releases replace PROMPT_COMMAND when they install at the
// first prompt, and their install adds a user precmd that may rewrite PS1.
const bashPreexecReplacingPromptCommand = `
__bp_imported=defined
__bp_set_ret_value() { return "${1:-0}"; }
__bp_precmd_invoke_cmd() {
    local status=$? hook
    for hook in "${precmd_functions[@]}"; do __bp_set_ret_value "$status"; "$hook"; done
}
__bp_interactive_mode() { :; }
__bp_install() {
    [[ "$PROMPT_COMMAND" == *__bp_precmd_invoke_cmd* ]] && return 1
    PROMPT_COMMAND="__bp_precmd_invoke_cmd; __bp_interactive_mode"
    precmd_functions+=(precmd)
    eval "$PROMPT_COMMAND"
}
PROMPT_COMMAND=$'\n__bp_install\n'
precmd() { PS1='user$ '; }
`

func TestBashPromptMarkersSurviveBashPreexecReplacingPromptCommand(t *testing.T) {
	starts, inputs, output := bashPromptMarkers(t, bashPreexecReplacingPromptCommand)
	// The first prompt runs the user's precmd after the hook; it is moved
	// last from then on.
	if starts != 3 || inputs != 2 {
		t.Fatalf("prompt starts %d (want 3), marked inputs %d (want 2): %q", starts, inputs, output)
	}
}

func TestBashPromptMarkersRunOnceWithVendoredBashPreexec(t *testing.T) {
	preexec, err := filepath.Abs("../../../../Vendor/libghostty-spm/Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/bash-preexec.sh")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(preexec); err != nil {
		t.Skip("vendored bash-preexec is not in this tree")
	}
	starts, inputs, output := bashPromptMarkers(t, ". "+shellQuote(preexec)+"\n")
	if starts != 3 || inputs != 3 {
		t.Fatalf("prompt starts %d, marked inputs %d, want 3 each: %q", starts, inputs, output)
	}
}

func TestBashPromptMarkersWithoutBashPreexec(t *testing.T) {
	starts, inputs, output := bashPromptMarkers(t, "PROMPT_COMMAND='USER_HOOK=1'\n")
	if starts != 3 || inputs != 3 {
		t.Fatalf("prompt starts %d, marked inputs %d, want 3 each: %q", starts, inputs, output)
	}
}

func TestStartupCommandReturnsToInteractiveShell(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	for _, startup := range []string{"printf AGENT_FINISHED", "exec printf AGENT_FINISHED", "exit 7"} {
		t.Run(startup, func(t *testing.T) {
			home := t.TempDir()
			cmd, err := sessionCommand(bash, startup, home, filepath.Join(home, "shims"))
			if err != nil {
				t.Fatal(err)
			}
			cmd.Env = append(os.Environ(), "HOME="+home)
			cmd.Stdin = strings.NewReader("printf SHELL_RETURNED\\n\nexit\n")
			output, err := cmd.CombinedOutput()
			if err != nil || !strings.Contains(string(output), "SHELL_RETURNED") {
				t.Fatalf("startup consumed the pane shell: %v: %s", err, output)
			}
		})
	}
}

func TestPromptEditorLaunchSettingDefaultsOnlyNewShellEnvironment(t *testing.T) {
	cases := []struct {
		environment []string
		want        string
	}{
		{nil, "1"},
		{[]string{"UNCHANGED=yes"}, "1"},
		{[]string{"RELAY_PROMPT_EDITOR_ENABLE=0"}, "0"},
		{[]string{"RELAY_PROMPT_EDITOR_ENABLE="}, ""},
		{[]string{"RELAY_PROMPT_EDITOR_ENABLE=1"}, "1"},
	}
	for _, test := range cases {
		if got := promptEditorLaunchSetting(test.environment); got != test.want {
			t.Fatalf("launch setting for %v = %q, want %q", test.environment, got, test.want)
		}
	}
}

// A pane shell started by a relayd that was itself launched from a Claude Code
// session does not inherit that session's markers.
func TestSessionShellDoesNotInheritClaudeSessionMarkers(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_CHILD_SESSION", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "inherited-session")
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude-max"))
	output := filepath.Join(home, "env.txt")
	session, err := startSession("claude-marker-test", "env > "+output+".tmp && mv "+output+".tmp "+output, "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.pty.Close()
	deadline := time.Now().Add(10 * time.Second)
	var data []byte
	for {
		if data, err = os.ReadFile(output); err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	// The shell's environment holds the developer's own variables, credentials
	// included: failures name variables, never print values.
	for _, line := range strings.Split(string(data), "\n") {
		if name, _, _ := strings.Cut(line, "="); name == "CLAUDECODE" || strings.HasPrefix(name, "CLAUDE_CODE_") {
			t.Fatalf("pane shell inherited %s", name)
		}
	}
	for _, setting := range []string{"CLAUDE_CONFIG_DIR=" + filepath.Join(home, ".claude-max"), "RELAY_SESSION=claude-marker-test"} {
		if !strings.Contains("\n"+string(data), "\n"+setting+"\n") {
			name, _, _ := strings.Cut(setting, "=")
			t.Fatalf("pane environment lost its own %s", name)
		}
	}
}

// A user profile shaped like a real one: it prepends commands that reset $?
// (history -a/-c/-r and a logging function) to PROMPT_COMMAND, and its
// bashrc appends a hook that preserves $? and installs a DEBUG trap.
var promptStatusUserFiles = map[string]string{
	".bash_profile": `
run_on_prompt_command() { builtin printf '%s\n' "$PWD" >> "$HOME/.persistent_history"; }
export PROMPT_COMMAND="history -a; history -c; history -r; run_on_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
`,
	".bashrc": `
__sqz_preexec() { :; }
__sqz_postexec() { local status=$?; return $status; }
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__sqz_postexec"
trap '__sqz_preexec' DEBUG
`,
}

func commandStatuses(output string) []string {
	var statuses []string
	for _, part := range strings.Split(output, "\x1b]133;D;")[1:] {
		status, _, _ := strings.Cut(part, "\a")
		statuses = append(statuses, status)
	}
	return statuses
}

// The finished mark reports the command's own status even when the user's
// PROMPT_COMMAND runs commands that reset $? before Relay's hook.
func TestBashReportsCommandStatusDespiteUserPromptCommands(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	requireBash44(t, bash)
	for name, files := range map[string]map[string]string{
		"history-prepend": promptStatusUserFiles,
		// A first user entry that reads $? must still see the command's status.
		"status-reading-user-entry": {".bashrc": `PROMPT_COMMAND='builtin printf "first-entry-saw:%s;" "$?"'` + "\n"},
		"array-prompt-command":      {".bashrc": `PROMPT_COMMAND=('history -a' 'true')` + "\n"},
		"bash-preexec":              {".bashrc": bashPreexecReplacingPromptCommand + "PROMPT_COMMAND=\"history -a; $PROMPT_COMMAND\"\n"},
	} {
		t.Run(name, func(t *testing.T) {
			output := bashSessionOutputWith(t, bash, files, "false\nsh -c 'exit 7'\ntrue\n(exit 3)\nexit 0\n")
			if got := commandStatuses(output); strings.Join(got, ",") != "1,7,0,3" {
				t.Fatalf("finished statuses %v, want [1 7 0 3]: %q", got, output)
			}
			if name == "status-reading-user-entry" {
				var seen []string
				for _, part := range strings.Split(output, "first-entry-saw:")[1:] {
					status, _, _ := strings.Cut(part, ";")
					seen = append(seen, status)
				}
				// Relay's capture must not change $? for the user's own entry.
				// The startup prompt sees 0 first, then each command's status.
				if strings.Join(seen, ",") != "0,1,7,0,3" {
					t.Fatalf("user entry saw %v, want [0 1 7 0 3]: %q", seen, output)
				}
			}
		})
	}
}

// A command prepended to PROMPT_COMMAND after Relay's setup (by a tool loaded
// later, or typed) can reset $? once; the hook moves the capture back in front
// for every later prompt, without duplicating it.
func TestBashStatusCaptureReassertsAfterALatePrepend(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	requireBash44(t, bash)
	input := "PROMPT_COMMAND=\"history -a; $PROMPT_COMMAND\"\nfalse\nsh -c 'exit 7'\ntrue\n" +
		"builtin printf 'captures:%s;' \"$(builtin printf '%s' \"$PROMPT_COMMAND\" | grep -o __relay_capture_status | wc -l | tr -d ' ')\"\nexit 0\n"
	output := bashSessionOutputWith(t, bash, map[string]string{".bashrc": "PROMPT_COMMAND='history -a'\n"}, input)
	if got := commandStatuses(output); strings.Join(got, ",") != "0,1,7,0,0" {
		t.Fatalf("finished statuses %v, want [0 1 7 0 0]: %q", got, output)
	}
	if !strings.Contains(output, "captures:1;") {
		t.Fatalf("status capture duplicated or lost: %q", output)
	}
}

// The vendored bash-preexec passes the real status to precmd functions; the
// finished marks stay correct with a status-resetting entry beside it.
func TestBashReportsCommandStatusWithVendoredBashPreexec(t *testing.T) {
	preexec, err := filepath.Abs("../../../../Vendor/libghostty-spm/Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/bash-preexec.sh")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(preexec); err != nil {
		t.Skip("vendored bash-preexec is not in this tree")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	requireBash44(t, bash)
	bashrc := ". " + shellQuote(preexec) + "\nPROMPT_COMMAND=\"history -a; ${PROMPT_COMMAND}\"\n"
	output := bashSessionOutputWith(t, bash, map[string]string{".bashrc": bashrc}, "false\nsh -c 'exit 7'\ntrue\n(exit 3)\nexit 0\n")
	if got := commandStatuses(output); strings.Join(got, ",") != "1,7,0,3" {
		t.Fatalf("finished statuses %v, want [1 7 0 3]: %q", got, output)
	}
}

// macOS /bin/bash 3.2 predates the integration (4.4+); it must still start
// cleanly with the generated rc and the user profile.
func TestBashIntegrationIsQuietOnBash32(t *testing.T) {
	const bash32 = "/bin/bash"
	if exec.Command(bash32, "-c", "(( BASH_VERSINFO[0] == 3 ))").Run() != nil {
		t.Skip("no bash 3 at /bin/bash")
	}
	output := bashSessionOutputWith(t, bash32, promptStatusUserFiles, "false\necho done-$?\nexit 0\n")
	if !strings.Contains(output, "done-1") || strings.Contains(output, "syntax error") ||
		strings.Contains(output, "bad substitution") || strings.Contains(output, "__relay") {
		t.Fatalf("bash 3.2 session: %q", output)
	}
}

// zshSessionOutput types input into a Relay zsh session on a pseudo-terminal
// (the zsh integration writes its marks to /dev/tty) and returns its output.
func zshSessionOutput(t *testing.T, zshrc, input string) string {
	t.Helper()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh is not installed")
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte(zshrc), 0o600); err != nil {
		t.Fatal(err)
	}
	command, err := sessionCommand(zsh, "", home, filepath.Join(home, "shims"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range os.Environ() {
		if name, _, _ := strings.Cut(entry, "="); name != "ZDOTDIR" && name != "PS1" && name != "PROMPT" && name != "RPROMPT" {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "HOME="+home, "TERM=xterm-256color")
	terminal, err := pty.StartWithSize(command, &pty.Winsize{Cols: 200, Rows: 50})
	if err != nil {
		t.Fatal(err)
	}
	defer terminal.Close()
	output := make(chan string, 1)
	go func() {
		var all []byte
		buffer := make([]byte, 4096)
		for {
			n, err := terminal.Read(buffer)
			all = append(all, buffer[:n]...)
			if err != nil {
				output <- string(all)
				return
			}
		}
	}()
	// Type one line per prompt: wait for each input-start mark first.
	for _, line := range strings.SplitAfter(input, "\n") {
		if line == "" {
			continue
		}
		time.Sleep(300 * time.Millisecond)
		if _, err := terminal.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		_ = command.Process.Signal(os.Interrupt)
		t.Fatal("zsh session did not exit")
	}
	select {
	case text := <-output:
		return text
	case <-time.After(5 * time.Second):
		t.Fatal("zsh output did not close")
	}
	return ""
}

// zsh runs other precmd functions before Relay's; one that runs a command
// must not replace the finished command's status.
func TestZshReportsCommandStatusDespiteUserPrecmd(t *testing.T) {
	for name, zshrc := range map[string]string{
		"plain":           "",
		"history-precmd":  "setopt INC_APPEND_HISTORY\nHISTFILE=$HOME/.zsh_history\nuser_precmd() { fc -AI; true; }\nprecmd_functions+=(user_precmd)\n",
		"precmd-function": "precmd() { true; }\n",
	} {
		t.Run(name, func(t *testing.T) {
			output := zshSessionOutput(t, zshrc, "false\nsh -c 'exit 7'\ntrue\n(exit 3)\nexit 0\n")
			if got := commandStatuses(output); strings.Join(got, ",") != "1,7,0,3" {
				t.Fatalf("finished statuses %v, want [1 7 0 3]: %q", got, output)
			}
		})
	}
}

// Before bash 5.1 an array PROMPT_COMMAND runs only element [0]. Relay must
// extend [0] as a string, never shift the user's command to [1]. Bash 5.1+
// runs every element, so this test forces the pre-5.1 decision and then runs
// [0] alone, as old bash would.
func TestBashPre51ArrayPromptCommandKeepsUserEntryRunnable(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	requireBash44(t, bash)
	bashrc := "__relay_prompt_command_array=0\n" +
		`PROMPT_COMMAND=('builtin printf "user-ran:%s;" "$?"' 'builtin printf element-one;')` + "\n"
	input := "true\ntrue\nbuiltin declare -p PROMPT_COMMAND\n" +
		"false; eval \"${PROMPT_COMMAND[0]}\"\nexit 0\n"
	output := bashSessionOutputWith(t, bash, map[string]string{".bashrc": bashrc}, input)
	want := `declare -a PROMPT_COMMAND=([0]="__relay_capture_status;builtin printf \"user-ran:%s;\" \"\$?\";__relay_prompt_hook 2>/dev/null" [1]="builtin printf element-one;")`
	if !strings.Contains(output, want) {
		t.Fatalf("pre-5.1 PROMPT_COMMAND layout changed; want %s in %q", want, output)
	}
	// Running [0] alone after `false` reports 1 and still runs the user's entry
	// with the command's status.
	if !strings.Contains(output, "user-ran:1;") || !strings.Contains(output, "\x1b]133;D;1\a") {
		t.Fatalf("element [0] alone lost the user's entry or the status: %q", output)
	}
}
