package peernet

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// A Claude desktop app session publishes its chat title ("Sapropels handoff")
// as its name. On 2026-11-08 that space kept session 7194df15 out of discovery,
// so no Codex task could be routed to it (peer_identity_unavailable). It is now
// discovered and resolved under a name derived from its session ID; a CLI
// session with an invalid name is still refused and a valid name is unchanged.
func TestClaudeDesktopSessionIsDiscoveredUnderItsSessionName(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	const session = "7194df15-5298-4ba5-bef3-193a96d90a53"
	home := t.TempDir()
	socketDir, err := os.MkdirTemp("/tmp", "peer-desktop-name-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketDir)
	socket := filepath.Join(socketDir, "peer.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	registration, err := register(home, socket, "placeholder", session)
	if err != nil {
		t.Fatal(err)
	}
	defer registration.close()
	record := filepath.Join(home, ".claude", "sessions", fmt.Sprintf("%d.json", os.Getpid()))
	publish := func(name, entrypoint string) {
		t.Helper()
		registration.value["relayProxy"] = false
		registration.value["name"] = name
		registration.value["entrypoint"] = entrypoint
		if err := atomicJSON(record, registration.value); err != nil {
			t.Fatal(err)
		}
	}
	discovered := func() []DiscoveredPeer {
		t.Helper()
		result, err := Discover(home)
		if err != nil {
			t.Fatal(err)
		}
		return result.Peers
	}

	publish("Sapropels handoff", "claude-desktop")
	if peers := discovered(); len(peers) != 1 || peers[0].Name != "claude-desktop-7194df15" || peers[0].Session != session {
		t.Fatalf("desktop session not discovered under its session name: %+v", peers)
	}
	if _, err := Resolve(home, "claude-desktop-7194df15", session, os.Getpid()); err != nil {
		t.Fatalf("derived name does not resolve: %v", err)
	}
	if _, err := Resolve(home, "Sapropels handoff", session, os.Getpid()); err == nil {
		t.Fatal("chat title accepted as a route name")
	}
	// Renaming the chat must not change the name a saved route checks.
	publish("Sapropels", "claude-desktop")
	if _, err := Resolve(home, "claude-desktop-7194df15", session, os.Getpid()); err != nil {
		t.Fatalf("chat rename changed the route name: %v", err)
	}

	publish("Sapropels handoff", "cli")
	if peers := discovered(); len(peers) != 0 {
		t.Fatalf("CLI session with an invalid name discovered: %+v", peers)
	}
	publish("kbd606-b1", "cli")
	if peers := discovered(); len(peers) != 1 || peers[0].Name != "kbd606-b1" {
		t.Fatalf("valid CLI name changed: %+v", peers)
	}
}
