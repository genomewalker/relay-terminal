package daemon

import (
	"errors"
	"strings"
)

// Owner administration is reachable by any same-user process that can run the
// relayd helper or reach the daemon socket. This gate is defense in depth, not a
// boundary. An owner operation is refused when its caller is, or descends from,
// an agent process: a pane's agent, a Claude desktop session, or any other
// recognized agent. The Relay application is not an agent, so the owner's own
// requests pass. An agent can still reach owner operations through a non-agent
// process it starts outside its ancestry: a double fork or nohup reparented to
// init, tmux or screen, launchctl or at, or `ssh <host> relayd communication`,
// whose ancestry is sshd. Other same-user programs can act as the owner too.

// communicationAgentAncestor reports the agent kind of one process. A variable so
// tests can name their own agent processes.
var communicationAgentAncestor = ancestorAgentKind

// communicationOwnerOperation reports whether an operation is owner administration.
func communicationOwnerOperation(operation string) bool {
	return strings.HasPrefix(operation, "route_") || operation == "node_trust_set"
}

// CheckCommunicationOwner refuses an owner operation from an agent or from a
// process that cannot be proven not to be one. Non-owner operations pass.
func CheckCommunicationOwner(r CommunicationRequest, callerPID int) error {
	return communicationOwnerGate(r, callerPID)
}

func communicationOwnerGate(r CommunicationRequest, callerPID int) error {
	if !communicationOwnerOperation(r.Operation) {
		return nil
	}
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return errors.New("owner administration required")
	}
	if callerPID <= 1 {
		return errors.New("owner administration refused: the caller is not identifiable")
	}
	start, err := processStartIdentity(callerPID)
	if err != nil {
		return errors.New("owner administration refused: the caller identity is unavailable")
	}
	chain, err := networkAncestors(callerPID, start)
	if err != nil {
		return errors.New("owner administration refused: the caller ancestry is unavailable")
	}
	for _, ancestor := range chain {
		if ancestor <= 1 {
			continue
		}
		kind, err := communicationAgentAncestor(ancestor)
		if err != nil {
			return errors.New("owner administration refused: the caller ancestry is unreadable")
		}
		if kind != "" {
			return errors.New("owner administration is not available to agent processes")
		}
	}
	return nil
}
