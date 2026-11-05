package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"runtime"
	"strings"
)

// Cross-host pane links from a remote pane are PROPOSALS. The pane proves
// itself with a single-use relayd attestation bound to the operation, the source
// pane, the target pane and the proposal id; the Mac shows a native
// confirmation naming both panes and both hosts and creates the link only on
// Allow. relay_link_panes routes here for a cross-host target on a remote host;
// relay_link_panes with only proposal_id reads the proposal's status.

const linkProposalPrefix = "relay-pane-link-proposal-v1"

// linkProposalInboxID stands in for the target of a status read, which names no
// target pane. It is a reserved id, not a pane.
const linkProposalInboxID = "a5515700-0000-4000-8000-00000000b0c6"

var strictProposalID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

const linkProposalPath = "/api/pane-link-proposals"

// linkProposalRemote reports whether this client is a remote-host client. The
// Mac's own relay-mcp keeps the direct local path.
var linkProposalRemote = func() bool { return runtime.GOOS != "darwin" }

func linkProposalText(op, source, target, id string) string {
	if op == "status" {
		return linkProposalPrefix + "\nstatus\n" + source + "\n" + id
	}
	return linkProposalPrefix + "\npropose\n" + source + "\n" + target + "\n" + id
}

func (s *server) linkProposalExchange(op, actor, target, id string) map[string]any {
	source := strings.ToLower(actor)
	attestTarget := target
	if op == "status" {
		attestTarget = linkProposalInboxID
	}
	packet := map[string]any{"actor_pane_id": source, "source_pane_id": source, "pane_id": attestTarget,
		"message_id": id, "text": linkProposalText(op, source, target, id)}
	if s.callerToken != "" {
		packet["client_token"] = s.callerToken
	}
	attestation, failure := s.sourceAttestation(packet)
	if attestation == "" {
		return toolText("This pane's relayd did not prove the call: "+failure+"; nothing was sent.", true)
	}
	fields := map[string]string{"op": op, "proposal_id": id, "attestation_id": attestation, "source_pane_id": source}
	if op == "propose" {
		fields["target_pane_id"] = target
	}
	body, err := json.Marshal(fields)
	if err != nil {
		return toolText("Request encoding failed; nothing was sent.", true)
	}
	content, err := s.exchange("POST", linkProposalPath, body)
	if err != nil {
		return toolText(fmt.Sprintf("%s (proposal %s). Do not create a new proposal; read the status with relay_link_panes proposal_id=%s, or retry once with the same proposal_id.", err.Error(), id, id), true)
	}
	var reply map[string]any
	if json.Unmarshal([]byte(content), &reply) != nil || reply == nil {
		return toolText(content, false)
	}
	if op == "propose" {
		reply["next"] = "Waiting for the user to Allow or Deny on the Mac. Read the outcome with relay_link_panes proposal_id=" + id + "; the proposal expires to denied."
	}
	out, _ := json.Marshal(reply)
	return toolText(string(out), false)
}

// proposeLink starts or replays a proposal. proposalID is optional so an agent
// can retry safely with the same id.
func (s *server) proposeLink(actor, target, proposalID string) map[string]any {
	target = strings.ToLower(target)
	if actor == "" || !paneID.MatchString(target) {
		return toolText("A cross-host link needs this pane's proven identity and an exact target pane_id; nothing was sent.", true)
	}
	if proposalID == "" {
		id, err := newRequestUUID()
		if err != nil {
			return toolText("Request identity unavailable; nothing was sent.", true)
		}
		proposalID = id
	}
	return s.linkProposalExchange("propose", actor, target, proposalID)
}

func (s *server) linkProposalStatus(proposalID string) map[string]any {
	actor, err := s.communicationActor()
	if err != nil {
		return toolText("This pane could not be proven: "+err.Error(), true)
	}
	return s.linkProposalExchange("status", actor, "", proposalID)
}

// takeProposalID removes and validates the optional proposal_id argument.
func takeProposalID(arguments map[string]json.RawMessage) (string, bool) {
	raw, ok := arguments["proposal_id"]
	if !ok {
		return "", true
	}
	delete(arguments, "proposal_id")
	var id string
	if json.Unmarshal(raw, &id) != nil || !strictProposalID.MatchString(id) {
		return "", false
	}
	return id, true
}
