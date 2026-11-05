package daemon

// ProcessWorkingDirectory is pid's current directory as the kernel names it,
// for a process of this user.
func ProcessWorkingDirectory(pid int) (string, error) {
	return processWorkingDirectory(pid)
}
