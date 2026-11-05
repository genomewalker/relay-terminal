package daemon

import (
	"reflect"
	"testing"
)

func TestTerminalEnvironmentRemovesLauncherColorPolicy(t *testing.T) {
	input := []string{"NO_COLOR=1", "PATH=/relay:/usr/bin:/relay:$PATH:${PATH}::/bin:", "HOME=/home/user", "LANG=en_US.UTF-8", "CUSTOM=preserved", "COLORTERM=truecolor"}
	want := []string{"PATH=/relay:/usr/bin::/bin", "HOME=/home/user", "LANG=en_US.UTF-8", "CUSTOM=preserved", "COLORTERM=truecolor"}
	got := TerminalEnvironment(input)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	if !reflect.DeepEqual(TerminalEnvironment(got), got) {
		t.Fatal("normalization must be idempotent")
	}
	if input[0] != "NO_COLOR=1" {
		t.Fatal("input was mutated")
	}
}

// A relayd started from a Claude Code shell must not hand that session's
// markers to new panes; Claude's own configuration variables are kept.
func TestTerminalEnvironmentDropsInheritedClaudeSessionMarkers(t *testing.T) {
	input := []string{"CLAUDECODE=1", "HOME=/home/user", "CLAUDE_CODE_CHILD_SESSION=1", "CLAUDE_CODE_SESSION_ID=abc",
		"CLAUDE_CODE_MESSAGING_TOKEN=secret", "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CONFIG_DIR=/home/user/.claude-max",
		"CLAUDECODE_EXTRA=kept", "MY_CLAUDE_CODE_NOTE=kept", "CLAUDE_CODE=kept", "PATH=/usr/bin"}
	want := []string{"HOME=/home/user", "CLAUDE_CONFIG_DIR=/home/user/.claude-max", "CLAUDECODE_EXTRA=kept",
		"MY_CLAUDE_CODE_NOTE=kept", "CLAUDE_CODE=kept", "PATH=/usr/bin"}
	if got := TerminalEnvironment(input); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}
