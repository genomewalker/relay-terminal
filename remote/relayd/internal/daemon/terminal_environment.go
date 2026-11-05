package daemon

import (
	"os"
	"strings"
)

// TerminalEnvironment prevents the noninteractive launcher's color policy from
// leaking into interactive terminals. Shell startup files can still set their
// own preferences after launch. Preserve PATH ordering and empty components.
// A relayd started from inside a Claude Code session inherits that session's
// CLAUDECODE and CLAUDE_CODE_* markers (session ID, messaging socket and token,
// child-session flag); a Claude later started in a pane would take itself for
// that session's child and stop saving its transcript, so they are dropped.
func TerminalEnvironment(environment []string) []string {
	result := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if name == "NO_COLOR" || inheritedClaudeSessionVariable(name) {
			continue
		}
		if found && name == "PATH" {
			seen := map[string]bool{}
			parts := []string{}
			for _, part := range strings.Split(value, string(os.PathListSeparator)) {
				if part == "$PATH" || part == "${PATH}" || seen[part] {
					continue
				}
				seen[part] = true
				parts = append(parts, part)
			}
			entry = "PATH=" + strings.Join(parts, string(os.PathListSeparator))
		}
		result = append(result, entry)
	}
	return result
}

func inheritedClaudeSessionVariable(name string) bool {
	return name == "CLAUDECODE" || strings.HasPrefix(name, "CLAUDE_CODE_")
}
