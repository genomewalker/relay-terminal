//go:build darwin

package daemon

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// ancestorIsClaude recognises a Claude process by the same identity the agent
// process scan uses: the kernel's command name, its argv when the command is an
// interpreter, and for a version-named native install, the executable it runs.
// Environment is never consulted here. An interpreter whose argv cannot be read
// is an error, not a skip.
func ancestorIsClaude(pid int) (bool, error) {
	if pid <= 1 {
		return false, nil
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info == nil || int(info.Proc.P_pid) != pid {
		return false, nil
	}
	command := darwinAgentCommand(info.Proc.P_comm[:])
	claude, err := ancestorClaudeFromArgv(command, func() (string, error) { return darwinHarnessArguments(pid) })
	if claude || err != nil {
		return claude, err
	}
	if len(command) == 0 || command[0] < '0' || command[0] > '9' {
		return false, nil
	}
	executable, err := darwinKernelExecutable(pid)
	if err != nil {
		executable, err = darwinExecPath(pid)
	}
	home, homeErr := os.UserHomeDir()
	return err == nil && homeErr == nil && classifyDarwinAgentExecutable(command, executable, home) == "claude", nil
}

// ancestorAgentKind names the agent a process is ("claude", "codex", ...), or ""
// for a process that is not an agent. An unreadable process or interpreter is an
// error, so a caller can refuse rather than assume.
func ancestorAgentKind(pid int) (string, error) {
	claude, err := ancestorIsClaude(pid)
	if err != nil {
		return "", err
	}
	if claude {
		return "claude", nil
	}
	if pid <= 1 {
		return "", nil
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info == nil || int(info.Proc.P_pid) != pid {
		return "", errors.New("process unreadable")
	}
	command := darwinAgentCommand(info.Proc.P_comm[:])
	if kind := classifyAgentProcess(command, ""); kind != "" {
		return kind, nil
	}
	if !harnessInterpreter(command) {
		return "", nil
	}
	args, err := darwinHarnessArguments(pid)
	if err != nil {
		return "", err
	}
	return classifyAgentProcess(command, args), nil
}
