package main

import (
	"bytes"
	"os"
)

// callerPaneFromAncestors finds RELAY_SESSION in the nearest parent process
// that has one. Codex strips it from its MCP servers' environment, but Codex
// itself and the pane's shell still carry it. The nearest value decides,
// valid or not; the walk is bounded and ends at init or a loop.
func callerPaneFromAncestors(pid int, parent func(int) int, environ func(int) ([]byte, bool)) string {
	seen := map[int]bool{}
	for depth := 0; depth < 16 && pid > 1 && !seen[pid]; depth++ {
		seen[pid] = true
		if env, ok := environ(pid); ok {
			for _, entry := range bytes.Split(env, []byte{0}) {
				if value, found := bytes.CutPrefix(entry, []byte("RELAY_SESSION=")); found {
					return callerPaneFrom(string(value))
				}
			}
		}
		pid = parent(pid)
	}
	return ""
}

// callerPane is this relay-mcp's own pane: RELAY_SESSION when present,
// otherwise the nearest ancestor's.
func callerPane() string {
	if value, present := os.LookupEnv("RELAY_SESSION"); present {
		return callerPaneFrom(value)
	}
	return callerPaneFromAncestors(os.Getppid(), parentPID, processEnviron)
}
