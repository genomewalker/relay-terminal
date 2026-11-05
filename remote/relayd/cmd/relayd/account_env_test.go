package main

import (
	"os"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestResumeSavedUsesTheConversationsAccount(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/inherited/from/new-pane")
	if err := resumeSavedAccount("claude", "/home/u/.claude-personal"); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("CLAUDE_CONFIG_DIR"); got != "/home/u/.claude-personal" {
		t.Fatalf("resume account = %q", got)
	}
	if err := resumeSavedAccount("claude", ""); err != nil {
		t.Fatal(err)
	}
	if _, set := os.LookupEnv("CLAUDE_CONFIG_DIR"); set {
		t.Fatal("a default-account conversation must resume with CLAUDE_CONFIG_DIR unset")
	}
	t.Setenv("CODEX_HOME", "")
	if err := resumeSavedAccount("codex", "relative"); err == nil {
		t.Fatal("a relative account directory was accepted")
	}
	if err := resumeSavedAccount("codex", "/home/u/.codex-personal"); err != nil || os.Getenv("CODEX_HOME") != "/home/u/.codex-personal" {
		t.Fatalf("Codex resume account = %q %v", os.Getenv("CODEX_HOME"), err)
	}
}

func TestRotationKeepsTheSourceAccount(t *testing.T) {
	// The dedicated worker inherits the daemon's environment.
	t.Setenv("CODEX_HOME", "/daemon/default")
	exited := agentlaunch.Snapshot{Client: "codex", PID: 1 << 22, ProcessStart: "1",
		ConfigDir: "/home/u/.codex-personal", ConfigDirRecorded: true}
	if err := keepRotationAccount(exited); err != nil || os.Getenv("CODEX_HOME") != "/home/u/.codex-personal" {
		t.Fatalf("rotation account = %q %v", os.Getenv("CODEX_HOME"), err)
	}
	exited.ConfigDir = ""
	if err := keepRotationAccount(exited); err != nil {
		t.Fatal(err)
	}
	if _, set := os.LookupEnv("CODEX_HOME"); set {
		t.Fatal("a default-account rotation must clear CODEX_HOME")
	}
	t.Setenv("CODEX_HOME", "/daemon/default")
	legacy := agentlaunch.Snapshot{Client: "codex", PID: 1 << 22, ProcessStart: "1"}
	if err := keepRotationAccount(legacy); err != nil || os.Getenv("CODEX_HOME") != "/daemon/default" {
		t.Fatalf("a legacy snapshot must leave the environment unchanged: %q %v", os.Getenv("CODEX_HOME"), err)
	}
}
