//go:build darwin

package agentaccounts

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"time"

	"golang.org/x/sys/unix"
)

func userProcesses() ([]runningProcess, error) {
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.uid", os.Getuid())
	if err != nil {
		return nil, err
	}
	result := make([]runningProcess, 0, len(processes))
	for _, process := range processes {
		pid := int(process.Proc.P_pid)
		if pid <= 0 {
			continue
		}
		result = append(result, runningProcess{pid: pid, name: unix.ByteSliceToString(process.Proc.P_comm[:])})
	}
	return result, nil
}

// renameExclusive renames from to to in one step, failing when to exists;
// supported is false on a filesystem without that rename.
func renameExclusive(from, to string) (supported bool, err error) {
	err = unix.RenamexNp(from, to, unix.RENAME_EXCL)
	if err == unix.EINVAL || err == unix.ENOSYS || err == unix.ENOTSUP {
		return false, err
	}
	return true, err
}

// renameExchange swaps a and b in one step; supported is false on a file
// system without that rename.
func renameExchange(a, b string) (supported bool, err error) {
	err = unix.RenamexNp(a, b, unix.RENAME_SWAP)
	if err == unix.EINVAL || err == unix.ENOSYS || err == unix.ENOTSUP {
		return false, err
	}
	return true, err
}

// openPaths lists the working directory and open files of this user's
// processes by pid, as the kernel names them now (a renamed folder appears
// under its new name).
func openPaths() (map[int][]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/usr/sbin/lsof", "-nP", "-w", "-u", strconv.Itoa(os.Getuid()), "-F", "pn")
	defer isolate(command)()
	command.WaitDelay = waitLimit
	output, err := command.Output()
	if ctx.Err() != nil || (err != nil && len(output) == 0) {
		return nil, errors.New("open files could not be listed")
	}
	result := map[int][]string{}
	pid := 0
	scanner := bufio.NewScanner(bytes.NewReader(output))
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case len(line) > 1 && line[0] == 'p':
			if pid, err = strconv.Atoi(line[1:]); err != nil {
				return nil, errors.New("open files could not be listed")
			}
		case len(line) > 1 && line[0] == 'n' && pid > 0:
			result[pid] = append(result[pid], line[1:])
		}
	}
	// lsof always lists this process; without it the listing is incomplete.
	if scanner.Err() != nil || len(result[os.Getpid()]) == 0 {
		return nil, errors.New("open files could not be listed")
	}
	return result, nil
}
