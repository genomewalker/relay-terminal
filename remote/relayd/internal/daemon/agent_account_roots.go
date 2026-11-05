package daemon

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// agentConfigOverride is an exact agent process's own CLAUDE_CONFIG_DIR or
// CODEX_HOME ("" when the provider default applies). Only that variable is
// read from the process environment.
func agentConfigOverride(pid int, provider string) (string, error) {
	name, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return "", err
	}
	vars, err := agentlaunch.ProcessEnvironment(pid, name)
	if err != nil {
		return "", err
	}
	value := vars[name]
	if value != "" && (!filepath.IsAbs(value) || filepath.Clean(value) != value || len(value) > 4096) {
		return "", errors.New("agent account directory is invalid")
	}
	return value, nil
}

// agentConfigRoot is the account directory an exact agent process uses: its
// override, else ~/.claude or ~/.codex of this host user.
func agentConfigRoot(pid int, provider string) (string, error) {
	override, err := agentConfigOverride(pid, provider)
	if err != nil || override != "" {
		return override, err
	}
	return defaultAgentConfigRoot(provider)
}

func defaultAgentConfigRoot(provider string) (string, error) {
	if provider != "claude" && provider != "codex" {
		return "", errors.New("unsupported provider")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("agent home unavailable")
	}
	return filepath.Join(home, "."+provider), nil
}

// validateClaudeConfigTranscript validates a transcript found in a Claude
// account directory: strictly inside that directory unless it is the default.
func validateClaudeConfigTranscript(path, config string) error {
	if fallback, err := defaultAgentConfigRoot("claude"); err == nil && fallback == config {
		return validateAccountTranscript(path, "claude", "")
	}
	return validateAccountTranscript(path, "claude", config)
}

// accountOverride converts an account root to the variable value that
// selects it. Codex's ~/.codex is its default (""); Claude's ~/.claude is
// kept, because an explicit CLAUDE_CONFIG_DIR=~/.claude reads another
// .claude.json than the unset default. A root alone cannot tell whether a
// Claude process set the variable, so binding records carry the process's
// own override (processAccountOverride), never a value derived from a root.
func accountOverride(provider, root string) string {
	if fallback, err := defaultAgentConfigRoot(provider); err == nil && fallback == root && provider == "codex" {
		return ""
	}
	return root
}

// claudeRecordOverride is a Claude frontend's own CLAUDE_CONFIG_DIR for its
// binding record: set (even to ~/.claude) or unset exactly as the process has
// it, checked against the directory its registration was read from.
func claudeRecordOverride(pid int, config string) (string, error) {
	override := processAccountOverride(pid, "claude")
	root := override
	if root == "" {
		root, _ = defaultAgentConfigRoot("claude")
	}
	if root != config {
		return "", errors.New("native Claude account changed during observation")
	}
	return override, nil
}

// processAccountOverride is agentConfigOverride for observations that already
// verify the process incarnation; an unreadable environment means the default.
func processAccountOverride(pid int, provider string) string {
	override, err := agentConfigOverride(pid, provider)
	if err != nil {
		return ""
	}
	return override
}

// processSourcePath resolves a transcript a verified agent process holds open
// inside that process's own account directory.
func processSourcePath(pid int, path, provider string) (string, error) {
	if override := processAccountOverride(pid, provider); override != "" {
		return rotationSourcePathIn(path, provider, override)
	}
	return rotationSourcePath(path, provider)
}
