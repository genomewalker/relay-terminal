//go:build linux

package daemon

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

func nodeBootID() (string, error) {
	data, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func processStartTime(pid int) (uint64, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	// The second field is parenthesized and may contain spaces. Field 22 is
	// therefore parsed relative to the final ')' rather than with Fields alone.
	closing := strings.LastIndexByte(string(data), ')')
	if closing < 0 || closing+2 >= len(data) {
		return 0, fmt.Errorf("invalid /proc/%d/stat", pid)
	}
	fields := strings.Fields(string(data[closing+2:]))
	if len(fields) <= 19 {
		return 0, fmt.Errorf("short /proc/%d/stat", pid)
	}
	return strconv.ParseUint(fields[19], 10, 64)
}

func processWorkingDirectory(pid int) (string, error) {
	return os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
}
