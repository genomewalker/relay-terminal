package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/daemon"
)

// Without declarations the upgrade takes exactly its old path.
func TestUpgradeServicesInactiveWithoutDeclarations(t *testing.T) {
	state := filepath.Join(t.TempDir(), "workers")
	if services := upgradeServices(state, filepath.Join(state, "absent.sock")); services != nil {
		t.Fatal("an empty host has service orchestration")
	}
	if _, err := os.Lstat(filepath.Join(state, "services")); !os.IsNotExist(err) {
		t.Fatalf("inspection created state: %v", err)
	}
}

func TestServiceCommandNameShowsOnlyTheCommandName(t *testing.T) {
	cases := map[string]daemon.ServiceSpec{
		"sh -lc uvicorn ...": {Command: "uvicorn app:api --port 8000 --token s3cr3t"},
		"sh -lc ...":         {Command: "TOKEN=s3cr3t uvicorn app:api"},
		"/usr/bin/node":      {Argv: []string{"/usr/bin/node", "server.js", "--key=s3cr3t"}},
	}
	for want, spec := range cases {
		if got := serviceCommandName(spec); got != want {
			t.Errorf("%+v: got %q, want %q", spec, got, want)
		}
	}
}
