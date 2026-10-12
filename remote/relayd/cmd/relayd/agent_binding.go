package main

import (
	"errors"
	"github.com/relay-terminal/relayd/internal/daemon"
)

func readAgentBindingArgs(args []string, verified, native func(string) (daemon.AgentBindingRecord, error)) (daemon.AgentBindingRecord, error) {
	var empty daemon.AgentBindingRecord
	if len(args) == 1 && args[0] != "--native" {
		return verified(args[0])
	}
	if len(args) == 2 && args[0] == "--native" && args[1] != "" && args[1] != "--native" {
		return native(args[1])
	}
	return empty, errors.New("usage: relayd agent-binding [--native] PANE")
}
