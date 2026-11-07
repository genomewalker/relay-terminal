package peernet

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// spawnAccountPeer runs the helper process with exactly the given environment.
// The test binary is used because the kernel withholds platform binaries' environment.
func spawnAccountPeer(t *testing.T, env []string) int {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestPeerAccountHelperProcess$")
	command.Env = append(env, "RELAY_PEER_ACCOUNT_HELPER=1")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})
	return command.Process.Pid
}

func TestClaudeConfigFollowsOwnerAccount(t *testing.T) {
	home := t.TempDir()
	acct := t.TempDir()
	cases := []struct {
		name string
		env  []string
		want string // "" means refused
	}{
		{"own account", []string{"CLAUDE_CONFIG_DIR=" + acct}, acct},
		{"unset selects default", []string{"PATH=/usr/bin:/bin"}, filepath.Join(home, ".claude")},
		{"set but empty refused", []string{"CLAUDE_CONFIG_DIR="}, ""},
		{"relative refused", []string{"CLAUDE_CONFIG_DIR=rel/acct"}, ""},
		{"unclean refused", []string{"CLAUDE_CONFIG_DIR=" + acct + "/."}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pid := spawnAccountPeer(t, c.env)
			got, err := claudeConfig(home, pid)
			if c.want == "" {
				if err == nil {
					t.Fatalf("resolved %q for a refused owner", got)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("claudeConfig = %q, %v; want %q", got, err, c.want)
			}
		})
	}
	if _, err := claudeConfig(home, 1); err == nil {
		t.Fatal("an unreadable environment (pid 1) resolved an account")
	}
}

// A non-default owner's registration is read from its own account only. The
// same record in the default account is not its registration.
func TestResolveNeverReadsDefaultAccountForNonDefaultOwner(t *testing.T) {
	home := t.TempDir()
	acct := t.TempDir()
	pid := spawnAccountPeer(t, []string{"CLAUDE_CONFIG_DIR=" + acct})
	start, err := processStart(pid)
	if err != nil {
		t.Fatal(err)
	}
	socketDir, err := os.MkdirTemp("/tmp", "peer-owner-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })
	socket := filepath.Join(socketDir, "peer.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	record := Record{PID: pid, Name: "owned-peer", Session: "owned-session", Socket: socket, Start: start}
	defaultSessions := filepath.Join(home, ".claude", "sessions")
	if err := os.MkdirAll(defaultSessions, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(defaultSessions, fmt.Sprintf("%d.json", pid)), record); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(home, "owned-peer", "owned-session", pid); err == nil {
		t.Fatal("registration in the default account resolved a non-default owner")
	}
	ownSessions := filepath.Join(acct, "sessions")
	if err := os.MkdirAll(ownSessions, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(ownSessions, fmt.Sprintf("%d.json", pid)), record); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(home, "owned-peer", "owned-session", pid); err != nil {
		t.Fatalf("own-account registration refused: %v", err)
	}
}

func TestOwnClaudeConfigRefusesInvalidOwnValue(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "relative/acct")
	if _, err := ownClaudeConfig(home); err == nil {
		t.Fatal("invalid own account directory accepted")
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	if _, err := ownClaudeConfig(home); err == nil {
		t.Fatal("set but empty own account directory accepted")
	}
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	if got, err := ownClaudeConfig(home); err != nil || got != filepath.Join(home, ".claude") {
		t.Fatalf("unset own account = %q, %v", got, err)
	}
}

// An owner whose environment cannot be read (a platform binary, withheld by the
// kernel) or that is gone is refused, never resolved to the default account.
func TestClaudeConfigRefusesUnreadableOwner(t *testing.T) {
	home := t.TempDir()
	sleeper := exec.Command("/bin/sleep", "30")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() })
	if got, err := claudeConfig(home, sleeper.Process.Pid); err == nil {
		t.Fatalf("unreadable environment resolved to %q", got)
	}
	gone := exec.Command(os.Args[0], "-test.run=^$")
	gone.Env = []string{"PATH=/usr/bin:/bin"}
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	if got, err := claudeConfig(home, gone.Process.Pid); err == nil {
		t.Fatalf("gone process resolved to %q", got)
	}
}
