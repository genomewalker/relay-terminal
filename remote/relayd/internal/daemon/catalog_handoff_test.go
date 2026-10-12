package daemon

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPreserveCatalogSnapshotRetainsDormantMetadataWithoutWorkers(t *testing.T) {
	server := &Server{stateDir: filepath.Join(t.TempDir(), "workers")}
	node, _ := currentNodeIdentity()
	now := time.Now().UTC().Truncate(time.Second)
	pane := CatalogPane{NodeID: node, PaneID: "dormant-pane", WorkspaceID: "workspace", TabID: "tab", ParentPaneID: "parent", Title: "Saved title", ContentKind: "terminal", Command: "codex", Directory: "/saved/work", State: "running", WorkerPID: 123, ShellPID: 124, CreatedAt: now, UpdatedAt: now, Recoverable: true, LastSequence: 15, LastEventSequence: 9}
	snapshot := CatalogSnapshot{Schema: 1, NodeID: node, Panes: []CatalogPane{pane}}
	if err := server.PreserveCatalogSnapshot(snapshot); err != nil {
		t.Fatal(err)
	}
	stored, err := loadStoredCatalog(server.catalogPath())
	if err != nil {
		t.Fatal(err)
	}
	expected := pane
	expected.State = "missing"
	expected.Recoverable = false
	expected.Retained = true
	if stored.Panes[pane.PaneID] != expected || stored.Revision != 1 {
		t.Fatal("dormant metadata changed or lost")
	}
	before, _ := os.ReadFile(server.catalogPath())
	snapshot.Panes[0].Title = "Older conflicting title"
	if err := server.PreserveCatalogSnapshot(snapshot); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(server.catalogPath())
	if !bytes.Equal(before, after) {
		t.Fatal("repeat import rewrote existing metadata")
	}
	if _, err := os.Stat(server.stateDir); !os.IsNotExist(err) {
		t.Fatal("offline import created worker state")
	}
	result, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Panes) != 1 || result.Panes[0] != expected {
		t.Fatal("dormant pane disappeared from catalog")
	}
}

func TestPreserveCatalogSnapshotSurvivesStartupGarbageCollection(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	node, _ := currentNodeIdentity()
	old := time.Now().UTC().Add(-45 * 24 * time.Hour)
	pane := CatalogPane{NodeID: node, PaneID: "old-dormant-preserved", Title: "Historical title", State: "missing", CreatedAt: old, UpdatedAt: old}
	if err := server.PreserveCatalogSnapshot(CatalogSnapshot{Schema: 1, NodeID: node, Panes: []CatalogPane{pane}}); err != nil {
		t.Fatal(err)
	}
	removed, err := server.CollectGarbage(30*24*time.Hour, false)
	if err != nil || len(removed) != 0 {
		t.Fatal("startup GC removed preserved history:", removed, err)
	}
	value, err := server.CatalogSnapshot()
	if err != nil || len(value.Panes) != 1 || value.Panes[0].Title != pane.Title || !value.Panes[0].UpdatedAt.Equal(old) || !value.Panes[0].Retained {
		t.Fatal("historical receipt changed:", err)
	}
	if err := server.ForgetPane(pane.PaneID); err != nil {
		t.Fatal("explicit Forget refused:", err)
	}
	value, err = server.CatalogSnapshot()
	if err != nil || len(value.Panes) != 0 {
		t.Fatal("explicit Forget did not remove receipt")
	}
}

func TestPreserveCatalogSnapshotRejectsInvalidInputBeforeWrite(t *testing.T) {
	node, _ := currentNodeIdentity()
	now := time.Now().UTC()
	pane := CatalogPane{NodeID: node, PaneID: "saved-pane", CreatedAt: now, UpdatedAt: now}
	for _, mode := range []string{"foreign-node", "duplicate", "invalid-id", "zero-time", "negative-pid", "nul-metadata"} {
		t.Run(mode, func(t *testing.T) {
			server := &Server{stateDir: filepath.Join(t.TempDir(), "workers")}
			snapshot := CatalogSnapshot{Schema: 1, NodeID: node, Panes: []CatalogPane{pane}}
			switch mode {
			case "foreign-node":
				snapshot.Panes[0].NodeID = "foreign"
			case "duplicate":
				snapshot.Panes = append(snapshot.Panes, pane)
			case "invalid-id":
				snapshot.Panes[0].PaneID = "../bad"
			case "zero-time":
				snapshot.Panes[0].CreatedAt = time.Time{}
			case "negative-pid":
				snapshot.Panes[0].WorkerPID = -1
			case "nul-metadata":
				snapshot.Panes[0].Title = "bad\x00title"
			}
			if server.PreserveCatalogSnapshot(snapshot) == nil {
				t.Fatal("invalid snapshot accepted")
			}
			if _, err := os.Stat(server.catalogPath()); !os.IsNotExist(err) {
				t.Fatal("invalid snapshot wrote catalog")
			}
		})
	}
}
