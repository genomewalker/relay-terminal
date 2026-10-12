package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
)

func TestPreserveCatalogOfflineLockAndPrivateSnapshot(t *testing.T) {
	root := t.TempDir()
	runtime := filepath.Join(root, "runtime")
	if err := os.Mkdir(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	t.Setenv("XDG_RUNTIME_DIR", runtime)
	server := daemon.NewServer()
	value, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	value.Panes = []daemon.CatalogPane{{NodeID: value.NodeID, PaneID: "saved-dormant", Title: "Original title", State: "running", CreatedAt: now, UpdatedAt: now}}
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := filepath.Join(root, "snapshot.json")
	if err := os.WriteFile(snapshot, data, 0600); err != nil {
		t.Fatal(err)
	}
	lock, err := daemon.OpenPrivateFile(defaultSocket()+".lock", syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if preserveCatalogOffline(defaultSocket(), snapshot) == nil {
		t.Fatal("live supervisor lock bypassed")
	}
	if err := catalogHandoffMode(defaultSocket(), snapshot, false, true); err != nil {
		t.Fatal("read-only prevalidation refused live supervisor:", err)
	}
	validated, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(validated.Panes) != 0 {
		t.Fatal("prevalidation mutated live profile catalog")
	}
	syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if preserveCatalogOffline(filepath.Join(runtime, "other.sock"), snapshot) == nil {
		t.Fatal("wrong profile socket accepted")
	}
	link := filepath.Join(root, "linked.json")
	if err := os.Symlink(snapshot, link); err != nil {
		t.Fatal(err)
	}
	if preserveCatalogOffline(defaultSocket(), link) == nil {
		t.Fatal("symlink snapshot accepted")
	}
	if err := preserveCatalogOffline(defaultSocket(), snapshot); err != nil {
		t.Fatal(err)
	}
	if err := preserveCatalogOfflineMode(defaultSocket(), snapshot, true); err != nil {
		t.Fatal("verified import not acknowledged:", err)
	}
	result, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Panes) != 1 || result.Panes[0].Title != "Original title" || result.Panes[0].Recoverable || result.Panes[0].State != "missing" {
		t.Fatal("offline metadata not retained")
	}
	if err := preserveCatalogOffline(defaultSocket(), snapshot); err != nil {
		t.Fatal(err)
	}
	repeated, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if repeated.Revision != result.Revision {
		t.Fatal("repeat import changed revision")
	}
	value.Panes[0].Title = "Different source title"
	data, _ = json.Marshal(value)
	if err := os.WriteFile(snapshot, data, 0600); err != nil {
		t.Fatal(err)
	}
	if preserveCatalogOfflineMode(defaultSocket(), snapshot, true) == nil {
		t.Fatal("missing source metadata incorrectly verified")
	}
	unchanged, err := server.CatalogSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if unchanged.Panes[0].Title != "Original title" || unchanged.Revision != repeated.Revision {
		t.Fatal("verify mutated catalog")
	}
}
