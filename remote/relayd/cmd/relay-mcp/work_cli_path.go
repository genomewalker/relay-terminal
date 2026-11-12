package main

import (
	"os"
	"path/filepath"
	"runtime"

	"github.com/relay-terminal/relayd/internal/workorigin"
)

// On macOS the Work CLI is the app bundle's relayd. On a remote host the
// installer publishes relayd-work-communication beside relay-mcp-linux-*, so
// it is resolved from this executable's own directory, never HOME or PATH.
func platformWorkCLIPath() string {
	if runtime.GOOS == "darwin" {
		return workorigin.CLIPath
	}
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	return remoteWorkCLI(executable)
}

func remoteWorkCLI(executable string) string {
	return filepath.Join(filepath.Dir(executable), "relayd-work-communication")
}
