//go:build unix

package agentaccounts

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeRegistryCLI is a stand-in for `claude -p`: it publishes
// $CLAUDE_CONFIG_DIR/sessions/<pid>.json at start and removes it only when it
// ends cleanly (stdin EOF) or on SIGTERM, like Claude Code does. SIGKILL
// leaves the record behind. The short pause before removal is the real CLI's
// own exit work (about 0.2 s observed).
//
//	answer: whether it answers the u2 get_usage request.
//	onEOF:  "exit" removes the record and exits; "stay" ignores EOF.
//	onTERM: "clean" removes the record and exits; "ignore" ignores SIGTERM.
func fakeRegistryCLI(t *testing.T, directory string, answer bool, onEOF, onTERM string) string {
	t.Helper()
	script := filepath.Join(directory, "claude")
	var b strings.Builder
	b.WriteString("#!/bin/sh\n")
	b.WriteString("reg=\"$CLAUDE_CONFIG_DIR/sessions/$$.json\"\n")
	b.WriteString("mkdir -p \"$CLAUDE_CONFIG_DIR/sessions\"\n")
	b.WriteString("printf '{\"pid\":%s}' \"$$\" > \"$reg\"\n")
	b.WriteString("printf '%s' \"$$\" > \"$CLAUDE_CONFIG_DIR/leader-pid\"\n")
	if onTERM == "ignore" {
		b.WriteString("trap '' TERM\n")
	} else {
		b.WriteString("trap 'sleep 0.2; rm -f \"$reg\"; exit 143' TERM\n")
	}
	b.WriteString("while IFS= read -r line; do\n  :\n")
	if answer {
		b.WriteString("  case \"$line\" in *'\"request_id\":\"u2\"'*) printf '%s\\n' '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"u2\",\"response\":{}}}';; esac\n")
	}
	b.WriteString("done\n")
	if onEOF == "stay" {
		// Ignore EOF. An ignored SIGTERM stays ignored in the sleep too.
		b.WriteString("while :; do sleep 1; done\n")
	} else {
		b.WriteString("sleep 0.2; rm -f \"$reg\"; exit 0\n")
	}
	writeFile(t, script, b.String())
	if err := os.Chmod(script, 0o700); err != nil {
		t.Fatal(err)
	}
	return script
}

func sessionRecords(t *testing.T, account string) []string {
	t.Helper()
	names, _ := filepath.Glob(filepath.Join(account, "sessions", "*.json"))
	return names
}

func leaderGone(t *testing.T, account string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(account, "leader-pid"))
	if err != nil {
		t.Fatalf("leader pid: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	if syscall.Kill(pid, 0) == nil {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		t.Fatalf("fake CLI %d still running after ProviderUsage returned", pid)
	}
}

// After the answer, the probe closes stdin and lets the CLI exit by itself,
// so the CLI's session record is gone when ProviderUsage returns and the
// answer is still returned.
func TestUsageProbeLetsTheCLIRemoveItsSessionRecord(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("RELAY_CLAUDE_BIN", fakeRegistryCLI(t, directory, true, "exit", "clean"))
	account := filepath.Join(directory, "account")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	line, err := ProviderUsage(ctx, "claude", account)
	if err != nil || !strings.Contains(string(line), `"request_id":"u2"`) {
		t.Fatalf("answer %q: %v", line, err)
	}
	if left := sessionRecords(t, account); len(left) != 0 {
		t.Fatalf("session records left behind: %v", left)
	}
	leaderGone(t, account)
}

// A CLI that answers but ignores EOF is ended by SIGTERM after the exit
// limit, which still lets it remove its record; the answer is returned.
func TestUsageProbeEndsAnAnsweredCLIThatIgnoresEOFWithSIGTERM(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("RELAY_CLAUDE_BIN", fakeRegistryCLI(t, directory, true, "stay", "clean"))
	account := filepath.Join(directory, "account")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	started := time.Now()
	line, err := ProviderUsage(ctx, "claude", account)
	elapsed := time.Since(started)
	if err != nil || !strings.Contains(string(line), `"request_id":"u2"`) {
		t.Fatalf("answer %q: %v", line, err)
	}
	if elapsed > 2*usageExitLimit+2*time.Second {
		t.Fatalf("took %v", elapsed)
	}
	if left := sessionRecords(t, account); len(left) != 0 {
		t.Fatalf("session records left behind: %v", left)
	}
	leaderGone(t, account)
}

// The timeout path still ends the CLI and returns the existing reason; with
// SIGTERM first, the CLI removes its record.
func TestUsageProbeTimeoutTerminatesAndKeepsItsReason(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("RELAY_CLAUDE_BIN", fakeRegistryCLI(t, directory, false, "exit", "clean"))
	account := filepath.Join(directory, "account")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	started := time.Now()
	_, err := ProviderUsage(ctx, "claude", account)
	if elapsed := time.Since(started); elapsed > time.Second+usageExitLimit+2*time.Second {
		t.Fatalf("took %v", elapsed)
	}
	if err == nil || err.Error() != "claude did not answer in 1 s" {
		t.Fatalf("reason: %v", err)
	}
	if left := sessionRecords(t, account); len(left) != 0 {
		t.Fatalf("session records left behind: %v", left)
	}
	leaderGone(t, account)
}

// A CLI that ignores SIGTERM is still ended (SIGKILL fallback) and the
// timeout reason is unchanged by the grace period. ProviderUsage runs under
// the same time bound as before; past it the test kills the fake CLI's
// process group itself, so a broken fallback fails here instead of hanging.
func TestUsageProbeTimeoutFallsBackToSIGKILL(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("RELAY_CLAUDE_BIN", fakeRegistryCLI(t, directory, false, "stay", "ignore"))
	account := filepath.Join(directory, "account")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	bound := time.Second + usageExitLimit + 2*time.Second
	started := time.Now()
	type outcome struct{ err error }
	done := make(chan outcome, 1)
	go func() {
		_, err := ProviderUsage(ctx, "claude", account)
		done <- outcome{err}
	}()
	var err error
	select {
	case result := <-done:
		err = result.err
	case <-time.After(bound):
		if data, readErr := os.ReadFile(filepath.Join(account, "leader-pid")); readErr == nil {
			if pid, convErr := strconv.Atoi(strings.TrimSpace(string(data))); convErr == nil && pid > 1 {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
		t.Fatalf("SIGKILL fallback did not end the CLI within %v", bound)
	}
	if elapsed := time.Since(started); elapsed > bound {
		t.Fatalf("took %v", elapsed)
	}
	if err == nil || err.Error() != "claude did not answer in 1 s" {
		t.Fatalf("reason: %v", err)
	}
	leaderGone(t, account)
}
