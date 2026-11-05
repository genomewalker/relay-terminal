//go:build unix

package agentaccounts

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// isolate runs a provider command in its own process group, so ending the
// command also ends every child that inherited its output. The returned end
// kills what is left of the group; callers defer it, so the group ends on
// every return path, including a leader that exited early while a child kept
// its output open. The group's ID cannot be reused while any member is alive.
func isolate(command *exec.Cmd) (end func()) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	return func() {
		if command.Process == nil {
			return
		}
		group := -command.Process.Pid
		if syscall.Kill(group, syscall.SIGKILL) != nil {
			return
		}
		// Wait briefly until the killed members are gone.
		for deadline := time.Now().Add(waitLimit); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
			if syscall.Kill(group, 0) != nil {
				return
			}
		}
	}
}

// terminateGently makes ending an isolated command SIGTERM its process group
// instead of SIGKILL; exec's WaitDelay and isolate's end remain the SIGKILL
// fallback. Call it after isolate.
func terminateGently(command *exec.Cmd) {
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
	}
}

// sameDevice reports whether a rename between the two paths stays on one
// filesystem.
func sameDevice(a, b string) bool {
	first, firstErr := os.Lstat(a)
	second, secondErr := os.Lstat(b)
	if firstErr != nil || secondErr != nil {
		return false
	}
	x, ok := first.Sys().(*syscall.Stat_t)
	y, ok2 := second.Sys().(*syscall.Stat_t)
	return ok && ok2 && x.Dev == y.Dev
}

// holdOpen opens the folder without close-on-exec and never closes it, so
// the agent this process becomes keeps it open for its lifetime.
func holdOpen(path string) error {
	_, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY, 0)
	return err
}

// lockAccounts takes this host's accounts lock (exclusive; with wait false
// it gives up at once when another relayd holds it). unlock releases it.
func lockAccounts(home string, wait bool) (unlock func(), err error) {
	dir := filepath.Join(home, ".relay")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	fd, err := syscall.Open(filepath.Join(dir, "agent-accounts.lock"), syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, err
	}
	how := syscall.LOCK_EX
	if !wait {
		how |= syscall.LOCK_NB
	}
	for {
		if err = syscall.Flock(fd, how); err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		syscall.Close(fd)
		return nil, err
	}
	return func() { syscall.Close(fd) }, nil
}

// renameOver is rename(2) itself, which replaces an empty folder at to.
func renameOver(from, to string) error { return syscall.Rename(from, to) }

// folderIdentity is a folder's device and inode, which a rename keeps.
func folderIdentity(path string) (dev, inode uint64, ok bool) {
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() {
		return 0, 0, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return uint64(stat.Dev), uint64(stat.Ino), true
}

// rmdirOnly is rmdir(2), which removes only an empty directory.
func rmdirOnly(path string) error { return syscall.Rmdir(path) }
