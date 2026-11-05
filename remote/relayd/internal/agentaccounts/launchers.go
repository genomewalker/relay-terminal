package agentaccounts

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
)

// A managed launcher is the two-line shell script in
// ~/.local/share/relay/shims that makes `claude` or `codex` in a Relay pane
// start through relayd. The same code installs and repairs them on every
// host, This Mac included; only the relayd path differs:
//   - Linux hosts keep relayd at ~/.local/bin/relayd and the launcher names
//     it through $HOME, exactly as the remote installer always wrote it.
//   - macOS runs relayd from inside the app bundle, so the launcher names
//     that executable's resolved path.
//
// Only the two exact names are looked at. A launcher another tool wrote,
// a link, or a file Relay did not write is reported and never touched.
type LauncherStatus struct {
	Provider string `json:"provider"`
	Path     string `json:"path"`
	// State is one of the Launcher* constants.
	State string `json:"state"`
	// Detail says what was found or why nothing was changed.
	Detail string `json:"detail,omitempty"`
	// Mode is the file's permission bits when one exists ("0700").
	Mode string `json:"mode,omitempty"`
}

const (
	// LauncherCurrent: Relay's launcher with the expected content.
	LauncherCurrent = "current"
	// LauncherInstalled / LauncherRepaired: written by this call.
	LauncherInstalled = "installed"
	LauncherRepaired  = "repaired"
	// LauncherMissing / LauncherStale: what a repair would install or fix.
	LauncherMissing = "missing"
	LauncherStale   = "stale"
	// LauncherWrongMode: Relay's launcher with the expected bytes but not
	// owner-executable, or writable by group or others. Repair sets 0700.
	LauncherWrongMode = "wrong_mode"
	// LauncherCustom: Relay's launcher with the user's extra settings
	// argument (install-relay-shell-ui.py). Kept as is.
	LauncherCustom = "custom"
	// LauncherForeign: a file or link Relay did not write. Never changed.
	LauncherForeign = "foreign"
	// LauncherUnavailable: the launcher cannot be installed on this host
	// (no relayd at the expected path, unsafe shims directory).
	LauncherUnavailable = "unavailable"
)

// LauncherProviders are the agents with a managed launcher.
var LauncherProviders = []string{"claude", "codex"}

// LauncherHost is what decides a launcher's content. Tests set every field;
// the daemon uses ThisLauncherHost.
type LauncherHost struct {
	Home string
	GOOS string
	// Relayd is this relayd's executable (its links resolved). Used on macOS.
	Relayd string
}

func ThisLauncherHost() (LauncherHost, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return LauncherHost{}, errors.New("host home unavailable")
	}
	host := LauncherHost{Home: home, GOOS: runtime.GOOS}
	if executable, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(executable); err == nil {
			host.Relayd = resolved
		}
	}
	return host, nil
}

func (h LauncherHost) ShimsDir() string {
	return filepath.Join(h.Home, ".local", "share", "relay", "shims")
}

// linuxRelaydReference names relayd where the remote installer places it.
const linuxRelaydReference = `"$HOME/.local/bin/relayd"`

// target is the relayd reference written into the launcher, or why there
// is none on this host.
func (h LauncherHost) target() (string, string) {
	if h.GOOS != "darwin" {
		info, err := os.Stat(filepath.Join(h.Home, ".local", "bin", "relayd"))
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o100 == 0 {
			return "", "relayd is not installed at ~/.local/bin/relayd on this host"
		}
		return linuxRelaydReference, ""
	}
	if h.Relayd == "" || !filepath.IsAbs(h.Relayd) {
		return "", "this relayd's own path is unavailable"
	}
	return shellWord(h.Relayd), ""
}

// LauncherContent is the exact launcher Relay writes for provider.
func LauncherContent(provider, target string) string {
	return "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=" + provider + "\nexport RELAY_INVOKED_AS\nexec " + target + " \"$@\"\n"
}

var (
	shellSafe = regexp.MustCompile(`^[A-Za-z0-9._/+-]+$`)
	// Relay's launcher with any relayd reference (an unquoted path, a
	// double-quoted "$HOME/..." path or a single-quoted path), optionally
	// with the cc-status settings argument.
	launcherPattern = regexp.MustCompile(`^#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=(claude|codex)\nexport RELAY_INVOKED_AS\nexec ([A-Za-z0-9._/+-]+|"\$HOME/[A-Za-z0-9._/+-]+"|'[^'\n]+') ((--settings "\$HOME/\.config/relay/claude-hooks-status\.json" )?)"\$@"\n$`)
)

func shellWord(path string) string {
	if shellSafe.MatchString(path) {
		return path
	}
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}

// Launchers reports each managed launcher without changing anything.
func Launchers(host LauncherHost) []LauncherStatus {
	return launchers(host, false)
}

// RepairLaunchers installs missing launchers and rewrites stale ones. It
// never changes a custom or foreign file, and never follows a link.
func RepairLaunchers(host LauncherHost) []LauncherStatus {
	return launchers(host, true)
}

func launchers(host LauncherHost, repair bool) []LauncherStatus {
	result := make([]LauncherStatus, 0, len(LauncherProviders))
	directory := host.ShimsDir()
	target, unavailable := host.target()
	if unavailable == "" {
		unavailable = shimsDirectoryProblem(directory, repair)
	}
	for _, provider := range LauncherProviders {
		path := filepath.Join(directory, provider)
		status, observed := inspectLauncher(provider, path, target)
		repairable := status.State == LauncherMissing || status.State == LauncherStale || status.State == LauncherWrongMode
		if unavailable != "" && repairable {
			status.State, status.Detail = LauncherUnavailable, unavailable
			repairable = false
		}
		if repair && repairable {
			if status.State == LauncherWrongMode {
				status = fixLauncherMode(path, status, observed)
			} else {
				status = writeLauncher(provider, path, LauncherContent(provider, target), status, observed)
			}
		}
		result = append(result, status)
	}
	return result
}

// inspectLauncher classifies the file at path and returns the bytes it
// was classified from.
func inspectLauncher(provider, path, target string) (LauncherStatus, []byte) {
	status := LauncherStatus{Provider: provider, Path: path}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		status.State = LauncherMissing
		return status, nil
	}
	if err != nil {
		status.State, status.Detail = LauncherForeign, "the launcher could not be examined"
		return status, nil
	}
	status.Mode = octalMode(info.Mode())
	if !info.Mode().IsRegular() {
		status.State, status.Detail = LauncherForeign, "not a regular file; Relay did not write it"
		return status, nil
	}
	if !ownedByMe(info) {
		status.State, status.Detail = LauncherForeign, "owned by another user"
		return status, nil
	}
	content, err := readSmall(path, 4<<10)
	if err != nil {
		status.State = LauncherForeign
		return status, nil
	}
	match := launcherPattern.FindSubmatch(content)
	switch {
	case match == nil || string(match[1]) != provider:
		status.State = LauncherForeign
	case len(match[3]) > 0:
		status.State, status.Detail = LauncherCustom, "with the cc-status settings"
		if !usableMode(info.Mode()) {
			status.Detail += "; mode " + status.Mode + " is not runnable by its owner alone, left unchanged"
		}
	case target != "" && string(content) == LauncherContent(provider, target) && !usableMode(info.Mode()):
		status.State, status.Detail = LauncherWrongMode, "mode "+status.Mode+"; Relay's launchers are 0700"
	case target != "" && string(content) == LauncherContent(provider, target):
		status.State = LauncherCurrent
	default:
		status.State, status.Detail = LauncherStale, "starts "+string(match[2])
	}
	return status, content
}

// usableMode: the owner can run it and only the owner can change it.
func usableMode(mode os.FileMode) bool {
	return mode.Perm()&0o100 != 0 && mode.Perm()&0o022 == 0
}

// fixLauncherMode sets 0700 on Relay's own launcher through a descriptor
// opened without following links, after checking it is still the same
// owned regular file with the bytes that were classified. The content is
// never rewritten; fchmod changes the mode in one step.
func fixLauncherMode(path string, status LauncherStatus, observed []byte) LauncherStatus {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		status.Detail = "the launcher could not be opened; left unchanged"
		return status
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !ownedByMe(info) {
		status.Detail = "the launcher changed while repairing; left unchanged"
		return status
	}
	content, err := io.ReadAll(io.LimitReader(file, 4<<10+1))
	if err != nil || !bytes.Equal(content, observed) {
		status.Detail = "the launcher changed while repairing; left unchanged"
		return status
	}
	if err := file.Chmod(0o700); err != nil {
		status.Detail = "the launcher's mode could not be set"
		return status
	}
	status.State, status.Mode, status.Detail = LauncherRepaired, "0700", ""
	return status
}

func octalMode(mode os.FileMode) string {
	const digits = "01234567"
	perm := mode.Perm()
	return string([]byte{'0', digits[perm>>6&7], digits[perm>>3&7], digits[perm&7]})
}

func readSmall(path string, limit int64) ([]byte, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(content)) > limit {
		return nil, errors.New("launcher too large")
	}
	return content, nil
}

func ownedByMe(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}

// shimsDirectoryProblem creates the shims directory (0700) when asked and
// refuses one that is a link, someone else's, or writable by others.
func shimsDirectoryProblem(directory string, create bool) string {
	info, err := os.Lstat(directory)
	if errors.Is(err, os.ErrNotExist) {
		if !create {
			return ""
		}
		if err := os.MkdirAll(filepath.Dir(directory), 0o755); err != nil {
			return "the shims directory could not be created"
		}
		if err := os.Mkdir(directory, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return "the shims directory could not be created"
		}
		info, err = os.Lstat(directory)
	}
	switch {
	case err != nil:
		return "the shims directory could not be examined"
	case !info.IsDir():
		return "the shims path is not a directory; nothing was changed"
	case !ownedByMe(info):
		return "the shims directory belongs to another user; nothing was changed"
	case info.Mode().Perm()&0o022 != 0:
		return "the shims directory is writable by other users; nothing was changed"
	}
	return ""
}

// writeLauncher writes content beside path and moves it into place: a
// missing launcher by a link that fails if anything appeared meanwhile, a
// stale one by rename after checking it still holds what was classified.
func writeLauncher(provider, path, content string, status LauncherStatus, observed []byte) LauncherStatus {
	failed := func(detail string) LauncherStatus {
		status.Detail = detail
		return status
	}
	random := make([]byte, 6)
	if _, err := rand.Read(random); err != nil {
		return failed("the launcher could not be written")
	}
	temporary := filepath.Join(filepath.Dir(path), "."+provider+".relay-"+hex.EncodeToString(random))
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o700)
	if err != nil {
		return failed("the launcher could not be written")
	}
	defer os.Remove(temporary)
	_, err = file.WriteString(content)
	if err == nil {
		err = file.Chmod(0o700)
	}
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return failed("the launcher could not be written")
	}
	if status.State == LauncherMissing {
		if err := os.Link(temporary, path); err != nil {
			if errors.Is(err, os.ErrExist) {
				now, _ := inspectLauncher(provider, path, "")
				now.Detail = "another launcher appeared while installing; left unchanged"
				return now
			}
			if err := createExclusive(path, content); err != nil {
				return failed("the launcher could not be installed")
			}
		}
		status.State = LauncherInstalled
	} else {
		current, err := readSmall(path, 4<<10)
		if err != nil || !bytes.Equal(current, observed) {
			return failed("the launcher changed while repairing; left unchanged")
		}
		if err := os.Rename(temporary, path); err != nil {
			return failed("the launcher could not be replaced")
		}
		status.State = LauncherRepaired
	}
	syncDirectory(filepath.Dir(path))
	status.Mode, status.Detail = "0700", ""
	return status
}

// createExclusive is the fallback where hard links are unsupported.
func createExclusive(path, content string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o700)
	if err != nil {
		return err
	}
	_, err = file.WriteString(content)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(path)
	}
	return err
}

func syncDirectory(path string) {
	if directory, err := os.Open(path); err == nil {
		_ = directory.Sync()
		directory.Close()
	}
}
