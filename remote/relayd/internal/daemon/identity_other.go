//go:build !linux && !darwin

package daemon

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
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

// processStartIdentity uses the same stable textual identity as native peer
// discovery on non-Linux hosts. A PID alone is not enough to bind an observed
// agent process to a registered messaging peer after PID reuse.
func processStartIdentity(pid int) (string, error) {
	if pid <= 0 {
		return "", fmt.Errorf("invalid PID")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/ps", "-p", fmt.Sprint(pid), "-o", "lstart=")
	command.Env = stableProcessEnvironment(os.Environ())
	data, err := command.Output()
	if err != nil {
		return "", err
	}
	start := strings.TrimSpace(string(data))
	if start == "" {
		return "", fmt.Errorf("process %d has no start time", pid)
	}
	return start, nil
}

func processWorkingDirectory(pid int) (string, error) {
	return "", fmt.Errorf("process working directory lookup is unsupported on this platform")
}
