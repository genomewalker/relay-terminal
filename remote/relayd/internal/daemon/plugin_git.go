package daemon

import (
	"errors"
	"path/filepath"
	"sort"
	"strings"
)

// The initial read returns paths, not every patch in a large worktree. Patches
// are fetched explicitly per file. Renames are shown as deletion/addition so a
// rename across the approved-directory boundary cannot reveal the other side.
func pluginGitReview(result *PluginResult, root, path string) error {
	git := func(args ...string) (string, error) {
		return pluginCommand(root, "git", append([]string{"--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false"}, args...)...)
	}
	identity, err := git("rev-parse", "--show-toplevel", "--absolute-git-dir")
	if err != nil {
		return err
	}
	result.Text = "Worktree and Git directory:\n" + identity + "\nTracked changes inside the approved directory. Select a file for its staged and unstaged diff. Renames appear as deletion/addition."
	if path != "" && (filepath.IsAbs(path) || filepath.Clean(path) != path || path == "." || path == ".." || strings.HasPrefix(path, "../") || strings.ContainsRune(path, 0)) {
		return errors.New("use a changed file relative to the approved directory")
	}
	paths := map[string]bool{}
	for _, staged := range []bool{false, true} {
		args := []string{"diff", "--relative", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all"}
		if staged {
			args = append(args, "--cached")
		}
		out, err := git(append(args, "--", ".")...)
		if err != nil {
			return err
		}
		for _, name := range strings.Split(out, "\x00") {
			if name != "" {
				paths[name] = true
			}
		}
	}
	for name := range paths {
		result.Entries = append(result.Entries, name)
	}
	sort.Strings(result.Entries)
	if len(result.Entries) > 500 {
		result.Entries = result.Entries[:500]
		result.Truncated = true
	}
	if path == "" {
		return nil
	}
	if !paths[path] {
		return errors.New("file is no longer changed inside the approved directory; refresh the list")
	}
	for _, staged := range []bool{false, true} {
		args := []string{"diff", "--relative", "--no-renames", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all"}
		label := "Unstaged"
		if staged {
			args = append(args, "--cached")
			label = "Staged"
		}
		patch, err := git(append(args, "--", path)...)
		if err != nil {
			return err
		}
		result.Text += "\n\n" + label + " changes:\n" + patch
	}
	return nil
}
