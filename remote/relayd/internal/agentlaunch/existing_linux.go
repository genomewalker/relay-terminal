//go:build linux

package agentlaunch

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func boundedRead(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(data) > 65536 {
		return nil, errors.New("process metadata exceeds bound")
	}
	return data, nil
}

func startFor(pid int) (string, error) {
	data, err := boundedRead(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return "", err
	}
	end := strings.LastIndexByte(string(data), ')')
	if end < 0 {
		return "", errors.New("invalid process identity")
	}
	fields := strings.Fields(string(data[end+1:]))
	if len(fields) <= 19 {
		return "", errors.New("invalid process identity")
	}
	return fields[19], nil
}

// CaptureExisting retains the currently running process's effective argv, not
// a reconstructed shell command. The exact incarnation is checked twice.
func CaptureExisting(directory, client string, pid int, expectedStart, expectedExecutable string) (string, error) {
	if pid <= 0 || expectedStart == "" {
		return "", errors.New("exact process identity required")
	}
	root := filepath.Join("/proc", strconv.Itoa(pid))
	info, err := os.Stat(root)
	if err != nil {
		return "", errors.New("process unavailable")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
		return "", errors.New("different process owner")
	}
	start, err := startFor(pid)
	if err != nil || start != expectedStart {
		return "", errors.New("process incarnation changed")
	}
	command, err := boundedRead(filepath.Join(root, "cmdline"))
	if err != nil {
		return "", err
	}
	argv := strings.Split(strings.TrimRight(string(command), "\x00"), "\x00")
	if len(argv) == 0 || argv[0] == "" {
		return "", errors.New("process argv unavailable")
	}
	executable, err := os.Readlink(filepath.Join(root, "exe"))
	expectedInfo, expectedError := os.Stat(expectedExecutable)
	actualInfo, actualError := os.Stat(filepath.Join(root, "exe"))
	if err != nil || expectedError != nil || actualError != nil || !os.SameFile(expectedInfo, actualInfo) {
		return "", errors.New("agent executable is unverified")
	}
	cwd, err := os.Readlink(filepath.Join(root, "cwd"))
	if err != nil {
		return "", err
	}
	environment, err := boundedRead(filepath.Join(root, "environ"))
	if err != nil {
		return "", err
	}
	pane := ""
	for _, field := range strings.Split(string(environment), "\x00") {
		if strings.HasPrefix(field, "RELAY_SESSION=") {
			pane = strings.TrimPrefix(field, "RELAY_SESSION=")
		}
	}
	if pane == "" {
		return "", errors.New("process is not a Relay-managed pane")
	}
	again, err := startFor(pid)
	if err != nil || again != expectedStart {
		return "", errors.New("process incarnation changed")
	}
	// Requested argv before the shim is unknowable for an already running
	// process; nil records that absence, while effective argv is exact.
	return save(directory, client, executable, cwd, pane, start, pid, nil, argv[1:])
}
