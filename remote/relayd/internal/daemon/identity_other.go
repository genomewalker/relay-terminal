//go:build !linux

package daemon

import (
	"fmt"
	"os"
	"syscall"
)

// relayd workers are currently deployed to Linux HPC nodes. These fallbacks
// keep local development builds portable without pretending to provide Linux's
// strong boot-ID and PID-start-time validation.
func nodeBootID() (string, error) {
	name, err := os.Hostname()
	if err != nil {
		return "", err
	}
	return "non-linux:" + name, nil
}

func processStartTime(pid int) (uint64, error) {
	if err := syscall.Kill(pid, 0); err != nil {
		return 0, err
	}
	return uint64(pid), nil
}

func processWorkingDirectory(pid int) (string, error) {
	return "", fmt.Errorf("process working directory lookup is unsupported on this platform")
}
