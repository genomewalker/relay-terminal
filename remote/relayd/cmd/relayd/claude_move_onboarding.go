package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/daemon"
)

// processDirectory is a seam for tests.
var processDirectory = daemon.ProcessWorkingDirectory

// claudeMoveOnboarding is `relayd claude-move-onboarding SOURCE|- TARGET|-
// PID`: SOURCE and TARGET are account directories as the registry spells
// them ("-" for the main account) and PID is the source agent, whose folder
// is the one the resumed conversation starts in.
func claudeMoveOnboarding(arguments []string) (agentaccounts.MoveOnboarding, error) {
	if len(arguments) != 3 {
		return agentaccounts.MoveOnboarding{}, errors.New("usage: relayd claude-move-onboarding SOURCE|- TARGET|- PID")
	}
	account := func(value string) string {
		if value == "-" {
			return ""
		}
		return value
	}
	pid, err := strconv.Atoi(arguments[2])
	if err != nil || pid <= 1 {
		return agentaccounts.MoveOnboarding{}, errors.New("the agent process is invalid")
	}
	dir, err := processDirectory(pid)
	if err != nil || !filepath.IsAbs(dir) {
		return agentaccounts.MoveOnboarding{}, errors.New("the agent's folder could not be read")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return agentaccounts.MoveOnboarding{}, err
	}
	return agentaccounts.PrepareClaudeMove(home, account(arguments[0]), account(arguments[1]), filepath.Clean(dir))
}
