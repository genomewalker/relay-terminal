//go:build !darwin

package daemon

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ancestorIsClaude recognises a Claude process by its command name and, for an
// interpreter, its arguments: the same classification the agent process scan
// uses. An interpreter whose arguments cannot be read is an error, not a skip.
func ancestorIsClaude(pid int) (bool, error) {
	if pid <= 1 {
		return false, nil
	}
	command, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
	return ancestorClaudeFromArgv(strings.TrimSpace(string(command)), func() (string, error) {
		arguments, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		return string(arguments), err
	})
}
