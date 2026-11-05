package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"golang.org/x/sys/unix"
)

// The chitta prompt classifier reads this per-session opt-in file. Relay owns
// it: written on bind for Codex panes, removed on release.

var questionClassifierSession = regexp.MustCompile(`^[A-Za-z0-9-]+$`)

// questionClassifierDirs are the real directories between the config home and
// the opt-in file. Every one is opened relative to the descriptor before it, so
// a parent swapped for a symlink after the check cannot redirect the operation.
var questionClassifierDirs = []string{"chitta", "prompt-classifier.d"}

func questionClassifierOptInPath(configHome, sessionID string) (string, error) {
	if !questionClassifierSession.MatchString(sessionID) {
		return "", errors.New("invalid session for classifier opt-in")
	}
	return filepath.Join(configHome, "chitta", "prompt-classifier.d", sessionID), nil
}

// openQuestionClassifierDir returns a descriptor for the opt-in directory,
// opened with O_NOFOLLOW at every level from the config home down. create makes
// missing directories with mode 0700 relative to the pinned parent. A symlink or
// non-directory at any level is refused, and the caller closes the descriptor.
func openQuestionClassifierDir(configHome string, create bool) (int, error) {
	fd, err := unix.Open(configHome, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, fmt.Errorf("classifier opt-in config home unavailable: %w", err)
	}
	for _, name := range questionClassifierDirs {
		if create {
			if err := unix.Mkdirat(fd, name, 0o700); err != nil && !errors.Is(err, unix.EEXIST) {
				unix.Close(fd)
				return -1, err
			}
		}
		next, err := unix.Openat(fd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		unix.Close(fd)
		if err != nil {
			return -1, fmt.Errorf("classifier opt-in path component is not a real directory: %s: %w", name, err)
		}
		fd = next
	}
	return fd, nil
}

// writeQuestionClassifierOptIn writes "on" as the first line, mode 0600. The
// leaf is opened with O_NOFOLLOW and must be a regular file.
func writeQuestionClassifierOptIn(configHome, sessionID string) error {
	path, err := questionClassifierOptInPath(configHome, sessionID)
	if err != nil {
		return err
	}
	dirFD, err := openQuestionClassifierDir(configHome, true)
	if err != nil {
		return err
	}
	defer unix.Close(dirFD)
	fd, err := unix.Openat(dirFD, sessionID, unix.O_WRONLY|unix.O_CREAT|unix.O_TRUNC|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return fmt.Errorf("classifier opt-in refused: %w", err)
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil || stat.Mode&unix.S_IFMT != unix.S_IFREG {
		return errors.New("classifier opt-in target is not a regular file")
	}
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	_, err = file.WriteString("on\n")
	return err
}

// removeQuestionClassifierOptIn is idempotent. It walks the same pinned
// directories as the write, refuses a symlink or a non-regular leaf, and
// unlinks the leaf relative to the pinned directory.
func removeQuestionClassifierOptIn(configHome, sessionID string) error {
	if _, err := questionClassifierOptInPath(configHome, sessionID); err != nil {
		return err
	}
	dirFD, err := openQuestionClassifierDir(configHome, false)
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(dirFD)
	var stat unix.Stat_t
	if err := unix.Fstatat(dirFD, sessionID, &stat, unix.AT_SYMLINK_NOFOLLOW); errors.Is(err, unix.ENOENT) {
		return nil
	} else if err != nil {
		return err
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG {
		return errors.New("classifier opt-in target is not a regular file")
	}
	return unix.Unlinkat(dirFD, sessionID, 0)
}
