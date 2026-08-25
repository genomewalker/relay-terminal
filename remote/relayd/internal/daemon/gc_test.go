package daemon

import (
	"os"
	"path/filepath"
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
