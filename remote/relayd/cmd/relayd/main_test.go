package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestClaudeHookSettings(t *testing.T) {
	if !json.Valid([]byte(claudeHookSettings)) {
		t.Fatal("Claude hook settings are not valid JSON")
	}
	for _, event := range []string{"PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"} {
		if !strings.Contains(claudeHookSettings, `"`+event+`"`) {
			t.Fatalf("Claude hook settings are missing %s", event)
		}
	}
}

func TestFindRealAgentExecutableSkipsRelayShim(t *testing.T) {
	root := t.TempDir()
	shimDirectory := filepath.Join(root, "shims")
	realDirectory := filepath.Join(root, "real")
	if err := os.MkdirAll(shimDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(realDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, filepath.Join(shimDirectory, "codex")); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(realDirectory, "codex")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDirectory+string(os.PathListSeparator)+realDirectory)

	found, err := findRealAgentExecutable("codex")
	if err != nil {
		t.Fatal(err)
	}
	if found != real {
		t.Fatalf("found %q, want %q", found, real)
	}
}

func TestCodexHookProfile(t *testing.T) {
	profile := codexHookProfile("/home/test/.codex/relay-terminal.config.toml")
	for _, event := range []string{"SessionStart", "PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"} {
		if !strings.Contains(profile, "[[hooks."+event+"]]") {
			t.Fatalf("Codex hook profile is missing %s", event)
		}
	}
	if !strings.Contains(profile, "--agent codex") {
		t.Fatal("Codex hook profile does not forward events to Relay")
	}
	if !strings.Contains(profile, `[hooks.state."/home/test/.codex/relay-terminal.config.toml:session_start:0:0"]`) {
		t.Fatal("Codex hook trust is not scoped to its generated SessionStart hook")
	}
	if got := codexHookHash("session_start", &codexWildcardMatcher); got != "sha256:0947938d6af2c56fe7cdf8b745e79997e0caaee90cd6d607a8a193f9eae6b30e" {
		t.Fatalf("Codex hook trust hash changed: %s", got)
	}
}

func TestParseObservedSessionsPreservesEventCursors(t *testing.T) {
	sessions := parseObservedSessions("pane-a:42,pane-b,pane-a:99")
	if len(sessions) != 2 || sessions[0].id != "pane-a" || sessions[0].lastEventSequence != 42 ||
		sessions[1].id != "pane-b" || sessions[1].lastEventSequence != 0 {
		t.Fatalf("unexpected observed sessions: %#v", sessions)
	}
}

func TestDefaultSocketNeverUsesSharedHome(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("HOME", "/shared/home/test")
	want := filepath.Join("/tmp", "relay-"+strconv.Itoa(os.Getuid()), "relayd.sock")
	if got := defaultSocket(); got != want {
		t.Fatalf("default socket = %q, want node-local %q", got, want)
	}

	t.Setenv("XDG_RUNTIME_DIR", "/run/user/123")
	if got := defaultSocket(); got != "/run/user/123/relayd.sock" {
		t.Fatalf("runtime socket = %q", got)
	}
}
