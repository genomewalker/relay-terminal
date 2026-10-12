package daemon

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestManifestIsAtomicPrivateAndValidatesIdentity(t *testing.T) {
	startTime, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "pane-1.json")
	want := workerManifest{
		Version: workerProtocolVersion, SessionID: "pane-1",
		WorkerPID: os.Getpid(), WorkerStartTime: startTime,
		NodeBootID: bootID, SocketPath: "/tmp/example.sock", Token: "token",
		State: "running", CreatedAt: time.Now().UTC(),
	}
	if err := storeManifest(path, want); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("manifest mode is %o, want 600", info.Mode().Perm())
	}
	got, err := loadManifest(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.SessionID != want.SessionID || got.WorkerPID != want.WorkerPID {
		t.Fatalf("unexpected manifest: %+v", got)
	}
	if err := validateWorkerIdentity(got); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureWorkerPreservesLiveOwnerWhenProbeFails(t *testing.T) {
	startTime, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{stateDir: t.TempDir(), executable: "/must-not-start-a-replacement"}
	manifest := workerManifest{
		Version: workerProtocolVersion, SessionID: "live-pane",
		WorkerPID: os.Getpid(), WorkerStartTime: startTime, NodeBootID: bootID,
		SocketPath: filepath.Join(t.TempDir(), "unavailable.sock"), Token: "test-token",
	}
	path := server.manifestPath(manifest.SessionID)
	if err := storeManifest(path, manifest); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.ensureWorker(protocol.HelloPayload{SessionID: manifest.SessionID}); err == nil {
		t.Fatal("unavailable live worker must report a retryable attachment failure")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("live owner's manifest was removed: %v", err)
	}
	if string(before) != string(after) {
		t.Fatal("live owner's manifest changed")
	}
}

func TestEnsureWorkerPreservesUnreadableRecoveryMetadata(t *testing.T) {
	server := &Server{stateDir: t.TempDir(), executable: "/must-not-start-a-replacement"}
	path := server.manifestPath("pane-corrupt")
	const damaged = `{"version":1,"session_id":"pane-corrupt"`
	if err := os.WriteFile(path, []byte(damaged), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := server.ensureWorker(protocol.HelloPayload{SessionID: "pane-corrupt"}); err == nil {
		t.Fatal("unreadable metadata must prevent replacement")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != damaged {
		t.Fatalf("recovery metadata lost: %v", err)
	}
}

func TestRestoredPaneNeverStartsReplacementWorker(t *testing.T) {
	server := &Server{stateDir: t.TempDir(), executable: "/must-not-start-a-replacement"}
	const sessionID = "restored-pane"
	if _, err := server.ensureWorker(protocol.HelloPayload{
		SessionID: sessionID, RequireExistingWorker: true,
	}); err == nil {
		t.Fatal("missing saved pane must not start a replacement")
	}
	if _, err := os.Stat(server.manifestPath(sessionID)); !os.IsNotExist(err) {
		t.Fatalf("missing pane acquired a replacement manifest: %v", err)
	}
}

func TestEnsureWorkerPreservesOwnerAfterProbeTimeout(t *testing.T) {
	dir, err := os.MkdirTemp("", "relay-probe-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	// Use a short path: macOS Unix sockets have a 104-byte name limit.
	socketPath := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	boot, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{stateDir: t.TempDir(), executable: "/must-not-start-a-replacement"}
	manifest := workerManifest{Version: workerProtocolVersion, SessionID: "slow-pane",
		WorkerPID: os.Getpid(), WorkerStartTime: start, NodeBootID: boot,
		SocketPath: socketPath, Token: "test-token"}
	path := server.manifestPath(manifest.SessionID)
	if err := storeManifest(path, manifest); err != nil {
		t.Fatal(err)
	}
	// The listener accepts at the kernel level, but sends no probe reply.
	// A deadline must lead to retry, never a replacement shell or unlink.
	if _, err := server.ensureWorker(protocol.HelloPayload{SessionID: manifest.SessionID}); err == nil {
		t.Fatal("expected probe timeout")
	}
	got, err := loadManifest(path)
	if err != nil || got.WorkerPID != manifest.WorkerPID || got.Token != manifest.Token {
		t.Fatalf("timed-out worker lost its identity: %v", err)
	}
	if _, err := os.Stat(socketPath); err != nil {
		t.Fatalf("worker socket removed: %v", err)
	}
}

func TestRecoveredOwnerWinsOverLegacyManifestUpdates(t *testing.T) {
	server := &Server{stateDir: t.TempDir(), executable: "/must-not-start-a-replacement"}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	boot, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	selected := workerManifest{Version: workerProtocolVersion, SessionID: "recovered-pane",
		WorkerPID: os.Getpid(), WorkerStartTime: start, NodeBootID: boot,
		State: "running", Token: "selected", SocketPath: "/no-such-recovery-socket"}
	legacyPath := filepath.Join(server.stateDir, selected.SessionID+".json")
	if err := storeManifest(server.recoveredManifestPath(selected.SessionID), selected); err != nil {
		t.Fatal(err)
	}
	legacy := selected
	legacy.Token = "legacy"
	legacy.WorkerPID = 1
	if err := storeManifest(legacyPath, legacy); err != nil {
		t.Fatal(err)
	}
	got, err := loadManifest(server.manifestPath(selected.SessionID))
	if err != nil || got.Token != "selected" {
		t.Fatalf("legacy worker displaced recovered owner: %v", err)
	}
	snapshot, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Panes) != 1 || snapshot.Panes[0].WorkerPID != selected.WorkerPID {
		t.Fatalf("catalog disagrees with attachment owner: %#v", snapshot.Panes)
	}
	if _, err := server.ensureWorker(protocol.HelloPayload{SessionID: selected.SessionID}); err == nil {
		t.Fatal("unavailable recovered owner must not silently switch to another shell")
	}
	if _, err := os.Stat(server.recoveredManifestPath(selected.SessionID)); err != nil {
		t.Fatal(err)
	}
}
