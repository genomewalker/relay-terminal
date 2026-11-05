package agentaccounts

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// ConfiguredExecutableFallback returns the user's current provider CLI when
// RELAY_<NAME>_BIN names a file that no longer exists. Claude's updater
// deletes old versions while a long-running relayd still carries the path it
// started with. Only a missing file falls back: a path that exists but is not
// runnable stays an error. The fallback is ~/.local/bin/<name> resolved to the
// file it links to, and is never Relay's launcher or the running relayd image.
func ConfiguredExecutableFallback(name, configured string) (string, bool) {
	if _, err := os.Stat(configured); !errors.Is(err, fs.ErrNotExist) {
		return "", false
	}
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(home, ".local", "bin", name))
	if err != nil || !filepath.IsAbs(resolved) {
		return "", false
	}
	shims := filepath.Join(home, ".local", "share", "relay", "shims")
	if directory := filepath.Dir(resolved); directory == shims {
		return "", false
	} else if real, err := filepath.EvalSymlinks(shims); err == nil && directory == real {
		return "", false
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", false
	}
	if startupImage == nil || os.SameFile(startupImage, info) {
		return "", false
	}
	return resolved, true
}

// startupImage identifies the running executable as it was when the process
// started. Its pathname can later be unlinked or replaced (an update), while a
// hard link to the same inode stays a way back into relayd; comparing against
// the current pathname would miss that. Without it no fallback is offered.
var startupImage = func() os.FileInfo {
	path, err := os.Executable()
	if err != nil {
		return nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil
	}
	return info
}()
