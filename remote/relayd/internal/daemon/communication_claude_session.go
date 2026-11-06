package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// ClaudeSessionActor is a Claude Code session outside any Relay pane (the
// Claude desktop app's background session) proven to own a calling process by
// that process's kernel ancestry and the session's own registry record.
type ClaudeSessionActor struct {
	Version      int    `json:"version"`
	SessionID    string `json:"session_id"`
	AccountRoot  string `json:"account_root"`
	PID          int    `json:"pid"`
	ProcessStart string `json:"process_start"`
	ClientPID    int    `json:"client_pid"`
	ClientStart  string `json:"client_start"`
	Source       string `json:"source"`
}

const claudeDesktopSessionSource = "claude_desktop_session_kernel_owner"

// Target is the delivery target naming the same session.
func (a ClaudeSessionActor) Target() nativemsg.ClaudeSessionTarget {
	return nativemsg.ClaudeSessionTarget{AccountRoot: a.AccountRoot, SessionID: a.SessionID}
}

// ReadClaudeSessionActor observes which Claude desktop session owns clientPID.
// The nearest ancestor publishing a Claude registration decides: when that is
// a terminal session, a background job or a Relay proxy, the client is not a
// desktop session's, whatever is further up. A client with no Claude ancestor
// (for example an MCP server the Claude chat app itself started) has no
// session. The caller tries the pane actor first.
func ReadClaudeSessionActor(clientPID int) (ClaudeSessionActor, error) {
	var empty ClaudeSessionActor
	if clientPID <= 1 {
		return empty, errors.New("invalid communication client")
	}
	start, err := processStartIdentity(clientPID)
	if err != nil {
		return empty, err
	}
	chain, err := networkAncestors(clientPID, start)
	if err != nil {
		return empty, err
	}
	fallback, err := defaultAgentConfigRoot("claude")
	if err != nil {
		return empty, err
	}
	for _, pid := range chain {
		if pid == clientPID || pid <= 1 {
			continue
		}
		config, configErr := agentConfigRoot(pid, "claude")
		if configErr != nil {
			config = fallback
		}
		path := filepath.Join(config, "sessions", strconv.Itoa(pid)+".json")
		if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
			continue
		}
		pidStart, err := processStartIdentity(pid)
		if err != nil {
			return empty, err
		}
		record, _, _, err := readNativeClaudeRegistrationEntry(path, pid, pidStart, "interactive", nativemsg.ClaudeDesktopEntrypoint)
		if err != nil {
			return empty, errors.New("the calling process's Claude session is not a Claude desktop session")
		}
		actor := ClaudeSessionActor{Version: 1, SessionID: record.SessionID, AccountRoot: config, PID: pid,
			ProcessStart: pidStart, ClientPID: clientPID, ClientStart: start, Source: claudeDesktopSessionSource}
		if !actor.Target().Valid() {
			return empty, errors.New("Claude desktop session account directory is invalid")
		}
		if after, err := processStartIdentity(pid); err != nil || after != pidStart {
			return empty, errors.New("Claude desktop session changed during observation")
		}
		if after, err := processStartIdentity(clientPID); err != nil || after != start {
			return empty, fmt.Errorf("communication client changed during observation")
		}
		return actor, nil
	}
	return empty, errors.New("no Claude desktop session owns this client")
}
