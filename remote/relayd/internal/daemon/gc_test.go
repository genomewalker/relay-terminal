package daemon

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestGarbageCollectionNeverSelectsValidatedRunningPane(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	old := time.Now().UTC().Add(-45 * 24 * time.Hour)
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	startTime, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if err := storeManifest(server.manifestPath("running-old"), workerManifest{
		Version: workerProtocolVersion, SessionID: "running-old", WorkerPID: os.Getpid(),
		WorkerStartTime: startTime, ShellPID: os.Getpid(), NodeBootID: bootID,
		SocketPath: filepath.Join(t.TempDir(), "running.sock"), Token: "test",
		State: "running", CreatedAt: old, UpdatedAt: old,
	}); err != nil {
		t.Fatal(err)
	}
	catalog := storedCatalog{Schema: catalogSchemaVersion, Panes: map[string]CatalogPane{
		"missing-old":   {PaneID: "missing-old", State: "missing", UpdatedAt: old},
		"running-old":   {PaneID: "running-old", State: "running", UpdatedAt: old},
		"stale-running": {PaneID: "stale-running", State: "running", UpdatedAt: old},
		"missing-new":   {PaneID: "missing-new", State: "missing", UpdatedAt: time.Now().UTC()},
	}}
	if err := storeCatalog(server.catalogPath(), catalog); err != nil {
		t.Fatal(err)
	}

	dryRun, err := server.CollectGarbage(30*24*time.Hour, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(dryRun) != 2 || dryRun[0] != "missing-old" || dryRun[1] != "stale-running" {
		t.Fatalf("unexpected dry-run selection: %v", dryRun)
	}
	removed, err := server.CollectGarbage(30*24*time.Hour, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 2 || removed[0] != "missing-old" || removed[1] != "stale-running" {
		t.Fatalf("unexpected removal: %v", removed)
	}
	updated, err := loadStoredCatalog(server.catalogPath())
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := updated.Panes["missing-old"]; exists {
		t.Fatal("old missing pane was retained")
	}
	if _, exists := updated.Panes["running-old"]; !exists {
		t.Fatal("running pane was collected")
	}
}

func TestGarbageCollectionRemovesOnlyOrphanedOldWorkspaceState(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	old := time.Now().UTC().Add(-45 * 24 * time.Hour)
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	startTime, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if err := storeManifest(server.manifestPath("live"), workerManifest{
		Version: workerProtocolVersion, SessionID: "live", WorkerPID: os.Getpid(),
		WorkerStartTime: startTime, ShellPID: os.Getpid(), NodeBootID: bootID,
		SocketPath: filepath.Join(t.TempDir(), "live.sock"), Token: "test",
		State: "running", CreatedAt: old,
	}); err != nil {
		t.Fatal(err)
	}
	catalog := storedCatalog{Schema: catalogSchemaVersion, Panes: map[string]CatalogPane{
		"live": {PaneID: "live", WorkspaceID: "workspace-live", State: "running", UpdatedAt: old},
	}}
	if err := storeCatalog(server.catalogPath(), catalog); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"workspace-live", "workspace-orphan"} {
		if err := server.storeWorkspaceState(workspaceStateRecord{
			Schema: workspaceStateSchema, WorkspaceID: id, Revision: 1,
			UpdatedAt: old, State: []byte(`{"tabs":[]}`),
		}); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(server.workspaceStatePath(id), old, old); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := server.CollectGarbage(30*24*time.Hour, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(server.workspaceStatePath("workspace-live")); err != nil {
		t.Fatal("live workspace state was removed")
	}
	if _, err := os.Stat(server.workspaceStatePath("workspace-orphan")); !os.IsNotExist(err) {
		t.Fatal("orphaned old workspace state was retained")
	}
}

// startStandInWorker runs a real child process whose identity validates like
// a pane worker's, and reports when it exits.
func startStandInWorker(t *testing.T) (*exec.Cmd, <-chan struct{}) {
	t.Helper()
	child := exec.Command("sleep", "60")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { _ = child.Wait(); close(exited) }()
	t.Cleanup(func() { _ = child.Process.Kill(); <-exited })
	return child, exited
}

func TestGarbageCollectionCollectsRetainedPaneOnlyWithProvenExitedShell(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	old := time.Now().UTC().Add(-45 * 24 * time.Hour)
	recent := time.Now().UTC().Add(-time.Hour)
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	workers := map[string]<-chan struct{}{}
	manifest := func(id, state string, updated time.Time, pid int, start uint64) {
		t.Helper()
		// storeManifest stamps the current time; write the recorded one.
		data, err := json.Marshal(workerManifest{
			Version: workerProtocolVersion, SessionID: id, WorkerPID: pid, WorkerStartTime: start,
			ShellPID: pid, NodeBootID: bootID, SocketPath: filepath.Join(t.TempDir(), id+".sock"),
			Token: "test", State: state, CreatedAt: old, UpdatedAt: updated,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(server.stateDir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(server.manifestPath(id), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	live := func(id, state string, updated time.Time) {
		t.Helper()
		child, exited := startStandInWorker(t)
		start, err := processStartTime(child.Process.Pid)
		if err != nil {
			t.Fatal(err)
		}
		manifest(id, state, updated, child.Process.Pid, start)
		workers[id] = exited
	}
	live("retained-exited-old", "exited", old)
	live("retained-exited-recent", "exited", recent)
	live("retained-running-old", "running", old)
	// A worker identity that no longer validates: the PID's start time differs.
	manifest("retained-stale-old", "exited", old, os.Getpid(), 1)

	panes := map[string]CatalogPane{"plain-missing-old": {PaneID: "plain-missing-old", State: "missing", UpdatedAt: old}}
	for _, id := range []string{"retained-exited-old", "retained-exited-recent", "retained-running-old",
		"retained-stale-old", "retained-missing-old"} {
		panes[id] = CatalogPane{PaneID: id, State: "running", UpdatedAt: old, Retained: true}
	}
	if err := storeCatalog(server.catalogPath(), storedCatalog{Schema: catalogSchemaVersion, Panes: panes}); err != nil {
		t.Fatal(err)
	}

	want := []string{"plain-missing-old", "retained-exited-old"}
	dryRun, err := server.CollectGarbage(30*24*time.Hour, true)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(dryRun, want) {
		t.Fatalf("unexpected dry-run selection: %v", dryRun)
	}
	select {
	case <-workers["retained-exited-old"]:
		t.Fatal("dry run stopped a worker")
	default:
	}
	removed, err := server.CollectGarbage(30*24*time.Hour, false)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(removed, want) {
		t.Fatalf("unexpected removal: %v", removed)
	}
	select {
	case <-workers["retained-exited-old"]:
	case <-time.After(5 * time.Second):
		t.Fatal("leftover worker of the collected retained pane was not stopped")
	}
	for _, id := range []string{"retained-exited-recent", "retained-running-old"} {
		select {
		case <-workers[id]:
			t.Fatalf("worker of protected pane %s was stopped", id)
		default:
		}
	}
	updated, err := loadStoredCatalog(server.catalogPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range want {
		if _, exists := updated.Panes[id]; exists {
			t.Fatalf("%s was not collected", id)
		}
	}
	for _, id := range []string{"retained-exited-recent", "retained-running-old", "retained-stale-old", "retained-missing-old"} {
		if pane, exists := updated.Panes[id]; !exists || !pane.Retained {
			t.Fatalf("protected retained pane %s was collected", id)
		}
	}
}
