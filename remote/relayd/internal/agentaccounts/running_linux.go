//go:build linux

package agentaccounts

import (
	"os"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

func userProcesses() ([]runningProcess, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	uid := uint32(os.Getuid())
	var result []runningProcess
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		info, err := os.Stat("/proc/" + entry.Name())
		if err != nil {
			continue
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uid {
			continue
		}
		comm, err := os.ReadFile("/proc/" + entry.Name() + "/comm")
		if err != nil {
			continue
		}
		result = append(result, runningProcess{pid: pid, name: strings.TrimSpace(string(comm))})
	}
	return result, nil
}

// renameExclusive renames from to to in one step, failing when to exists;
// supported is false on a filesystem without that rename.
func renameExclusive(from, to string) (supported bool, err error) {
	err = unix.Renameat2(unix.AT_FDCWD, from, unix.AT_FDCWD, to, unix.RENAME_NOREPLACE)
	if err == unix.EINVAL || err == unix.ENOSYS || err == unix.ENOTSUP {
		return false, err
	}
	return true, err
}

// renameExchange swaps a and b in one step; supported is false on a file
// system without that rename.
func renameExchange(a, b string) (supported bool, err error) {
	err = unix.Renameat2(unix.AT_FDCWD, a, unix.AT_FDCWD, b, unix.RENAME_EXCHANGE)
	if err == unix.EINVAL || err == unix.ENOSYS || err == unix.ENOTSUP {
		return false, err
	}
	return true, err
}

// openPaths lists the working directory and open files of this user's
// processes by pid, as the kernel names them now (a renamed folder appears
// under its new name). A process that ends while it is read is skipped.
func openPaths() (map[int][]string, error) {
	processes, err := userProcesses()
	if err != nil {
		return nil, err
	}
	result := map[int][]string{}
	for _, process := range processes {
		base := "/proc/" + strconv.Itoa(process.pid)
		if cwd, err := os.Readlink(base + "/cwd"); err == nil {
			result[process.pid] = append(result[process.pid], cwd)
		}
		fds, err := os.ReadDir(base + "/fd")
		if err != nil {
			continue
		}
		for _, fd := range fds {
			if target, err := os.Readlink(base + "/fd/" + fd.Name()); err == nil && strings.HasPrefix(target, "/") {
				result[process.pid] = append(result[process.pid], target)
			}
		}
	}
	return result, nil
}
