package desktoproute

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// The route helper reads the owner's session record itself. A Claude desktop
// app owner is checked under the same session-derived name that discovery
// gives it, both as the exact endpoint and as an account-move replacement.
func TestRouteHelperNamesClaudeDesktopOwnerBySession(t *testing.T) {
	const session = "7194df15-5298-4ba5-bef3-193a96d90a53"
	home := privateTemp(t)
	registry := filepath.Join(home, "sessions")
	privateDirectory(registry, true)
	path := filepath.Join(home, "peer.sock")
	unixFixture(t, path)
	owner := map[string]any{"pid": os.Getpid(), "name": "Sapropels handoff", "sessionId": session, "procStart": "123",
		"messagingSocketPath": path, "cwd": home, "entrypoint": "claude-desktop"}
	atomicJSON(filepath.Join(registry, fmt.Sprint(os.Getpid())+".json"), owner)
	r := &remoteRuntime{home: home, inspect: func(pid int) (processInfo, error) {
		if pid == os.Getpid() {
			return processInfo{Start: "123"}, nil
		}
		return processInfo{}, errIdentity
	}}
	p, err := r.endpoint(registry, os.Getpid(), session, "123")
	if err != nil || p.Name != "claude-desktop-7194df15" {
		t.Fatalf("endpoint: %+v %v", p, err)
	}
	found, err := r.replacement(registry, session)
	if err != nil || found == nil || found.Name != "claude-desktop-7194df15" {
		t.Fatalf("replacement: %+v %v", found, err)
	}
	owner["entrypoint"] = "cli"
	atomicJSON(filepath.Join(registry, fmt.Sprint(os.Getpid())+".json"), owner)
	if _, err := r.endpoint(registry, os.Getpid(), session, "123"); err == nil {
		t.Fatal("CLI owner with an invalid name accepted")
	}
}
