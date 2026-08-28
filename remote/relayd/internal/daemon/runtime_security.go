package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// EnsurePrivateRuntimeDir creates or validates a directory used for sockets,
// locks, logs, and worker endpoints. Shared HPC nodes must never place those
// files directly in /tmp, where another user can reserve or replace their
// names before relayd starts.
func EnsurePrivateRuntimeDir(path string) error {
	if path == "" || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return fmt.Errorf("invalid relay runtime directory %q", path)
	}
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("relay runtime path is not a real directory: %s", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() {
		return fmt.Errorf("relay runtime directory is not owned by uid %d: %s", os.Getuid(), path)
	}
	if info.Mode().Perm() != 0o700 {
		if err := os.Chmod(path, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// OpenPrivateFile refuses symlinks and validates the file after opening. The
// containing directory must already have passed EnsurePrivateRuntimeDir.
func OpenPrivateFile(path string, flags int) (*os.File, error) {
	fd, err := syscall.Open(path, flags|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("could not open private relay file %s", path)
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || !info.Mode().IsRegular() {
		file.Close()
		return nil, fmt.Errorf("unsafe relay runtime file: %s", path)
	}
	if info.Mode().Perm() != 0o600 {
		if err := file.Chmod(0o600); err != nil {
			file.Close()
			return nil, err
		}
	}
	return file, nil
}
