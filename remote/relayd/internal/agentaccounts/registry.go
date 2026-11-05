// Package agentaccounts keeps a host's provider accounts: which Claude or
// Codex config directory each account label uses. An account is selected only
// by its directory (CLAUDE_CONFIG_DIR or CODEX_HOME); Relay never reads,
// copies or moves provider credentials. Login runs the provider's own flow.
package agentaccounts

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// Account maps a label to a provider config directory on this host. Dir is
// "" for the provider default (~/.claude or ~/.codex, variable unset), else
// "~/name" or an absolute path. The default is not the same as setting the
// variable to ~/.claude: Claude then moves its global .claude.json.
type Account struct {
	Provider string `json:"provider"`
	Label    string `json:"label"`
	Dir      string `json:"dir"`
	// ShareHistory is the user's opt-in to link the main directory's
	// conversation history (never credentials or account state).
	ShareHistory bool `json:"share_history,omitempty"`
	// MCPExclude names main MCP servers that are never copied here.
	MCPExclude []string `json:"mcp_exclude,omitempty"`
	// ExpectWorkspace and ExpectPlan are the workspace (organization) and
	// plan the user means this slot for; ExpectKey pins the workspace key a
	// sign-in reported. Settings compares a fresh sign-in with them.
	ExpectWorkspace string `json:"expect_workspace,omitempty"`
	ExpectPlan      string `json:"expect_plan,omitempty"`
	ExpectKey       string `json:"expect_key,omitempty"`
}

type Registry struct {
	Version  int       `json:"version"`
	Accounts []Account `json:"accounts"`
}

const registryVersion = 1

var (
	labelPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,23}$`)
	keyPattern   = regexp.MustCompile(`^[0-9a-f]{16}$`)
	// Directories are typed into a shell as "$HOME/..." or as an absolute
	// path, so only characters that need no quoting are accepted.
	dirPattern = regexp.MustCompile(`^(~/|/)[A-Za-z0-9._/-]{1,240}$`)
)

// DefaultRegistry: the main directories are "work" (the default), and
// "personal" uses ~/.claude-personal and ~/.codex-personal.
func DefaultRegistry() Registry {
	return Registry{Version: registryVersion, Accounts: []Account{
		{Provider: "claude", Label: "work", Dir: ""},
		{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"},
		{Provider: "codex", Label: "work", Dir: ""},
		{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"},
	}}
}

func Path(home string) string { return filepath.Join(home, ".relay", "agent-accounts.json") }

// Normalize validates a registry and folds a Codex directory that resolves to
// the main directory back to the default (Claude's explicit ~/.claude is
// refused). Labels and resolved directories are unique per provider (each
// provider keeps its own set of roots), no account directory is inside
// another of the same provider, and each provider keeps exactly one account
// on the default directory.
func Normalize(registry Registry, home string) (Registry, error) {
	if registry.Version != registryVersion || len(registry.Accounts) == 0 || len(registry.Accounts) > 16 {
		return Registry{}, errors.New("invalid agent account registry")
	}
	result := Registry{Version: registryVersion}
	labels := map[string]bool{}
	// Resolved account roots, one set per provider: another provider's
	// row never replaces an earlier entry.
	roots := map[string]map[string]bool{}
	defaults := map[string]int{}
	for _, account := range registry.Accounts {
		if account.Provider != "claude" && account.Provider != "codex" {
			return Registry{}, errors.New("account provider must be claude or codex")
		}
		if !labelPattern.MatchString(account.Label) {
			return Registry{}, errors.New("account labels use 1-24 lowercase letters, digits, '-' or '_'")
		}
		if account.Dir != "" {
			if !dirPattern.MatchString(account.Dir) || strings.Contains(account.Dir, "..") ||
				strings.Contains(account.Dir, "//") || strings.HasSuffix(account.Dir, "/") {
				return Registry{}, errors.New("account directory must be ~/name or an absolute path without spaces or '..'")
			}
			// Real paths decide, every parent included, so an alias of
			// the main directory is the main directory.
			root, main := resolvedRoot(account.Root(home)), resolvedRoot(defaultRoot(home, account.Provider))
			if root == main {
				// CODEX_HOME=~/.codex is the default account; Claude's
				// explicit ~/.claude is not, it reads another .claude.json.
				if account.Provider == "claude" {
					return Registry{}, errors.New("leave the directory empty for Claude's main account: an explicit ~/.claude uses a different .claude.json")
				}
				account.Dir = ""
			} else if within(root, main) || within(main, root) {
				return Registry{}, errors.New("an account directory cannot be inside the main directory or contain it")
			}
		}
		if account.Dir == "" {
			defaults[account.Provider]++
			if account.ShareHistory || len(account.MCPExclude) > 0 {
				return Registry{}, errors.New("the main account is the source of shared history and MCP servers")
			}
		}
		if !displayText(account.ExpectWorkspace, 64) || !displayText(account.ExpectPlan, 32) ||
			(account.ExpectKey != "" && !keyPattern.MatchString(account.ExpectKey)) {
			return Registry{}, errors.New("an expected workspace or plan is at most 64 printable characters")
		}
		exclude, err := normalizeServerNames(account.MCPExclude)
		if err != nil {
			return Registry{}, err
		}
		account.MCPExclude = exclude
		label, root := account.Provider+"\x00"+account.Label, resolvedRoot(account.Root(home))
		if labels[label] {
			return Registry{}, errors.New("each account needs its own label and directory")
		}
		for other := range roots[account.Provider] {
			if other == root || within(other, root) || within(root, other) {
				return Registry{}, errors.New("each account needs its own label and directory")
			}
		}
		if roots[account.Provider] == nil {
			roots[account.Provider] = map[string]bool{}
		}
		labels[label], roots[account.Provider][root] = true, true
		result.Accounts = append(result.Accounts, account)
	}
	for provider, count := range defaults {
		if count > 1 {
			return Registry{}, errors.New(provider + " has more than one account on its default directory")
		}
	}
	return result, nil
}

func normalizeServerNames(names []string) ([]string, error) {
	if len(names) == 0 {
		return nil, nil
	}
	if len(names) > 64 {
		return nil, errors.New("at most 64 MCP servers can be excluded")
	}
	seen := map[string]bool{}
	result := []string{}
	for _, name := range names {
		if name == "" || len(name) > 128 || strings.IndexFunc(name, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0 {
			return nil, errors.New("MCP server names are 1-128 characters without control characters")
		}
		if !seen[name] {
			seen[name] = true
			result = append(result, name)
		}
	}
	sort.Strings(result)
	return result, nil
}

func (a Account) excludes(server string) bool {
	for _, name := range a.MCPExclude {
		if name == server {
			return true
		}
	}
	return false
}

// Root is the absolute account directory on this host.
func (a Account) Root(home string) string {
	switch {
	case a.Dir == "":
		return defaultRoot(home, a.Provider)
	case strings.HasPrefix(a.Dir, "~/"):
		return filepath.Join(home, a.Dir[2:])
	}
	return filepath.Clean(a.Dir)
}

// Override is the variable value that selects this account ("" = unset).
func (a Account) Override(home string) string {
	if a.Dir == "" {
		return ""
	}
	return a.Root(home)
}

func defaultRoot(home, provider string) string { return filepath.Join(home, "."+provider) }

// resolvedRoot is path with every symbolic link resolved, parents included.
// A missing tail (an account not created yet) is kept as written below its
// longest existing, resolved prefix.
func resolvedRoot(path string) string {
	path = filepath.Clean(path)
	for prefix, rest := path, ""; ; {
		if resolved, err := filepath.EvalSymlinks(prefix); err == nil {
			return filepath.Join(resolved, rest)
		}
		parent := filepath.Dir(prefix)
		if parent == prefix {
			return path
		}
		rest = filepath.Join(filepath.Base(prefix), rest)
		prefix = parent
	}
}

// within reports whether path is strictly below directory.
func within(path, directory string) bool {
	relative, err := filepath.Rel(directory, path)
	return err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) &&
		!filepath.IsAbs(relative)
}

// Load returns the host registry, or the defaults when none was saved.
func Load(home string) (Registry, error) {
	path := Path(home)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return DefaultRegistry(), nil
	}
	if err != nil {
		return Registry{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0o022 != 0 || info.Size() > 65536 {
		return Registry{}, errors.New("agent account registry is not private")
	}
	file, err := os.Open(path)
	if err != nil {
		return Registry{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(data) > 65536 {
		return Registry{}, errors.New("agent account registry exceeds its limit")
	}
	var registry Registry
	if err := json.Unmarshal(data, &registry); err != nil {
		return Registry{}, errors.New("agent account registry is invalid")
	}
	return Normalize(registry, home)
}

// Save writes the registry atomically with owner-only permissions.
func Save(home string, registry Registry) (Registry, error) {
	registry, err := Normalize(registry, home)
	if err != nil {
		return Registry{}, err
	}
	data, err := json.MarshalIndent(registry, "", "  ")
	if err != nil {
		return Registry{}, err
	}
	if err := os.MkdirAll(filepath.Dir(Path(home)), 0o700); err != nil {
		return Registry{}, err
	}
	return registry, writeAtomic(Path(home), append(data, '\n'), 0o600)
}

// displayText accepts "" or up to limit bytes of printable text without
// surrounding space.
func displayText(value string, limit int) bool {
	if len(value) > limit || strings.TrimSpace(value) != value || !utf8.ValidString(value) {
		return false
	}
	for _, r := range value {
		if !unicode.IsPrint(r) {
			return false
		}
	}
	return true
}

// Find returns the account with the label, or the account using an override.
func (r Registry) Find(provider, label string) (Account, bool) {
	for _, account := range r.Accounts {
		if account.Provider == provider && account.Label == label {
			return account, true
		}
	}
	return Account{}, false
}

// LabelFor names the account whose directory a process override selects.
func (r Registry) LabelFor(home, provider, override string) (string, bool) {
	for _, account := range r.Accounts {
		if account.Provider == provider && account.Override(home) == override {
			return account.Label, true
		}
	}
	return "", false
}

// Roots lists every configured account directory of a provider; the default
// directory is always included. Callers must still verify what they find.
func Roots(home, provider string) []string {
	registry, err := Load(home)
	if err != nil {
		registry = DefaultRegistry()
	}
	roots := []string{defaultRoot(home, provider)}
	for _, account := range registry.Accounts {
		if account.Provider == provider && account.Dir != "" {
			roots = append(roots, account.Root(home))
		}
	}
	return roots
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	name, err := writeTemp(path, data, mode)
	if err != nil {
		return err
	}
	defer os.Remove(name)
	return os.Rename(name, path)
}

// writeTemp writes data, synced, to a new temporary file beside path.
func writeTemp(path string, data []byte, mode os.FileMode) (string, error) {
	file, err := os.CreateTemp(filepath.Dir(path), ".relay-account-*")
	if err != nil {
		return "", err
	}
	name := file.Name()
	fail := func(err error) (string, error) {
		file.Close()
		os.Remove(name)
		return "", err
	}
	if err := file.Chmod(mode); err != nil {
		return fail(err)
	}
	if _, err := file.Write(data); err != nil {
		return fail(err)
	}
	if err := file.Sync(); err != nil {
		return fail(err)
	}
	if err := file.Close(); err != nil {
		os.Remove(name)
		return "", err
	}
	return name, nil
}
