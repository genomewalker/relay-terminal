package main

import (
	"encoding/json"
	"os"
	"path/filepath"
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
	for _, event := range []string{"SessionStart", "PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"} {
		if !strings.Contains(codexHookProfile, "[[hooks."+event+"]]") {
			t.Fatalf("Codex hook profile is missing %s", event)
		}
	}
	if !strings.Contains(codexHookProfile, "--agent codex") {
		t.Fatal("Codex hook profile does not forward events to Relay")
	}
}
