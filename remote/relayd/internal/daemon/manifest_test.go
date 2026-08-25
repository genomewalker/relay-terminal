package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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
