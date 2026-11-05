package daemon

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/programstatus"
	"github.com/relay-terminal/relayd/internal/protocol"
)

var (
	reexecBinaryOnce sync.Once
	reexecBinary     string
	reexecBinaryErr  error
)

// buildRelaydForReexec builds the real relayd once per test binary; workers in
// these tests run the shipped entry point, not a test double.
func buildRelaydForReexec(t *testing.T) string {
	t.Helper()
	reexecBinaryOnce.Do(func() {
		// A prebuilt relayd lets a cross-compiled test binary run on a host
		// without a Go toolchain (`go test -c` with GOOS=linux).
		if prebuilt := os.Getenv("RELAYD_REEXEC_TEST_BINARY"); prebuilt != "" {
			directory, err := os.MkdirTemp("", "relayd-reexec-bin-")
			if err != nil {
				reexecBinaryErr = err
				return
			}
			reexecBinary = filepath.Join(directory, "relayd")
			data, err := os.ReadFile(prebuilt)
			if err == nil {
				err = os.WriteFile(reexecBinary, data, 0o755)
			}
			reexecBinaryErr = err
			return
		}
		directory, err := os.MkdirTemp("", "relayd-reexec-bin-")
		if err != nil {
			reexecBinaryErr = err
			return
		}
		_, file, _, _ := runtime.Caller(0)
		module := filepath.Join(filepath.Dir(file), "..", "..")
		reexecBinary = filepath.Join(directory, "relayd")
		build := exec.Command("go", "build", "-o", reexecBinary, "./cmd/relayd")
		build.Dir = module
		if output, err := build.CombinedOutput(); err != nil {
			reexecBinaryErr = fmt.Errorf("go build: %v\n%s", err, output)
		}
	})
	if reexecBinaryErr != nil {
		t.Fatal(reexecBinaryErr)
	}
	return reexecBinary
}

var (
	reexecNextOnce sync.Once
	reexecNext     string
	reexecNextErr  error
)

// buildNextRelaydForReexec builds relayd once more with a different version
// string: an upgrade target whose digest differs from the running image, so
// upgrade-workers re-executes instead of reporting the worker current.
func buildNextRelaydForReexec(t *testing.T) string {
	t.Helper()
	binary := buildRelaydForReexec(t)
	reexecNextOnce.Do(func() {
		reexecNext = filepath.Join(filepath.Dir(binary), "relayd-next-build")
		if prebuilt := os.Getenv("RELAYD_REEXEC_TEST_NEXT_BINARY"); prebuilt != "" {
			data, err := os.ReadFile(prebuilt)
			if err == nil {
				err = os.WriteFile(reexecNext, data, 0o755)
			}
			reexecNextErr = err
			return
		}
		if os.Getenv("RELAYD_REEXEC_TEST_BINARY") != "" {
			reexecNextErr = fmt.Errorf("RELAYD_REEXEC_TEST_NEXT_BINARY is required with RELAYD_REEXEC_TEST_BINARY")
			return
		}
		_, file, _, _ := runtime.Caller(0)
		build := exec.Command("go", "build", "-ldflags=-X main.relaydVersion=reexec-next", "-o", reexecNext, "./cmd/relayd")
		build.Dir = filepath.Join(filepath.Dir(file), "..", "..")
		if output, err := build.CombinedOutput(); err != nil {
			reexecNextErr = fmt.Errorf("go build: %v\n%s", err, output)
		}
	})
	if reexecNextErr != nil {
		t.Fatal(reexecNextErr)
	}
	return reexecNext
}

func TestMain(m *testing.M) {
	code := m.Run()
	if reexecBinary != "" {
		_ = os.RemoveAll(filepath.Dir(reexecBinary))
	}
	os.Exit(code)
}

// copyExecutable places the build at a second path, standing in for the
// newly installed relayd a worker upgrades into.
func copyExecutable(t *testing.T, source, target string) {
	t.Helper()
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0o755); err != nil {
		t.Fatal(err)
	}
}

type reexecWorker struct {
	stateDir string
	manifest workerManifest
	process  *exec.Cmd
}

// startReexecWorker launches `relayd worker` exactly as the daemon does: its
// own session, token in the environment, startup command in base64.
func startReexecWorker(t *testing.T, binary, command string) *reexecWorker {
	t.Helper()
	return startReexecWorkerProbed(t, binary, command, true)
}

// startReexecWorkerProbed with probe false waits only for the manifest, so
// the worker has not yet been asked for its image digest.
func startReexecWorkerProbed(t *testing.T, binary, command string, probe bool) *reexecWorker {
	t.Helper()
	root, err := os.MkdirTemp("", "rx")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	stateDir := filepath.Join(root, "workers")
	sessionID := "reexec-" + strconv.FormatInt(time.Now().UnixNano(), 36)
	token := strings.Repeat("ab", 24)
	socketPath := filepath.Join(root, "w.sock")
	manifestPath := filepath.Join(stateDir, sessionID+".json")
	child := exec.Command(binary, "worker", "--socket", socketPath, "--manifest", manifestPath,
		"--session", sessionID, "--cols", "80", "--rows", "24")
	child.Env = append(os.Environ(), "HOME="+root, "SHELL=/bin/sh", "XDG_STATE_HOME="+root,
		"RELAY_WORKER_TOKEN="+token,
		"RELAY_WORKER_COMMAND_B64="+base64.StdEncoding.EncodeToString([]byte(command)))
	child.Dir = root
	log, err := os.Create(filepath.Join(root, "worker.log"))
	if err != nil {
		t.Fatal(err)
	}
	child.Stdout, child.Stderr = log, log
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	worker := &reexecWorker{stateDir: stateDir, process: child}
	t.Cleanup(func() {
		_ = child.Process.Signal(syscall.SIGTERM)
		done := make(chan struct{})
		go func() { _ = child.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = child.Process.Kill()
		}
		if t.Failed() {
			data, _ := os.ReadFile(log.Name())
			t.Logf("worker log:\n%s", data)
		}
	})
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		manifest, err := loadManifest(manifestPath)
		if err == nil && manifest.Token == token {
			if !probe {
				worker.manifest = manifest
				return worker
			}
			if status, err := probeWorkerStatus(manifest); err == nil && status.State == "ready" {
				worker.manifest = manifest
				return worker
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("worker did not become ready")
	return nil
}

func (worker *reexecWorker) upgrade(t *testing.T, executable string) WorkerUpgradeResult {
	t.Helper()
	results, err := UpgradeWorkers(WorkerUpgradeOptions{
		StateDir: worker.stateDir, Executable: executable, Sessions: []string{worker.manifest.SessionID},
		Timeout: 20 * time.Second,
	})
	if err != nil || len(results) != 1 {
		t.Fatalf("upgrade-workers: %v %+v", err, results)
	}
	return results[0]
}

type reexecViewer struct {
	connection net.Conn
	attached   protocol.StatusPayload
	lastSeq    uint64
	output     []byte
}

func attachReexecViewer(t *testing.T, manifest workerManifest, lastSeq uint64) *reexecViewer {
	t.Helper()
	connection, err := net.DialTimeout("unix", manifest.SocketPath, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID, WorkerToken: manifest.Token,
		Cols: 80, Rows: 24, LastSeq: lastSeq, TerminalOnly: true, ClientID: "reexec-test",
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		t.Fatal(err)
	}
	viewer := &reexecViewer{connection: connection, lastSeq: lastSeq}
	_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status || protocol.DecodeJSON(frame, &viewer.attached) != nil ||
		viewer.attached.State != "attached" {
		t.Fatalf("attach: %v %+v", err, viewer.attached)
	}
	return viewer
}

// readUntil collects sequenced output until match holds; it fails on any
// sequence gap, which would mean output was lost.
func (viewer *reexecViewer) readUntil(t *testing.T, match func([]byte) bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !match(viewer.output) {
		if time.Now().After(deadline) {
			t.Fatalf("output never matched; have %q", tail(viewer.output))
		}
		_ = viewer.connection.SetReadDeadline(time.Now().Add(5 * time.Second))
		frame, err := protocol.ReadFrame(viewer.connection)
		if err != nil {
			t.Fatalf("viewer read: %v; have %q", err, tail(viewer.output))
		}
		if frame.Type != protocol.Output {
			continue
		}
		sequence, data, err := protocol.ParseOutput(frame)
		if err != nil || sequence == 0 {
			continue
		}
		if viewer.lastSeq != 0 && sequence != viewer.lastSeq+1 {
			t.Fatalf("output sequence jumped from %d to %d", viewer.lastSeq, sequence)
		}
		viewer.lastSeq = sequence
		viewer.output = append(viewer.output, data...)
	}
}

func tail(data []byte) []byte {
	if len(data) > 400 {
		return data[len(data)-400:]
	}
	return data
}

var tickPattern = regexp.MustCompile(`tick-(\d+)\r?\n`)

func ticks(output []byte) []int {
	var values []int
	for _, match := range tickPattern.FindAllSubmatch(output, -1) {
		value, _ := strconv.Atoi(string(match[1]))
		values = append(values, value)
	}
	return values
}

func ticksThrough(minimum int) func([]byte) bool {
	return func(output []byte) bool {
		values := ticks(output)
		return len(values) > 0 && values[len(values)-1] >= minimum
	}
}

// The shell's startup command prints a numbered line every 20 ms through the
// whole handoff, so lost, duplicated or reordered PTY output shows as a gap.
const reexecTickCommand = `i=0; while :; do i=$((i+1)); echo tick-$i; sleep 0.02; done`

// workerExecutablePath reports the image a process is running.
func workerExecutablePath(pid int) (string, error) {
	if path, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid)); err == nil {
		return path, nil
	}
	output, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func processParent(t *testing.T, pid int) int {
	t.Helper()
	output, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		t.Fatalf("ps %d: %v", pid, err)
	}
	parent, _ := strconv.Atoi(strings.TrimSpace(string(output)))
	return parent
}

func TestWorkerReexecPreservesShellPTYAndCursors(t *testing.T) {
	binary := buildRelaydForReexec(t)
	upgraded := filepath.Join(filepath.Dir(binary), "relayd-next")
	copyExecutable(t, buildNextRelaydForReexec(t), upgraded)
	worker := startReexecWorker(t, binary, reexecTickCommand)
	manifest := worker.manifest
	shellStart, err := processStartTime(manifest.ShellPID)
	if err != nil {
		t.Fatal(err)
	}

	viewer := attachReexecViewer(t, manifest, 0)
	viewer.readUntil(t, ticksThrough(5))
	before := viewer.lastSeq

	result := worker.upgrade(t, upgraded)
	if result.Result != "upgraded" || result.WorkerPID != manifest.WorkerPID {
		t.Fatalf("upgrade result: %+v", result)
	}

	// Same process, same kernel incarnation, same child shell.
	if start, err := processStartTime(manifest.WorkerPID); err != nil || start != manifest.WorkerStartTime {
		t.Fatalf("worker incarnation changed: %d %v", start, err)
	}
	if start, err := processStartTime(manifest.ShellPID); err != nil || start != shellStart {
		t.Fatalf("shell incarnation changed: %d %v", start, err)
	}
	if parent := processParent(t, manifest.ShellPID); parent != manifest.WorkerPID {
		t.Fatalf("shell parent is %d, want worker %d", parent, manifest.WorkerPID)
	}
	exe, err := workerExecutablePath(manifest.WorkerPID)
	if err == nil && exe != upgraded {
		if resolved, _ := filepath.EvalSymlinks(upgraded); exe != resolved {
			t.Fatalf("worker runs %q, want %q", exe, upgraded)
		}
	}
	reloaded, err := loadManifest(filepath.Join(worker.stateDir, manifest.SessionID+".json"))
	if err != nil || reloaded.ReexecOperation == "" || !reloaded.supports(workerReexecCapability) ||
		reloaded.WorkerPID != manifest.WorkerPID || reloaded.WorkerStartTime != manifest.WorkerStartTime ||
		reloaded.ShellPID != manifest.ShellPID || reloaded.Token != manifest.Token || !reloaded.CreatedAt.Equal(manifest.CreatedAt) {
		t.Fatalf("manifest after upgrade: %+v %v", reloaded, err)
	}
	if err := validateWorkerIdentity(reloaded); err != nil {
		t.Fatalf("upgraded worker fails identity validation: %v", err)
	}

	// The old connection closed at exec. Reconnecting from the old cursor is
	// an incremental attach: no reset, and the next record is before+1.
	resumed := attachReexecViewer(t, manifest, viewer.lastSeq)
	if resumed.attached.OutputReset {
		t.Fatal("reconnect after upgrade reset the output cursor")
	}
	resumed.output = viewer.output
	last := ticks(viewer.output)[len(ticks(viewer.output))-1]
	resumed.readUntil(t, ticksThrough(last+25))
	if resumed.lastSeq <= before {
		t.Fatalf("no output after upgrade: %d <= %d", resumed.lastSeq, before)
	}
	values := ticks(resumed.output)
	for index := 1; index < len(values); index++ {
		if values[index] != values[index-1]+1 {
			t.Fatalf("PTY output lost or duplicated across the handoff: tick-%d then tick-%d", values[index-1], values[index])
		}
	}

	// Typed input still reaches the same shell's terminal.
	writer := protocol.NewWriter(resumed.connection)
	if err := writer.Write(protocol.Frame{Type: protocol.Input, Payload: []byte("upgraded-input\r")}); err != nil {
		t.Fatal(err)
	}
	resumed.readUntil(t, func(output []byte) bool { return bytes.Contains(output, []byte("upgraded-input")) })

	// A second upgrade from the upgraded image works the same way.
	if again := worker.upgrade(t, binary); again.Result != "upgraded" {
		t.Fatalf("second upgrade: %+v", again)
	}
	if start, err := processStartTime(manifest.ShellPID); err != nil || start != shellStart {
		t.Fatalf("shell did not survive a second upgrade: %v", err)
	}
}

func TestWorkerReexecRefusalLeavesWorkerServing(t *testing.T) {
	binary := buildRelaydForReexec(t)
	worker := startReexecWorker(t, binary, reexecTickCommand)
	manifest := worker.manifest

	// An executable that cannot restore the state never receives the PTY;
	// every quiesce step is undone and the same image keeps serving.
	broken := filepath.Join(t.TempDir(), "relayd-broken")
	if err := os.WriteFile(broken, []byte("#!/bin/sh\nexit 3\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	result := worker.upgrade(t, broken)
	if result.Result != "refused" || !strings.Contains(result.Message, "cannot restore") {
		t.Fatalf("broken target: %+v", result)
	}
	if status, err := probeWorkerStatus(manifest); err != nil || status.State != "ready" || status.ReexecOperation != "" {
		t.Fatalf("worker after refused upgrade: %+v %v", status, err)
	}
	viewer := attachReexecViewer(t, manifest, 0)
	viewer.readUntil(t, ticksThrough(5))
	first := ticks(viewer.output)[len(ticks(viewer.output))-1]
	viewer.readUntil(t, ticksThrough(first+10))
	values := ticks(viewer.output)
	for index := 1; index < len(values); index++ {
		if values[index] != values[index-1]+1 {
			t.Fatalf("output gap after rollback: tick-%d then tick-%d", values[index-1], values[index])
		}
	}

	// The rollback restored the reader, accept loop, transcripts, persistence
	// and supervisor well enough for a real upgrade to follow.
	upgraded := filepath.Join(t.TempDir(), "relayd-next")
	copyExecutable(t, buildNextRelaydForReexec(t), upgraded)
	if result := worker.upgrade(t, upgraded); result.Result != "upgraded" {
		t.Fatalf("upgrade after rollback: %+v", result)
	}
}

func TestUpgradeWorkersReportsDryRunAndRequestValidation(t *testing.T) {
	binary := buildRelaydForReexec(t)
	worker := startReexecWorker(t, binary, reexecTickCommand)
	next := buildNextRelaydForReexec(t)
	results, err := UpgradeWorkers(WorkerUpgradeOptions{StateDir: worker.stateDir, Executable: next, DryRun: true})
	if err != nil || len(results) != 1 || results[0].Result != "would_upgrade" {
		t.Fatalf("dry run: %+v %v", results, err)
	}
	// On Linux a byte-identical copy of the running image is current, dry run
	// or not: nothing is re-executed and the worker reports no upgrade
	// operation. Elsewhere the loaded image is unknown, so it is re-executed.
	same := filepath.Join(t.TempDir(), "relayd-same")
	copyExecutable(t, binary, same)
	knowsImage := runtime.GOOS == "linux"
	for _, dryRun := range []bool{true, false} {
		want := map[bool]string{true: "would_upgrade", false: "upgraded"}[dryRun]
		if knowsImage {
			want = "current"
		}
		results, err = UpgradeWorkers(WorkerUpgradeOptions{StateDir: worker.stateDir, Executable: same, DryRun: dryRun})
		if err != nil || len(results) != 1 || results[0].Result != want {
			t.Fatalf("same image (dry run %v): want %s, have %+v %v", dryRun, want, results, err)
		}
	}
	if status, err := probeWorkerStatus(worker.manifest); err != nil || (status.ReexecOperation != "") == knowsImage {
		t.Fatalf("upgrade operation after the same image (Linux %v): %+v %v", knowsImage, status, err)
	}
	// After a real upgrade the worker reports the new image as current
	// (Linux), or is re-executed again (elsewhere).
	if result := worker.upgrade(t, next); result.Result != "upgraded" {
		t.Fatalf("upgrade: %+v", result)
	}
	want := map[bool]string{true: "current", false: "upgraded"}[knowsImage]
	if result := worker.upgrade(t, next); result.Result != want {
		t.Fatalf("second upgrade to the same image: want %s, have %+v", want, result)
	}

	// A request whose digest does not match the file is refused before any
	// quiescing, as is a malformed one.
	for _, request := range []workerUpgradeRequest{
		{Executable: binary, SHA256: strings.Repeat("0", 64), OperationID: "op-digest"},
		{Executable: "relative/relayd", SHA256: strings.Repeat("0", 64), OperationID: "op-relative"},
		{Executable: binary, SHA256: strings.Repeat("0", 64), OperationID: "bad id"},
	} {
		raw, _ := json.Marshal(request)
		connection, err := net.Dial("unix", worker.manifest.SocketPath)
		if err != nil {
			t.Fatal(err)
		}
		hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion,
			SessionID: worker.manifest.SessionID, WorkerToken: worker.manifest.Token, WorkerUpgrade: raw})
		_ = protocol.NewWriter(connection).Write(hello)
		_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
		frame, err := protocol.ReadFrame(connection)
		var status protocol.StatusPayload
		if err != nil || protocol.DecodeJSON(frame, &status) != nil || status.State != "refused" {
			t.Fatalf("request %+v was not refused: %+v %v", request, status, err)
		}
		_ = connection.Close()
	}
	// A wrong token gets no reply at all.
	connection, err := net.Dial("unix", worker.manifest.SocketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	raw, _ := json.Marshal(workerUpgradeRequest{Executable: binary, SHA256: strings.Repeat("0", 64), OperationID: "op"})
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion,
		SessionID: worker.manifest.SessionID, WorkerToken: strings.Repeat("cd", 24), WorkerUpgrade: raw})
	_ = protocol.NewWriter(connection).Write(hello)
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	if frame, err := protocol.ReadFrame(connection); err == nil {
		t.Fatalf("unauthenticated upgrade request was answered: %+v", frame)
	}
}

func TestWorkerReexecStateRoundTrip(t *testing.T) {
	session, err := startSession("reexec-state-test", "exec sleep 30", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.terminate()
	session.publish([]byte("\x1b[?2004h\x1b[?1000hhello\x1b]9;4;1;50\x07"))
	session.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"sub-1"}}`))
	session.mu.Lock()
	session.inputSequences[[16]byte{1, 2, 3}] = 42
	session.controlClientID = "owner"
	session.programStatus.Restore(programstatus.TrackerState{Revision: 7, Records: []programstatus.Record{{ID: "a", State: "working", Revision: 7}}})
	session.programStatusRevision = 3
	session.mu.Unlock()
	cursors := []transcriptCursor{{Agent: "codex", RootPID: 99, RootStart: 5, Path: "/x.jsonl", Offset: 1234,
		Known: map[string]bool{"t": true}, Active: map[string]bool{"t": true}}}

	created := time.Now().UTC().Truncate(time.Second)
	state, err := session.exportReexecState("op-1", cursors, created)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.CreateTemp(t.TempDir(), "state")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := writeWorkerReexecState(file, state); err != nil {
		t.Fatal(err)
	}
	var probe bytes.Buffer
	if err := ProbeWorkerReexecState(file, &probe); err != nil || !strings.Contains(probe.String(), `"format":1`) {
		t.Fatalf("probe: %v %s", err, probe.String())
	}
	decoded, err := readWorkerReexecState(file)
	if err != nil {
		t.Fatal(err)
	}

	restored := newSession(session.id, session.command, session.pty, session.process)
	if err := restored.restoreReexecState(decoded); err != nil {
		t.Fatal(err)
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if restored.sequence != session.sequence || len(restored.replay) != len(session.replay) ||
		restored.replayBytes != session.replayBytes || restored.eventSequence != session.eventSequence ||
		len(restored.eventHistory) != len(session.eventHistory) || len(restored.eventHashes) != len(session.eventHashes) {
		t.Fatalf("cursors or history not restored: seq %d/%d events %d/%d", restored.sequence, session.sequence,
			restored.eventSequence, session.eventSequence)
	}
	if _, ok := restored.activeSubagents["claude\x00sub-1"]; !ok {
		t.Fatalf("active subagents not restored: %v", restored.activeSubagents)
	}
	if restored.inputSequences[[16]byte{1, 2, 3}] != 42 {
		t.Fatal("input acknowledgements not restored; a retried input would be written twice")
	}
	if restored.controlClientID != "owner" || !restored.controlGraceUntil.After(time.Now()) {
		t.Fatal("input lease not held for its owner across the handoff")
	}
	if !bytes.Equal(restored.terminalModes.presentationPrelude(), session.terminalModes.presentationPrelude()) {
		t.Fatal("terminal input modes not restored")
	}
	if restored.programStatusRevision != 3 || len(restored.programStatus.Snapshot()) != 1 {
		t.Fatal("program status not restored")
	}
	if !restored.agentProcessesSeeded || restored.reexecOperation != "op-1" || decoded.ManifestCreatedAt != created ||
		len(decoded.Transcripts) != 1 || decoded.Transcripts[0].Offset != 1234 {
		t.Fatalf("handoff metadata not restored: %+v", decoded.Transcripts)
	}
	// A duplicate of an event seen before the handoff is still dropped.
	before := restored.eventSequence
	restored.agentEvent([]byte(`{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"sub-1"}}`))
	if restored.eventSequence != before {
		t.Fatal("dedup hashes not restored")
	}
}

// The handoff depends on stopping the PTY reader between reads: output the
// old image has not read must stay in the kernel for the next image, never be
// read and dropped. Terminal echo makes the test independent of timing.
func TestOutputReaderStopsBetweenReadsAndLeavesOutputInKernel(t *testing.T) {
	session, err := startSession("reader-stop-test", "exec sleep 30", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.terminate()
	if _, err := session.pty.Write([]byte("before-stop\n")); err != nil {
		t.Fatal(err)
	}
	waitForRingBytes(t, session, "before-stop")
	if !session.stopOutputReader() {
		t.Fatal("reader did not stop")
	}
	if _, err := session.pty.Write([]byte("while-stopped\n")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if bytes.Contains(ringBytesAfter(session, 0), []byte("while-stopped")) {
		t.Fatal("a stopped reader consumed PTY output")
	}
	session.startOutputReader()
	waitForRingBytes(t, session, "while-stopped")
}
