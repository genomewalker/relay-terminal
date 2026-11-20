package daemon

import "testing"

// The conversation composer treats stop_observed as ready to send, so Stop
// must be the only event that yields it, and any notification other than
// Claude's idle prompt must keep the terminal's answer pending.
func TestClaudeHookLifecycleContract(t *testing.T) {
	cases := []struct{ name, notification, want string }{
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
		{"SubagentStop", "", "unknown"},
		{"SessionStart", "", "unknown"},
		{"", "", "unknown"},
	}
	for _, c := range cases {
		if got := claudeHookLifecycle(c.name, c.notification); got != c.want {
			t.Errorf("claudeHookLifecycle(%q, %q) = %q, want %q", c.name, c.notification, got, c.want)
		}
	}
}
