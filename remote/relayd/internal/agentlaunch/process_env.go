package agentlaunch

import (
	"bytes"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// ConfigDirVariable names the environment variable that selects a provider's
// account directory: CLAUDE_CONFIG_DIR for Claude, CODEX_HOME for Codex.
func ConfigDirVariable(provider string) (string, error) {
	switch provider {
	case "claude":
		return "CLAUDE_CONFIG_DIR", nil
	case "codex":
		return "CODEX_HOME", nil
	}
	return "", errors.New("unsupported provider")
}

// ProcessConfigDirectory resolves the account directory an exact agent
// process was started with. It reads only HOME and the provider variable from
// that process's initial environment; no other value is read or returned.
// The override is the variable's value ("" when the provider default applies).
func ProcessConfigDirectory(pid int, provider string) (root, override string, err error) {
	name, err := ConfigDirVariable(provider)
	if err != nil {
		return "", "", err
	}
	vars, err := ProcessEnvironment(pid, "HOME", name)
	if err != nil {
		return "", "", err
	}
	root, err = ProviderConfigRoot(provider, vars)
	return root, vars[name], err
}

// ProviderConfigRoot applies the provider's own rule: the variable when set,
// otherwise ~/.claude or ~/.codex. Both CLIs require an absolute directory.
func ProviderConfigRoot(provider string, vars map[string]string) (string, error) {
	name, err := ConfigDirVariable(provider)
	if err != nil {
		return "", err
	}
	root := vars[name]
	if root == "" {
		home := vars["HOME"]
		if !filepath.IsAbs(home) || filepath.Clean(home) != home {
			return "", errors.New("agent home is unavailable")
		}
		root = filepath.Join(home, "."+provider)
	}
	if !filepath.IsAbs(root) || filepath.Clean(root) != root || len(root) > 4096 || strings.ContainsRune(root, 0) {
		return "", errors.New("agent account directory is invalid")
	}
	return root, nil
}

// selectEnvironment extracts only the requested keys from a NUL-separated
// environment block. A duplicated requested key is ambiguous and fails closed.
func selectEnvironment(block []byte, keys []string) (map[string]string, error) {
	wanted := make(map[string]bool, len(keys))
	for _, key := range keys {
		wanted[key] = true
	}
	vars := map[string]string{}
	for _, entry := range bytes.Split(block, []byte{0}) {
		key, value, found := bytes.Cut(entry, []byte{'='})
		if !found || !wanted[string(key)] {
			continue
		}
		if _, duplicate := vars[string(key)]; duplicate {
			return nil, errors.New("ambiguous agent environment")
		}
		vars[string(key)] = string(value)
	}
	return vars, nil
}

// ErrConfigDirMismatch reports that a running agent no longer uses the
// account directory its launch recorded. Relay reports this; it never
// switches a pane's account to resolve it.
var ErrConfigDirMismatch = errors.New("agent account directory differs from the recorded launch")

// ErrClaudeExplicitDefault is the mismatch between Claude's default account
// (CLAUDE_CONFIG_DIR unset) and CLAUDE_CONFIG_DIR naming ~/.claude: the
// directory is the same, but Claude then reads <dir>/.claude.json instead of
// ~/.claude.json, so it is not the same account state.
var ErrClaudeExplicitDefault = fmt.Errorf("%w: explicit ~/.claude uses a different .claude.json", ErrConfigDirMismatch)

// LaunchConfigDirectory resolves the account directory override of a
// snapshot's agent: the live process's own environment while its incarnation
// still matches, otherwise the recorded value. known is false only for a
// snapshot written before accounts were recorded whose process has exited.
func LaunchConfigDirectory(snapshot Snapshot) (override string, known bool, err error) {
	if VerifyProcess(snapshot) == nil {
		name, err := ConfigDirVariable(snapshot.Client)
		if err != nil {
			return "", false, err
		}
		vars, err := ProcessEnvironment(snapshot.PID, "HOME", name)
		if err != nil {
			return "", false, err
		}
		live := vars[name]
		if _, err := ProviderConfigRoot(snapshot.Client, vars); err != nil {
			return "", false, err
		}
		if snapshot.ConfigDirRecorded {
			if err := ConfigDirectoryMismatch(snapshot.Client, vars["HOME"], live, snapshot.ConfigDir); err != nil {
				return "", false, err
			}
		}
		// The live value is kept: a symlinked alias names the same account.
		return live, true, nil
	}
	if snapshot.ConfigDirRecorded {
		return snapshot.ConfigDir, true, nil
	}
	return "", false, nil
}

// SameConfigDirectory reports whether two account overrides select the same
// account. Both sides are compared as resolved real paths, so a symlinked
// alias is the same account. "" is the provider default under home: for
// Codex, CODEX_HOME naming ~/.codex is the default too; for Claude it is not,
// because an explicit CLAUDE_CONFIG_DIR moves Claude's global .claude.json.
func SameConfigDirectory(provider, home, a, b string) bool {
	return ConfigDirectoryMismatch(provider, home, a, b) == nil
}

// ConfigDirectoryMismatch is nil when two overrides select the same account,
// ErrClaudeExplicitDefault when they differ only by Claude's explicit
// ~/.claude, and ErrConfigDirMismatch otherwise.
func ConfigDirectoryMismatch(provider, home, a, b string) error {
	resolve := func(override string) (string, bool) {
		root, err := ProviderConfigRoot(provider, map[string]string{"HOME": home, mustVariable(provider): override})
		if err != nil {
			return "", false
		}
		if resolved, err := filepath.EvalSymlinks(root); err == nil {
			return resolved, true
		}
		return filepath.Clean(root), true
	}
	left, ok := resolve(a)
	right, valid := resolve(b)
	if !ok || !valid || left != right {
		return ErrConfigDirMismatch
	}
	if provider == "claude" && (a == "") != (b == "") {
		return ErrClaudeExplicitDefault
	}
	return nil
}

func mustVariable(provider string) string {
	name, _ := ConfigDirVariable(provider)
	return name
}
