package peernet

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiscoveryIsVerifiedAndRedacted(t *testing.T) {
	home := t.TempDir()
	empty, err := Discover(home)
	if err != nil || len(empty.Peers) != 0 {
		t.Fatalf("empty: %+v %v", empty, err)
	}
	socketDir, err := os.MkdirTemp("/tmp", "peer-discovery-")
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
	registration, err := register(home, socket, "discovery-test", "session-test")
	if err != nil {
		t.Fatal(err)
	}
	defer registration.close()
	// Relay's own registration is a proxy and must not appear as an agent.
	proxies, err := Discover(home)
	if err != nil || len(proxies.Peers) != 0 {
		t.Fatalf("proxy advertised as agent: %+v %v", proxies, err)
	}
	registration.value["relayProxy"] = false
	if err := atomicJSON(filepath.Join(home, ".claude", "sessions", fmt.Sprintf("%d.json", os.Getpid())), registration.value); err != nil {
		t.Fatal(err)
	}
	result, err := Discover(home)
	if err != nil || len(result.Peers) != 1 {
		t.Fatalf("live: %+v %v", result, err)
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), socket) || strings.Contains(string(encoded), "Token") {
		t.Fatal("discovery exposed private routing data")
	}
	listener.Close()
	result, err = Discover(home)
	if err != nil || len(result.Peers) != 0 {
		t.Fatalf("dead socket advertised: %+v %v", result, err)
	}
}
