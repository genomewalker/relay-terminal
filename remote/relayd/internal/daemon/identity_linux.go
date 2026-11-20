//go:build linux

package daemon

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
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

// processStartWallTime combines the kernel process start ticks with the boot
// epoch in /proc/stat. Both quantities are rounded down by the kernel.
func processStartWallTime(start uint64) time.Time {
	data, err := os.ReadFile("/proc/stat")
	if err != nil || start == 0 {
		return time.Time{}
	}
	for _, line := range strings.Split(string(data), "\n") {
		raw, ok := strings.CutPrefix(line, "btime ")
		if !ok {
			continue
		}
		boot, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || boot <= 0 {
			break
		}
		// Linux userspace exposes process start in USER_HZ (100 ticks/second).
		return time.Unix(boot+int64(start/100), int64(start%100)*int64(10*time.Millisecond)).UTC()
	}
	return time.Time{}
}

func processStartIdentity(pid int) (string, error) {
	start, err := processStartTime(pid)
	if err != nil {
		return "", err
	}
	return strconv.FormatUint(start, 10), nil
}

func processWorkingDirectory(pid int) (string, error) {
	return os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
}
