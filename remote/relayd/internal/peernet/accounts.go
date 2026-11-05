package peernet

import (
	"os"
	"path/filepath"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// claudeConfig is the Claude account directory a peer process publishes in:
// its own CLAUDE_CONFIG_DIR, else home/.claude. Records found there are still
// verified against the process's PID and start time before any use.
func claudeConfig(home string, pid int) string {
	if pid > 1 {
		if vars, err := agentlaunch.ProcessEnvironment(pid, "CLAUDE_CONFIG_DIR"); err == nil {
			if value := vars["CLAUDE_CONFIG_DIR"]; validConfig(value) {
				return value
			}
		}
	}
	return filepath.Join(home, ".claude")
}

// ownClaudeConfig is claudeConfig for this process, which runs inside the
// Claude session it registers.
func ownClaudeConfig(home string) string {
	if value := os.Getenv("CLAUDE_CONFIG_DIR"); validConfig(value) {
		return value
	}
	return filepath.Join(home, ".claude")
}

func codexConfig(home string, pid int) string {
	if pid > 1 {
		if vars, err := agentlaunch.ProcessEnvironment(pid, "CODEX_HOME"); err == nil {
			if value := vars["CODEX_HOME"]; validConfig(value) {
				return value
			}
		}
	}
	return filepath.Join(home, ".codex")
}

func validConfig(value string) bool {
	return value != "" && filepath.IsAbs(value) && filepath.Clean(value) == value
}

// claudeConfigs lists the default and every configured Claude account
// directory, for discovery only.
func claudeConfigs(home string) []string {
	return agentaccounts.Roots(home, "claude")
}
