//go:build linux

package daemon

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func nativeCodexLauncherChild(pid int, processes map[int]string) int {
	before, err := processStartTime(pid)
	if err != nil {
		return 0
	}
	parent := fmt.Sprintf("/proc/%d", pid)
	info, err := os.Stat(parent)
	if err != nil {
		return 0
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return 0
	}
	executable, err := os.Readlink(filepath.Join(parent, "exe"))
	if err != nil {
		return 0
	}
	name := filepath.Base(strings.TrimSuffix(executable, " (deleted)"))
	if name != "node" && name != "nodejs" {
		return 0
	}
	arguments, err := nativeProcRead(filepath.Join(parent, "cmdline"), 16384)
	if err != nil {
		return 0
	}
	parts := bytes.SplitN(arguments, []byte{0}, 3)
	if len(parts) < 2 {
		return 0
	}
	script := filepath.Base(string(parts[1]))
	if script != "codex" && script != "codex.js" {
		return 0
	}
	children, err := nativeProcRead(filepath.Join(parent, "task", strconv.Itoa(pid), "children"), 16384)
	if err != nil {
		return 0
	}
	child, childStart := 0, uint64(0)
	for _, value := range strings.Fields(string(children)) {
		candidate, err := strconv.Atoi(value)
		if err != nil || processes[candidate] != "codex" {
			continue
		}
		beforeChild, err := processStartTime(candidate)
		if err != nil {
			return 0
		}
		childPath := fmt.Sprintf("/proc/%d", candidate)
		exe, err := os.Readlink(filepath.Join(childPath, "exe"))
		if err != nil || filepath.Base(strings.TrimSuffix(exe, " (deleted)")) != "codex" {
			continue
		}
		data, err := nativeProcRead(filepath.Join(childPath, "stat"), 4096)
		if err != nil {
			return 0
		}
		end := strings.LastIndex(string(data), ")")
		if end < 0 {
			return 0
		}
		fields := strings.Fields(string(data)[end+1:])
		if len(fields) < 2 {
			return 0
		}
		parentPID, err := strconv.Atoi(fields[1])
		if err != nil || parentPID != pid {
			return 0
		}
		if child != 0 {
			return 0
		}
		child, childStart = candidate, beforeChild
	}
	if child == 0 {
		return 0
	}
	after, err := processStartTime(pid)
	if err != nil || after != before {
		return 0
	}
	afterChild, err := processStartTime(child)
	if err != nil || afterChild != childStart {
		return 0
	}
	return child
}
