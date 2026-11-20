package daemon

import "testing"

// The conversation composer treats stop_observed as ready to send, so Stop
// must be the only event that yields it, and any notification other than
// Claude's idle prompt must keep the terminal's answer pending.
func TestClaudeHookLifecycleContract(t *testing.T) {
	cases := []struct{ name, detail, want string }{
		{"Stop", "", "stop_observed"},
		{"Notification", "idle_prompt", "quiet"},
		{"Notification", "permission_prompt", "needs_input"},
		{"Notification", "", "needs_input"},
		{"PermissionRequest", "", "needs_input"},
		{"UserPromptSubmit", "", "active"},
		{"PreToolUse", "", "active"},
		{"PostToolUse", "", "active"},
		{"PostToolUseFailure", "", "active"},
		{"SessionEnd", "", "exited"},
		// A started, resumed or cleared session waits at an empty prompt.
		{"SessionStart", "startup", "stop_observed"},
		{"SessionStart", "resume", "stop_observed"},
		{"SessionStart", "clear", "stop_observed"},
		// Events about subagents or compaction keep the stored lifecycle.
		{"SessionStart", "compact", ""},
		{"SessionStart", "", ""},
		{"SubagentStart", "", ""},
		{"SubagentStop", "", ""},
		{"PreCompact", "", ""},
		{"", "", "unknown"},
		{"FutureEvent", "", "unknown"},
	}
	for _, c := range cases {
		if got := claudeHookLifecycle(c.name, c.detail); got != c.want {
			t.Errorf("claudeHookLifecycle(%q, %q) = %q, want %q", c.name, c.detail, got, c.want)
		}
	}
}

func TestClaudeHookDetailReadsSessionStartSource(t *testing.T) {
	if got := claudeHookDetail(map[string]any{"hook_event_name": "SessionStart", "source": "resume", "notification_type": "idle_prompt"}); got != "resume" {
		t.Fatalf("SessionStart detail = %q, want resume", got)
	}
	if got := claudeHookDetail(map[string]any{"hook_event_name": "Notification", "source": "resume", "notification_type": "idle_prompt"}); got != "idle_prompt" {
		t.Fatalf("Notification detail = %q, want idle_prompt", got)
	}
}
