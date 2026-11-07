package peernet

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// claudeConfig is the Claude account directory a peer process publishes in:
// exactly its own CLAUDE_CONFIG_DIR, or home/.claude only when that variable
// is unset. An unreadable environment, a set but invalid directory and a
// process that is gone are errors: no other account is ever tried.
// Records found there are still verified against the process's PID and start
// time before any use.
func claudeConfig(home string, pid int) (string, error) {
	if pid <= 1 {
		return "", errors.New("invalid peer process")
	}
	vars, err := agentlaunch.ProcessEnvironment(pid, "CLAUDE_CONFIG_DIR")
	if err != nil {
		return "", err
	}
	value, set := vars["CLAUDE_CONFIG_DIR"]
	if !set {
		return filepath.Join(home, ".claude"), nil
	}
	if !validConfig(value) {
		return "", errors.New("peer account directory is invalid")
	}
	return value, nil
}

// ownClaudeConfig is claudeConfig for this process, which runs inside the
// Claude session it registers. Its own environment is authoritative.
func ownClaudeConfig(home string) (string, error) {
	value, set := os.LookupEnv("CLAUDE_CONFIG_DIR")
	if !set {
		return filepath.Join(home, ".claude"), nil
	}
	if !validConfig(value) {
		return "", errors.New("account directory is invalid")
	}
	return value, nil
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
