package daemon

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A worker whose executable file is replaced after it started still runs the
// old image. It must not report the replacement's digest as its own, or
// upgrade-workers would call it current and leave it on the old build.
func TestUpgradeWorkersUpgradesWorkerWhoseFileWasReplaced(t *testing.T) {
	directory := t.TempDir()
	installed := filepath.Join(directory, "relayd")
	copyExecutable(t, buildRelaydForReexec(t), installed)
	// No probe yet: the first digest request comes after the replacement.
	worker := startReexecWorkerProbed(t, installed, reexecTickCommand, false)
	staged := filepath.Join(directory, ".relayd.new")
	copyExecutable(t, buildNextRelaydForReexec(t), staged)
	if err := os.Rename(staged, installed); err != nil {
		t.Fatal(err)
	}
	if result := worker.upgrade(t, installed); result.Result != "upgraded" {
		t.Fatalf("worker on the replaced image: %+v", result)
	}
}

type fakeUpgradeWorker struct {
	stateDir  string
	sessionID string

	mu        sync.Mutex
	requests  int
	operation string
}

// startFakeUpgradeWorker answers the worker protocol as a capable worker in
// this process. It reports digest as its image and refuses the first refusals
// upgrade requests with message, then accepts and reports the operation.
func startFakeUpgradeWorker(t *testing.T, digest string, refusals int, message string) *fakeUpgradeWorker {
	t.Helper()
	root, err := os.MkdirTemp("", "rb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	pid := os.Getpid()
	start, err := processStartTime(pid)
	if err != nil {
		t.Fatal(err)
	}
	boot, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	worker := &fakeUpgradeWorker{stateDir: filepath.Join(root, "workers"),
		sessionID: "busy-" + strconv.FormatInt(time.Now().UnixNano(), 36)}
	token := strings.Repeat("cd", 24)
	manifest := workerManifest{Version: workerProtocolVersion, SessionID: worker.sessionID, WorkerPID: pid,
		WorkerStartTime: start, NodeBootID: boot, SocketPath: filepath.Join(root, "w.sock"), Token: token,
		State: "running", CreatedAt: time.Now().UTC()}
	listener, err := net.Listen("unix", manifest.SocketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if err := storeManifest(filepath.Join(worker.stateDir, worker.sessionID+".json"), manifest); err != nil {
		t.Fatal(err)
	}
	serve := func(connection net.Conn) {
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
		frame, err := protocol.ReadFrame(connection)
		var hello protocol.HelloPayload
		if err != nil || protocol.DecodeJSON(frame, &hello) != nil || hello.WorkerToken != token {
			return
		}
		worker.mu.Lock()
		status := protocol.StatusPayload{WorkerPID: pid}
		switch {
		case hello.Probe:
			status.State, status.Capabilities = "ready", []string{workerReexecCapability}
			status.ExecutableSHA256, status.ReexecOperation = digest, worker.operation
		case len(hello.WorkerUpgrade) > 0:
			worker.requests++
			var request workerUpgradeRequest
			if worker.requests <= refusals || json.Unmarshal(hello.WorkerUpgrade, &request) != nil {
				status.State, status.Message = "refused", message
			} else {
				status.State, worker.operation = "upgrading", request.OperationID
			}
		}
		worker.mu.Unlock()
		reply, _ := protocol.JSONFrame(protocol.Status, status)
		_ = protocol.NewWriter(connection).Write(reply)
	}
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go serve(connection)
		}
	}()
	return worker
}

func (worker *fakeUpgradeWorker) upgrade(t *testing.T, retries int, dryRun bool) WorkerUpgradeResult {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	results, err := UpgradeWorkers(WorkerUpgradeOptions{StateDir: worker.stateDir, Executable: executable,
		DryRun: dryRun, Timeout: 5 * time.Second, BusyRetries: retries, BusyRetryInterval: 10 * time.Millisecond})
	if err != nil || len(results) != 1 {
		t.Fatalf("upgrade-workers: %v %+v", err, results)
	}
	return results[0]
}

func (worker *fakeUpgradeWorker) upgradeRequests() int {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.requests
}

func TestUpgradeWorkersRetriesBusyWorkers(t *testing.T) {
	busy := errWorkerPromptEditOpen.Error()

	// A pane that settles within the retries is upgraded.
	worker := startFakeUpgradeWorker(t, "", 2, busy)
	if result := worker.upgrade(t, 3, false); result.Result != "upgraded" || result.Attempts != 3 || worker.upgradeRequests() != 3 {
		t.Fatalf("settling pane: %+v after %d requests", result, worker.upgradeRequests())
	}

	// Retries are bounded: a pane busy throughout is reported busy.
	worker = startFakeUpgradeWorker(t, "", 100, busy)
	if result := worker.upgrade(t, 2, false); result.Result != "busy" || result.Message != busy || result.Attempts != 3 ||
		worker.upgradeRequests() != 3 {
		t.Fatalf("busy pane: %+v after %d requests", result, worker.upgradeRequests())
	}
	worker = startFakeUpgradeWorker(t, "", 1, busy)
	if result := worker.upgrade(t, 0, false); result.Result != "busy" || result.Attempts != 1 {
		t.Fatalf("no retries: %+v", result)
	}

	// Other refusals are final, and a dry run sends no upgrade request.
	worker = startFakeUpgradeWorker(t, "", 1, "new relayd cannot restore this worker: test")
	if result := worker.upgrade(t, 3, false); result.Result != "refused" || result.Attempts != 1 {
		t.Fatalf("permanent refusal: %+v", result)
	}
	worker = startFakeUpgradeWorker(t, "", 100, busy)
	if result := worker.upgrade(t, 3, true); result.Result != "would_upgrade" || worker.upgradeRequests() != 0 {
		t.Fatalf("dry run: %+v after %d requests", result, worker.upgradeRequests())
	}
}

// A worker reporting the target's digest is current: never asked to upgrade.
func TestUpgradeWorkersSkipsWorkerReportingTargetDigest(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	digest, err := fileDigest(executable)
	if err != nil {
		t.Fatal(err)
	}
	worker := startFakeUpgradeWorker(t, digest, 0, "")
	if result := worker.upgrade(t, 3, false); result.Result != "current" || worker.upgradeRequests() != 0 {
		t.Fatalf("current worker: %+v after %d requests", result, worker.upgradeRequests())
	}
}

func TestWorkerBusyRefusalsMatchWorkerMessages(t *testing.T) {
	for _, message := range []string{"a prompt edit is open", "another worker upgrade is in progress",
		"a native rotation bridge is attached", "context rotation owns terminal input",
		"context management has a turn to evaluate", "context management is evaluating a turn",
		"context management is completing a rotation"} {
		if !workerBusyRefusals[message] {
			t.Errorf("%q is not treated as busy", message)
		}
	}
	for _, message := range []string{"pane shell has exited", "pane terminal closed",
		"upgrade target does not match the requested digest", "invalid worker upgrade request"} {
		if workerBusyRefusals[message] {
			t.Errorf("%q is treated as busy", message)
		}
	}
}
