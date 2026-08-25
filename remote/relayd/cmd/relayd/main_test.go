package main

import (
	"encoding/json"
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
