package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestCatalogDiscoversOldWorkerAndAddsHierarchyWithoutChangingManifest(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "workers")
	server := &Server{stateDir: stateDir}
	bootID, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	startTime, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	manifest := workerManifest{
		Version: workerProtocolVersion, SessionID: "pane-old",
		WorkerPID: os.Getpid(), WorkerStartTime: startTime, ShellPID: os.Getpid(),
		NodeBootID: bootID, SocketPath: filepath.Join(t.TempDir(), "worker.sock"), Token: "secret",
		Command: "codex", WorkingDirectory: "/work", State: "running",
		CreatedAt: now, UpdatedAt: now,
	}
	manifestPath := filepath.Join(stateDir, "pane-old.json")
	if err := storeManifest(manifestPath, manifest); err != nil {
		t.Fatal(err)
	}

	initial, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(initial.Panes) != 1 || !initial.Panes[0].Unfiled || !initial.Panes[0].Recoverable {
		t.Fatalf("old worker was not exposed as recoverable unfiled pane: %#v", initial.Panes)
	}

	hello := protocol.HelloPayload{
		SessionID: "pane-old", WorkspaceID: "workspace-1", TabID: "tab-1",
		ParentSessionID: "pane-parent", PaneTitle: "Training", ContentKind: "terminal",
	}
	if err := server.recordCatalogEntry(hello, manifest); err != nil {
		t.Fatal(err)
	}
	if err := server.storeWorkspaceState(workspaceStateRecord{
		Schema: workspaceStateSchema, WorkspaceID: "workspace-1", Revision: 1,
		UpdatedAt: now, State: []byte(`{"tabs":["tab-1"]}`),
	}); err != nil {
		t.Fatal(err)
	}
	updated, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if updated.Revision != 1 || len(updated.Panes) != 1 {
		t.Fatalf("unexpected catalog revision: %#v", updated)
	}
	pane := updated.Panes[0]
	if pane.WorkspaceID != "workspace-1" || pane.TabID != "tab-1" || pane.ParentPaneID != "pane-parent" || pane.Title != "Training" || pane.Unfiled {
		t.Fatalf("hierarchy metadata was not retained: %#v", pane)
	}
	if string(updated.WorkspaceStates["workspace-1"]) != `{"tabs":["tab-1"]}` {
		t.Fatalf("workspace layout was not returned in catalog: %s", updated.WorkspaceStates["workspace-1"])
	}

	manifestBytes, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(manifestBytes) == "" || containsSecretInCatalog(t, server.catalogPath(), "secret") {
		t.Fatal("catalog exposed the worker token")
	}
}

func containsSecretInCatalog(t *testing.T, path, secret string) bool {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index+len(secret) <= len(data); index++ {
		if string(data[index:index+len(secret)]) == secret {
			return true
		}
	}
	return false
}
