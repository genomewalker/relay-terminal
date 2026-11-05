package peernet

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestPeerAccountHelperProcess(t *testing.T) {
	if os.Getenv("RELAY_PEER_ACCOUNT_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(60 * time.Second)
}

func TestDiscoveryFindsAPeerInItsOwnClaudeAccount(t *testing.T) {
	home := t.TempDir()
	if _, err := agentaccounts.Save(home, agentaccounts.DefaultRegistry()); err != nil {
		t.Fatal(err)
	}
	personal := filepath.Join(home, ".claude-personal")
	command := exec.Command(os.Args[0], "-test.run=^TestPeerAccountHelperProcess$")
	command.Env = []string{"RELAY_PEER_ACCOUNT_HELPER=1", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + personal}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}()
	pid := command.Process.Pid
	for deadline := time.Now().Add(5 * time.Second); claudeConfig(home, pid) != personal; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("helper account never became readable")
		}
	}
	start, err := processStart(pid)
	if err != nil {
		t.Fatal(err)
	}
	socketDir, err := os.MkdirTemp("/tmp", "peer-account-")
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
	record := Record{PID: pid, Name: "personal-peer", Session: "personal-session", Socket: socket, Start: start}
	sessions := filepath.Join(personal, "sessions")
	if err := os.MkdirAll(sessions, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(sessions, fmt.Sprintf("%d.json", pid)), record); err != nil {
		t.Fatal(err)
	}
	result, err := Discover(home)
	if err != nil || len(result.Peers) != 1 || result.Peers[0].PID != pid || result.Peers[0].Name != "personal-peer" {
		t.Fatalf("personal peer not discovered: %+v %v", result, err)
	}
	if _, err := Resolve(home, "personal-peer", "personal-session", pid); err != nil {
		t.Fatalf("personal peer not resolved: %v", err)
	}
	// The same record in the default account is not this process's own.
	if err := os.Rename(filepath.Join(sessions, fmt.Sprintf("%d.json", pid)), filepath.Join(home, "moved.json")); err != nil {
		t.Fatal(err)
	}
	defaultSessions := filepath.Join(home, ".claude", "sessions")
	if err := os.MkdirAll(defaultSessions, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(home, "moved.json"), filepath.Join(defaultSessions, fmt.Sprintf("%d.json", pid))); err != nil {
		t.Fatal(err)
	}
	if result, err := Discover(home); err != nil || len(result.Peers) != 0 {
		t.Fatalf("a record outside the process's account was trusted: %+v %v", result, err)
	}
	if _, err := agentlaunch.ProcessEnvironment(pid, "CLAUDE_CONFIG_DIR"); err != nil {
		t.Fatal(err)
	}
}
