//go:build !darwin

package daemon

import (
	"os"
	"path/filepath"
	"strconv"
)

// ancestorIsClaude recognises a Claude process by its command name and
// arguments, the same classification the agent process scan uses.
func ancestorIsClaude(pid int) bool {
	if pid <= 1 {
		return false
	}
	command, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
	arguments, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	return classifyAgentProcess(string(command), string(arguments)) == "claude"
}
