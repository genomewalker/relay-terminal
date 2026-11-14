package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// autoStartLine is the relayd.log line a client writes when it starts the
// supervisor. It names only the relayd subcommand, the client and parent
// processes and the SSH client address: never flags or arguments, which may
// carry tokens.
func autoStartLine(args []string, pid, ppid int, parentName, sshClient, invokedAs string, now time.Time) string {
	command := "(none)"
	if len(args) > 1 {
		command = autoStartClean(args[1], 40)
	}
	source := "local"
	if address, _, _ := strings.Cut(strings.TrimSpace(sshClient), " "); address != "" {
		source = "ssh from " + autoStartClean(address, 64)
	}
	if parentName == "" {
		parentName = "unknown"
	}
	line := fmt.Sprintf("relay: %s supervisor started by `relayd %s` (client pid %d, parent pid %d %s, %s",
		now.UTC().Format(time.RFC3339), command, pid, ppid, autoStartClean(parentName, 40), source)
	if invokedAs != "" {
		line += ", invoked as " + autoStartClean(invokedAs, 40)
	}
	return line + ")"
}

// autoStartClean keeps a short printable value on one log line.
func autoStartClean(value string, limit int) string {
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '?'
		}
		return r
	}, value)
	if len(value) > limit {
		value = value[:limit] + "…"
	}
	return value
}

// parentProcessName is the parent's command name where the system exposes it
// without running another program (Linux /proc), else "".
func parentProcessName(ppid int) string {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(ppid) + "/comm")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}
