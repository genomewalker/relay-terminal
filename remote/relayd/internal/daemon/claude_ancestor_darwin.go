//go:build darwin

package daemon

import (
	"os"

	"golang.org/x/sys/unix"
)

// ancestorIsClaude recognises a Claude process by the same identity the agent
// process scan uses: the kernel's command name, and for a version-named native
// install, the executable it runs. Environment is never consulted here.
func ancestorIsClaude(pid int) bool {
	if pid <= 1 {
		return false
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info == nil || int(info.Proc.P_pid) != pid {
		return false
	}
	command := darwinAgentCommand(info.Proc.P_comm[:])
	if classifyAgentProcess(command, "") == "claude" {
		return true
	}
	if len(command) == 0 || command[0] < '0' || command[0] > '9' {
		return false
	}
	executable, err := darwinKernelExecutable(pid)
	if err != nil {
		executable, err = darwinExecPath(pid)
	}
	home, homeErr := os.UserHomeDir()
	return err == nil && homeErr == nil && classifyDarwinAgentExecutable(command, executable, home) == "claude"
}
