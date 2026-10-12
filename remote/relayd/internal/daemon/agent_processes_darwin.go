//go:build darwin

package daemon

import (
	"bytes"
	"errors"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"unsafe"
)

func descendantAgentProcesses(rootPID int) map[int]string {
	result := make(map[int]string)
	rootStart, err := processStartTime(rootPID)
	if err != nil {
		return result
	}
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.uid", os.Getuid())
	if err != nil || len(processes) > 16384 {
		return result
	}
	byPID := make(map[int]unix.KinfoProc, len(processes))
	for _, info := range processes {
		byPID[int(info.Proc.P_pid)] = info
	}
	for pid, info := range byPID {
		command := darwinAgentCommand(info.Proc.P_comm[:])
		agent := classifyAgentProcess(command, "")
		// Native Claude installs a version-named binary behind ~/.local/bin/claude.
		if agent == "" && len(command) > 0 && command[0] >= '0' && command[0] <= '9' {
			executable, err := darwinKernelExecutable(pid)
			home, homeErr := os.UserHomeDir()
			if err == nil && homeErr == nil {
				agent = classifyDarwinAgentExecutable(command, executable, home)
			}

		}
		current := pid
		seen := map[int]bool{}
		chain := []int{}
		belongs := false
		for current > 1 && len(chain) < 64 {
			if seen[current] {
				break
			}
			seen[current] = true
			member, ok := byPID[current]
			if !ok {
				break
			}
			chain = append(chain, current)
			if current == rootPID {
				belongs = true
				break
			}
			current = int(member.Eproc.Ppid)
		}
		if !belongs {
			continue
		}
		if agent == "" && harnessInterpreter(command) {
			if arguments, err := darwinHarnessArguments(pid); err == nil {
				agent = classifyAgentProcess(command, arguments)
			}
		}
		if agent == "" {
			continue
		}
		// Recheck every sampled incarnation. A recycled parent never joins a pane.
		stable := true
		for _, memberPID := range chain {
			before := byPID[memberPID].Proc.P_starttime
			after, e := darwinProcessInfo(memberPID)
			if e != nil || after.Proc.P_starttime != before {
				stable = false
				break
			}
		}
		if stable {
			result[pid] = agent
		}
	}
	after, err := processStartTime(rootPID)
	if err != nil || after != rootStart {
		return map[int]string{}
	}
	return result
}

func descendantAgentProcess(rootPID int) (string, int) {
	processes := descendantAgentProcesses(rootPID)
	pids := make([]int, 0, len(processes))
	for pid := range processes {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	if len(pids) == 0 {
		return "", 0
	}
	// Only a unique top-level provider may own the native conversation.
	roots := []int{}
	for _, pid := range pids {
		nested := false
		info, err := darwinProcessInfo(pid)
		if err != nil {
			continue
		}
		for parent, depth := int(info.Eproc.Ppid), 0; parent > 1 && depth < 64; depth++ {
			if _, ok := processes[parent]; ok {
				nested = true
				break
			}
			if parent == rootPID {
				break
			}
			member, e := darwinProcessInfo(parent)
			if e != nil {
				nested = true
				break
			}
			parent = int(member.Eproc.Ppid)
		}
		if !nested {
			roots = append(roots, pid)
		}
	}
	if len(roots) != 1 {
		return "", 0
	}
	return processes[roots[0]], roots[0]
}

func darwinAgentCommand(raw []byte) string {
	if end := bytes.IndexByte(raw, 0); end >= 0 {
		raw = raw[:end]
	}
	return string(raw)
}

func classifyDarwinAgentExecutable(command, executable, home string) string {
	if !filepath.IsAbs(executable) || !filepath.IsAbs(home) {
		return ""
	}
	canonicalHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return ""
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	if filepath.Dir(resolved) == filepath.Join(canonicalHome, ".local", "share", "claude", "versions") && filepath.Base(resolved) == command {
		return "claude"
	}
	return ""
}

// Mirrors libproc's proc_pidpath request: PROC_INFO_CALL_PIDINFO=2,
// PROC_PIDPATHINFO=11. The vnode path identifies the running executable even
// after a launcher symlink is updated to a newer version.
func darwinKernelExecutable(pid int) (string, error) {
	if pid <= 1 {
		return "", errors.New("invalid executable process")
	}
	buffer := make([]byte, 4096)
	_, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 11, 0,
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	runtime.KeepAlive(buffer)
	if errno != 0 {
		return "", errno
	}
	end := bytes.IndexByte(buffer, 0)
	if end <= 0 || !filepath.IsAbs(string(buffer[:end])) {
		return "", errors.New("kernel executable path unavailable")
	}
	return string(buffer[:end]), nil
}
