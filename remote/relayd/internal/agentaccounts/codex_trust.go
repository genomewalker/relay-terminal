package agentaccounts

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Codex folder-trust states for a launch directory under one CODEX_HOME.
const (
	// CodexTrustTrusted: config.toml trusts the directory itself, or the root
	// of the git repository holding it.
	CodexTrustTrusted = "trusted"
	// CodexTrustParentOnly: only a parent of a directory outside any trusted
	// repository root is trusted. Codex 0.170.0 shows its folder-trust dialog
	// for such a directory (7b68ee70, 2026-11-18); 0.169.0 did not.
	CodexTrustParentOnly = "parent_only"
	// CodexTrustUntrusted: no entry trusts it, or an entry marks it untrusted.
	CodexTrustUntrusted = "untrusted"
	// CodexTrustUnknown: config.toml could not be read.
	CodexTrustUnknown = "unknown"
)

// CodexTrust is how one account's config.toml trusts one launch directory.
type CodexTrust struct {
	Status string `json:"status"`
	Dir    string `json:"cwd"`
	// Parent is the trusted ancestor entry for CodexTrustParentOnly.
	Parent string `json:"parent,omitempty"`
}

// codexProjectTrust is the trust_level of each [projects."<path>"] entry.
func codexProjectTrust(document *tomlDocument) map[string]string {
	result := map[string]string{}
	projects := document.root.table("projects")
	if projects == nil {
		return result
	}
	for _, key := range projects.keys {
		if entry, ok := projects.values[key].(*tomlTable); ok {
			if level, ok := entry.values["trust_level"].(string); ok {
				result[key] = level
			}
		}
	}
	return result
}

// gitRoot is the nearest ancestor of dir (itself included) holding .git.
func gitRoot(dir string) string {
	for current := dir; ; current = filepath.Dir(current) {
		if _, err := os.Lstat(filepath.Join(current, ".git")); err == nil {
			return current
		}
		if current == filepath.Dir(current) {
			return ""
		}
	}
}

// CodexProjectTrust reads home/config.toml and says whether a Codex launched
// in dir is trusted without its folder-trust dialog. It never writes.
func CodexProjectTrust(home, dir string) CodexTrust {
	result := CodexTrust{Status: CodexTrustUnknown, Dir: dir}
	if !filepath.IsAbs(home) || !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return result
	}
	document, _, seen, err := readCodexMain(filepath.Join(home, "config.toml"))
	if err != nil {
		return result
	}
	levels := map[string]string{}
	if seen.exists {
		levels = codexProjectTrust(document)
	}
	if level, ok := levels[dir]; ok {
		result.Status = map[bool]string{true: CodexTrustTrusted, false: CodexTrustUntrusted}[level == "trusted"]
		return result
	}
	if root := gitRoot(dir); root != "" {
		if levels[root] == "trusted" {
			result.Status = CodexTrustTrusted
			return result
		}
	}
	for parent := filepath.Dir(dir); ; parent = filepath.Dir(parent) {
		if level, ok := levels[parent]; ok {
			if level == "trusted" {
				result.Status, result.Parent = CodexTrustParentOnly, parent
			} else {
				result.Status = CodexTrustUntrusted
			}
			return result
		}
		if parent == filepath.Dir(parent) {
			break
		}
	}
	result.Status = CodexTrustUntrusted
	return result
}

// TrustCodexDirectoryLikeParent appends an exact trusted entry for dir to
// home/config.toml, only when dir is CodexTrustParentOnly: it mirrors the
// trust the user already gave its parent. It returns the parent it mirrored.
// The rest of the file is kept byte for byte.
func TrustCodexDirectoryLikeParent(home, dir string) (string, error) {
	trust := CodexProjectTrust(home, dir)
	if trust.Status != CodexTrustParentOnly {
		return "", errors.New("the directory is not trusted through a parent only (" + trust.Status + "); nothing was written")
	}
	path := filepath.Join(home, "config.toml")
	_, text, seen, err := readCodexMain(path)
	if err != nil || !seen.exists {
		return "", errors.New("config.toml could not be read; nothing was written")
	}
	entry := "\n[projects." + tomlQuote(dir) + "]\ntrust_level = \"trusted\"\n"
	updated := string(text)
	if !strings.HasSuffix(updated, "\n") && updated != "" {
		updated += "\n"
	}
	updated += entry
	if _, err := parseTOML(updated); err != nil {
		return "", errors.New("the trust entry would not parse; nothing was written")
	}
	temporary, err := os.CreateTemp(home, ".config.toml.relay-trust-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(temporary.Name())
	if err := temporary.Chmod(seen.info.Mode().Perm()); err != nil {
		temporary.Close()
		return "", err
	}
	if _, err := temporary.WriteString(updated); err != nil {
		temporary.Close()
		return "", err
	}
	if err := temporary.Close(); err != nil {
		return "", err
	}
	// The file must not have changed since it was read.
	if again, err := os.ReadFile(path); err != nil || string(again) != string(text) {
		return "", errors.New("config.toml changed while Relay prepared the entry; nothing was written")
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return "", err
	}
	return trust.Parent, nil
}
