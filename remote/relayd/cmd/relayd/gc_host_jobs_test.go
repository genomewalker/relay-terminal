package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/protocol"
)

// fakeRelayd answers one probe on a temporary socket with the given
// capabilities, as this process.
func fakeRelayd(t *testing.T, capabilities []string) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "rgc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	socket := filepath.Join(directory, "relayd.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		if _, err := protocol.ReadFrame(connection); err != nil {
			return
		}
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Version: "fixture",
			SupervisorPID: os.Getpid(), Capabilities: capabilities})
		_ = protocol.NewWriter(connection).Write(status)
	}()
	return socket
}

func TestGCHostJobsRefusesARelaydWithoutTombstoneSupport(t *testing.T) {
	old := fakeRelayd(t, []string{"agent_binding_v1"})
	if _, err := tombstoneAwareRelaydPIDs([]string{old}); err == nil || !strings.Contains(err.Error(), "does not support job tombstones") {
		t.Fatalf("an old relayd was accepted: %v", err)
	}
	current := fakeRelayd(t, []string{"agent_binding_v1", daemon.HostJobTombstonesCapability})
	pids, err := tombstoneAwareRelaydPIDs([]string{current, filepath.Join(t.TempDir(), "absent.sock")})
	if err != nil || len(pids) != 1 || pids[0] != os.Getpid() {
		t.Fatalf("tombstone-aware relayd: %v %v", pids, err)
	}
	directory, err := os.MkdirTemp("/tmp", "rgc")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	// A socket file nobody listens on is not a live relayd.
	stale := filepath.Join(directory, "stale.sock")
	if dead, err := net.Listen("unix", stale); err != nil {
		t.Fatal(err)
	} else {
		dead.(*net.UnixListener).SetUnlinkOnClose(false)
		dead.Close()
	}
	if pids, err := tombstoneAwareRelaydPIDs([]string{stale}); err != nil || len(pids) != 0 {
		t.Fatalf("a dead socket file counted: %v %v", pids, err)
	}
	// A live process that answers but cannot be verified refuses.
	silent := filepath.Join(directory, "silent.sock")
	listener, err := net.Listen("unix", silent)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		if connection, err := listener.Accept(); err == nil {
			connection.Close()
		}
	}()
	if _, err := tombstoneAwareRelaydPIDs([]string{silent}); err == nil {
		t.Fatal("an unverifiable live relayd was accepted")
	}
}
