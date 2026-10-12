//go:build linux

package agentlaunch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodexStartSettingsUseLastCompletedEffectiveContext(t *testing.T) {
	thread := "12345678-1234-4234-8234-123456789abc"
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	rows := []string{
		`{"type":"session_meta","payload":{"id":"` + thread + `"}}`,
		`{"type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}`,
		`{"type":"turn_context","payload":{"turn_id":"one","model":"old","cwd":"/work","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"effort":"low","personality":"friendly"}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","turn_id":"one"}}`,
		`{"type":"event_msg","payload":{"type":"task_started","turn_id":"two"}}`,
		`{"type":"turn_context","payload":{"turn_id":"two","model":"gpt-6-sol","cwd":"/work","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"effort":"medium","personality":"friendly"}}`,
		`{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6-sol","approval_policy":"never","cwd":"/work"}}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","turn_id":"two"}}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(rows, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readCodexStartSettings(path, thread)
	if err != nil {
		t.Fatal(err)
	}
	if got.SourceTurnID != "two" || got.StartParameters["model"] != "gpt-6-sol" ||
		got.StartParameters["sandbox"] != "dangerFullAccess" || got.Effort != "medium" {
		t.Fatalf("wrong effective settings: %+v", got)
	}
	changed := strings.ReplaceAll(strings.Join(rows, "\n"), `"model":"gpt-6-sol","approval_policy":"never","cwd":"/work"`, `"model":"other","approval_policy":"never","cwd":"/work"`)
	if err := os.WriteFile(path, []byte(changed+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readCodexStartSettings(path, thread); err == nil {
		t.Fatal("changed post-context model was accepted")
	}
}
