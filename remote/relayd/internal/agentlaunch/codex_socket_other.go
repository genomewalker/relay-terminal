//go:build !linux

package agentlaunch

import "errors"

type CodexSocket struct {
	Path             string `json:"path"`
	Device           uint64 `json:"device"`
	Inode            uint64 `json:"inode"`
	Executable       string `json:"executable"`
	WorkingDirectory string `json:"working_directory"`
	SourcePID        int    `json:"source_pid"`
	SourceStart      string `json:"source_start"`
}

func DiscoverCodexSocket(snapshot Snapshot) (CodexSocket, error) {
	return CodexSocket{}, errors.New("Codex process socket discovery is unavailable on this platform")
}
