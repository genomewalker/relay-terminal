//go:build linux || darwin

package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

const desktopTestSession = "7194df15-5298-4ba5-bef3-193a96d90a53"

// claudeChain starts outer -> inner -> client shells, each with
// CLAUDE_CONFIG_DIR=config, and returns their PIDs.
func claudeChain(t *testing.T, config string) (outer, inner, client int) {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "client")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// The test binary itself plays each process: macOS hides the environment
	// of its protected platform binaries such as /bin/sh, and the session's
	// account directory is read from that environment.
	cmd := exec.Command(self, "-test.run=^$")
	cmd.Env = []string{"PATH=/usr/bin:/bin", "CLAUDE_CONFIG_DIR=" + config, "HOME=" + dir,
		"RELAYD_TEST_CLAUDE_CHAIN=2", "RELAYD_TEST_CLAUDE_CHAIN_PIDFILE=" + pidFile}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if client > 1 {
			syscall.Kill(client, syscall.SIGKILL)
		}
		if inner > 1 {
			syscall.Kill(inner, syscall.SIGKILL)
		}
		cmd.Process.Kill()
		cmd.Wait()
	})
	outer = cmd.Process.Pid
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		data, err := os.ReadFile(pidFile)
		if _, scanErr := fmt.Sscanf(string(data), "%d %d", &client, &inner); err == nil && scanErr == nil && client > 1 {
			break
		}
	}
	if client <= 1 || inner <= 1 || inner == outer {
		t.Fatalf("unexpected process tree outer=%d inner=%d client=%d", outer, inner, client)
	}
	return outer, inner, client
}

// runClaudeChainHelper makes this test binary one link of claudeChain: depth
// 2 and 1 start the next link and wait; depth 0 reports "pid ppid" and waits
// until its parent exits.
func runClaudeChainHelper() bool {
	depth := os.Getenv("RELAYD_TEST_CLAUDE_CHAIN")
	if depth == "" {
		return false
	}
	n, _ := strconv.Atoi(depth)
	if n > 0 {
		self, _ := os.Executable()
		cmd := exec.Command(self, "-test.run=^$")
		cmd.Env = append(os.Environ(), "RELAYD_TEST_CLAUDE_CHAIN="+strconv.Itoa(n-1))
		if cmd.Start() == nil {
			cmd.Wait()
		}
		return true
	}
	parent := os.Getppid()
	path := os.Getenv("RELAYD_TEST_CLAUDE_CHAIN_PIDFILE")
	os.WriteFile(path+".tmp", []byte(fmt.Sprintf("%d %d\n", os.Getpid(), parent)), 0o600)
	os.Rename(path+".tmp", path)
	for start := time.Now(); time.Since(start) < 5*time.Minute && os.Getppid() == parent; time.Sleep(100 * time.Millisecond) {
	}
	return true
}

func writeClaudeRegistration(t *testing.T, config string, pid int, overrides map[string]any) {
	t.Helper()
	start, err := processStartIdentity(pid)
	if err != nil {
		t.Fatal(err)
	}
	row := map[string]any{"pid": pid, "sessionId": desktopTestSession, "procStart": start, "peerProtocol": 1,
		"kind": "interactive", "entrypoint": "claude-desktop", "pidDomain": nativeClaudePIDDomain(),
		"messagingSocketPath": "/tmp/cc-socks/" + strconv.Itoa(pid) + ".sock"}
	for key, value := range overrides {
		if value == nil {
			delete(row, key)
		} else {
			row[key] = value
		}
	}
	data, _ := json.Marshal(row)
	sessions := filepath.Join(config, "sessions")
	if err := os.MkdirAll(sessions, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessions, strconv.Itoa(pid)+".json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func claudeTestConfig(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "claude")
}

func TestReadClaudeSessionActorNamesTheOwningDesktopSession(t *testing.T) {
	config := claudeTestConfig(t)
	_, inner, client := claudeChain(t, config)
	writeClaudeRegistration(t, config, inner, nil)
	actor, err := ReadClaudeSessionActor(client)
	if err != nil {
		t.Fatal(err)
	}
	if actor.SessionID != desktopTestSession || actor.AccountRoot != config || actor.PID != inner ||
		actor.ClientPID != client || actor.Source != claudeDesktopSessionSource || !actor.Target().Valid() {
		t.Fatalf("%+v", actor)
	}
}

func TestReadClaudeSessionActorRefusesClientsNoDesktopSessionOwns(t *testing.T) {
	cases := []struct {
		name     string
		innerRow map[string]any // nil: no record for the nearest session
		outerRow map[string]any
	}{
		{"no Claude ancestor publishes a record", nil, nil},
		{"nearest session is a terminal session, desktop further up", map[string]any{"entrypoint": "cli"}, map[string]any{}},
		{"stale record: process start differs", map[string]any{"procStart": "Thu Jan  1 00:00:00 1970"}, nil},
		{"record names another PID", map[string]any{"pid": 999999}, nil},
		{"background job", map[string]any{"kind": "bg"}, nil},
		{"Relay proxy", map[string]any{"relayProxy": true}, nil},
		{"invalid session ID", map[string]any{"sessionId": "not-a-session"}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			config := claudeTestConfig(t)
			outer, inner, client := claudeChain(t, config)
			if c.innerRow != nil {
				writeClaudeRegistration(t, config, inner, c.innerRow)
			}
			if c.outerRow != nil {
				writeClaudeRegistration(t, config, outer, c.outerRow)
			}
			actor, err := ReadClaudeSessionActor(client)
			if err == nil && actor.AccountRoot == config {
				t.Fatalf("client attributed to %+v", actor)
			}
		})
	}
	t.Run("group-writable record", func(t *testing.T) {
		config := claudeTestConfig(t)
		_, inner, client := claudeChain(t, config)
		writeClaudeRegistration(t, config, inner, nil)
		os.Chmod(filepath.Join(config, "sessions", strconv.Itoa(inner)+".json"), 0o620)
		if actor, err := ReadClaudeSessionActor(client); err == nil && actor.AccountRoot == config {
			t.Fatalf("attributed through a group-writable record: %+v", actor)
		}
	})
	t.Run("invalid client", func(t *testing.T) {
		if _, err := ReadClaudeSessionActor(1); err == nil {
			t.Fatal("PID 1 accepted")
		}
	})
}
