package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

func (s *server) communicationActor() (string, error) {
	pane, _, err := s.communicationActorProof()
	return pane, err
}

// communicationActorProof returns the proven caller pane and the proof source.
func (s *server) communicationActorProof() (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication-actor")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", "", fmt.Errorf("native caller pane unavailable: %s", strings.TrimSpace(stderr.String()))
	}
	var actor struct {
		Version     int    `json:"version"`
		PaneID      string `json:"pane_id"`
		ClientPID   int    `json:"client_pid"`
		ClientStart string `json:"client_start"`
		Source      string `json:"source"`
	}
	if stdout.Len() > 8192 || json.Unmarshal(stdout.Bytes(), &actor) != nil || actor.Version != 1 ||
		!paneID.MatchString(actor.PaneID) || actor.ClientPID != os.Getpid() || actor.ClientStart == "" ||
		(actor.Source != "foreground_worker_kernel_ancestry" && actor.Source != "native_parked_job_kernel_owner" && actor.Source != "claude_desktop_session_kernel_owner") {
		return "", "", fmt.Errorf("invalid native caller pane proof")
	}
	return actor.PaneID, actor.Source, nil
}

// noSenderRefusal is the local answer to relay_message_pane with neither a source
// pane nor a registered caller credential. Nothing is sent.
// callerSessionRefusal is the answer to a pane-less send that names a session.
const callerSessionRefusal = "a registered caller cannot address a session; omit target_session_id"

// desktopInboxWithoutDaemon explains the usual cause: Claude desktop's own
// connector (an mcpServers "relay" entry in claude_desktop_config.json, started
// without RELAY_MCP_BACKEND) shares the name of a Code session's daemon-backed
// "relay" server and answers in its place.
const desktopInboxWithoutDaemon = "relay_read_desktop_inbox needs the daemon-backed Relay MCP server that a Claude Code session starts for itself; this Relay server runs without that backend. In a Claude desktop Code session this usually means the \"relay\" entry in Claude desktop's claude_desktop_config.json is answering instead of the session's own \"relay\" server, because both have the same name. Rename that desktop entry (for example to \"relay-desktop\") and restart Claude desktop. Nothing was read."

const noSenderRefusal = "source_pane_id is required: this helper has no registered caller token (RELAY_MCP_CALLER_TOKEN), so the message has no sender. Nothing was sent."

// Only communication is redirected here. UI/editor tools retain their existing
// client transport; none of those tools are advertised as server automation.
func (s *server) daemonCommunication(name string, arguments map[string]json.RawMessage) (any, bool) {
	operations := map[string]string{"relay_link_panes": "link", "relay_unlink_panes": "unlink", "relay_list_pane_links": "list",
		"relay_message_pane": "send", "relay_pane_message_receipt": "receipt",
		"relay_bind_question_thread": "question_bind", "relay_unbind_question_thread": "question_unbind", "relay_read_desktop_inbox": "desktop_inbox_read"}
	operation, ok := operations[name]
	if !ok {
		return nil, false
	}
	// Only this process mints source proofs; a client never supplies one.
	for _, minted := range []string{"source_attestation", "source_signature", "source_proof_error"} {
		if _, supplied := arguments[minted]; supplied {
			return map[string]any{"content": []map[string]any{{"type": "text", "text": "Unexpected daemon communication argument"}}, "isError": true}, true
		}
	}
	// With a desktop transport configured, the node daemon serves only pairs
	// it owns; cross-host pairs and the full link list stay on the desktop path.
	desktopFallback := s.token != ""
	// A remote pane never creates a cross-host link directly. proposal_id alone
	// reads a proposal's status; a cross-host target below becomes a proposal.
	var proposalID string
	if operation == "link" {
		var valid bool
		if proposalID, valid = takeProposalID(arguments); !valid {
			return map[string]any{"content": []map[string]any{{"type": "text", "text": "proposal_id must be a lowercase UUID"}}, "isError": true}, true
		}
		_, hasSource := arguments["source_pane_id"]
		_, hasTarget := arguments["pane_id"]
		if proposalID != "" && !hasSource && !hasTarget && desktopFallback && linkProposalRemote() {
			return s.linkProposalStatus(proposalID), true
		}
		if proposalID != "" && !linkProposalRemote() {
			// Not a remote client: only the Mac's own route serves proposals, by id.
			arguments["proposal_id"], _ = json.Marshal(proposalID)
			return nil, false
		}
	}
	if desktopFallback && operation == "list" {
		return nil, false
	}
	// A named background session is proven by the recipient host's relayd;
	// the desktop route cannot carry it, so such a send never falls back.
	_, targeted := arguments["target_session_id"]
	if targeted && operation != "send" {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": "target_session_id applies only to relay_message_pane"}}, "isError": true}, true
	}
	refuseTargetFallback := map[string]any{"content": []map[string]any{{"type": "text", "text": "target_session_id needs a pair on this host's relayd; the desktop route cannot address a session. Nothing was sent."}}, "isError": true}
	// Question threads live only on the pane's host; the desktop path never serves them.
	questionOperation := strings.HasPrefix(operation, "question_")
	packet := map[string]any{"operation": operation}
	if s.callerToken != "" {
		packet["client_token"] = s.callerToken
	}
	// The pane is proven from kernel ancestry, never from the environment, and
	// relayd re-derives it independently. Harnesses such as Codex scrub
	// RELAY_SESSION from MCP servers, so its absence only means an unowned
	// client keeps the unattributed path instead of failing.
	actor, actorSource, actorErr := s.communicationActorProof()
	// A verified Claude desktop session sends to a pane through its saved link.
	if actorErr == nil && actorSource == desktopSessionSource && operation == "send" {
		return s.desktopSessionSend(actor, arguments, targeted)
	}
	if actorErr == nil && actorSource == desktopSessionSource && name == "relay_read_desktop_inbox" {
		return s.desktopSessionInbox(actor, arguments)
	}
	if name == "relay_read_desktop_inbox" {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": "Only a verified Claude desktop session can read its desktop inbox. Nothing was read."}}, "isError": true}, true
	}
	if actorErr == nil && actorSource == desktopSessionSource && operation == "link" {
		return s.desktopSessionLink(actor, arguments, targeted)
	}
	if _, polled := arguments["request_id"]; polled && operation == "link" {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": "request_id is read only by the verified Claude desktop session that made the request. Nothing was read."}}, "isError": true}, true
	}
	if actorErr != nil {
		actor = ""
		if os.Getenv("RELAY_SESSION") != "" {
			if desktopFallback && !questionOperation {
				if operation == "link" && linkProposalRemote() {
					return map[string]any{"content": []map[string]any{{"type": "text", "text": "A remote pane link needs this pane's proven identity: " + actorErr.Error()}}, "isError": true}, true
				}
				// The desktop refuses an unproven remote sender; say why on its receipt.
				if targeted {
					return refuseTargetFallback, true
				}
				if operation == "send" {
					arguments["source_proof_error"], _ = json.Marshal(proofDiagnostic("communication-actor", actorErr.Error()))
				}
				return nil, false
			}
			return map[string]any{"content": []map[string]any{{"type": "text", "text": actorErr.Error()}}, "isError": true}, true
		}
	} else {
		packet["actor_pane_id"] = actor
	}
	allowed := map[string]bool{"source_pane_id": true, "pane_id": true, "message_id": true, "text": true, "link_id": true,
		"thread_id": true, "realm": true, "ttl": true, "target_session_id": true}
	result := func(text string, failed bool) any {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": failed}
	}
	// A send with no source pane and no pane identity of its own can only come from
	// a registered caller, and only the Relay app can resolve a caller's credential
	// and label. relayd cannot take a pane-less send, so it goes to the desktop
	// route, which also checks the credential; with no credential there is no sender.
	if operation == "send" && actor == "" {
		if _, hasSource := arguments["source_pane_id"]; !hasSource {
			if s.callerToken == "" {
				return result("source_pane_id is required: this helper has no registered caller token. Nothing was sent.", true), true
			}
			if targeted {
				return result(callerSessionRefusal+". Nothing was sent.", true), true
			}
			if !desktopFallback {
				return result("A message from a registered caller needs the Relay desktop route. Nothing was sent.", true), true
			}
			return nil, false
		}
	}
	for key, raw := range arguments {
		if !allowed[key] {
			return result("Unexpected daemon communication argument", true), true
		}
		var value string
		if json.Unmarshal(raw, &value) != nil {
			return result("Communication arguments must be strings", true), true
		}
		packet[key] = value
	}
	// A provider-local MCP client can label only its own pane as sender.
	// Actual recipient/session/socket identity is checked again by relayd.
	if actor != "" && (operation == "send" || operation == "link" || operation == "unlink" || questionOperation) {
		source, _ := packet["source_pane_id"].(string)
		if source != "" && !strings.EqualFold(source, actor) {
			return result("Sender must be this MCP client's own pane", true), true
		}
		packet["source_pane_id"] = actor
	}
	encoded, err := json.Marshal(packet)
	if err != nil || len(encoded) > 65536 {
		return result("Communication request exceeds limit", true), true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if desktopFallback && !questionOperation && daemonDeclinedBeforeWrite(operation, stderr.String()) {
			if targeted {
				return refuseTargetFallback, true
			}
			if operation == "link" && linkProposalRemote() {
				target, _ := packet["pane_id"].(string)
				return s.proposeLink(actor, target, proposalID), true
			}
			// Cross-host pairs are brokered by the desktop. Carry the proven
			// sender so a client that names only the recipient still links,
			// and the scoped bridge sees this pane rather than an empty source.
			if actor != "" {
				arguments["source_pane_id"], _ = json.Marshal(actor)
				if operation == "send" {
					id, attestErr := s.sourceAttestation(packet)
					if id != "" {
						arguments["source_attestation"], _ = json.Marshal(id)
					}
					// The signature lets the receiving host verify the sender
					// itself; the attestation remains for older receivers.
					signature, signErr := s.sourceSignature(packet)
					if signature != "" {
						arguments["source_signature"], _ = json.Marshal(signature)
					}
					if id == "" && signature == "" {
						arguments["source_proof_error"], _ = json.Marshal(proofDiagnostic("attest", attestErr) + "; " + proofDiagnostic("sign", signErr))
					}
				}
			} else if operation == "send" && actorErr != nil {
				arguments["source_proof_error"], _ = json.Marshal(proofDiagnostic("communication-actor", actorErr.Error()))
			}
			return nil, false
		}
		return result(fmt.Sprintf("Daemon communication unavailable: %s", strings.TrimSpace(stderr.String())), true), true
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return result("Invalid daemon communication response", true), true
	}
	if desktopFallback && (operation == "receipt" || operation == "unlink") {
		// Desktop-path messages and links have no record on this node.
		var reply struct {
			Status string `json:"status"`
		}
		if json.Unmarshal(out.Bytes(), &reply) == nil &&
			((operation == "receipt" && reply.Status == "unknown") || (operation == "unlink" && reply.Status == "not_found")) {
			return nil, false
		}
	}
	return result(out.String(), false), true
}

var attestationID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// sourceAttestation asks this node's relayd to record the sender it proves
// from this process's kernel ancestry, bound to this exact message. Only the
// proof ID travels through the desktop; the desktop redeems it on this host.
// Without one the desktop delivers the message as an unverified claim.
func (s *server) sourceAttestation(packet map[string]any) (string, string) {
	attest := map[string]any{"operation": "attest"}
	for _, key := range []string{"client_token", "actor_pane_id", "source_pane_id", "pane_id", "message_id", "text"} {
		if value, ok := packet[key]; ok {
			attest[key] = value
		}
	}
	encoded, err := json.Marshal(attest)
	if err != nil {
		return "", "request encoding failed"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil || out.Len() > 4096 {
		return "", helperFailure(err, stderr.String())
	}
	var reply struct {
		ID string `json:"attestation_id"`
	}
	if json.Unmarshal(out.Bytes(), &reply) != nil || !attestationID.MatchString(reply.ID) {
		return "", "invalid attestation reply"
	}
	return reply.ID, ""
}

func helperFailure(err error, stderr string) string {
	if detail := strings.TrimSpace(stderr); detail != "" {
		return detail
	}
	if err != nil {
		return err.Error()
	}
	return "reply exceeds limit"
}

// proofDiagnostic is bounded, single-line text for the desktop receipt. It
// names the failing step only; it carries no authority.
func proofDiagnostic(step, detail string) string {
	if detail == "" {
		detail = "failed"
	}
	text := strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, step+": "+detail)
	if len(text) > 240 {
		text = text[:240]
	}
	return strings.ToValidUTF8(text, "")
}

var sourceSignatureAlphabet = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// validSourceSignature accepts only a bounded base64url envelope.
func validSourceSignature(value string) bool {
	return len(value) <= 32768 && sourceSignatureAlphabet.MatchString(value)
}

// sourceSignature asks this node's relayd to sign this exact message as the
// pane it proves from this process's kernel ancestry. The receiving host's
// relayd verifies it against pinned host keys; brokers carry it opaque.
func (s *server) sourceSignature(packet map[string]any) (string, string) {
	sign := map[string]any{"operation": "sign"}
	for _, key := range []string{"client_token", "actor_pane_id", "source_pane_id", "pane_id", "message_id", "text"} {
		if value, ok := packet[key]; ok {
			sign[key] = value
		}
	}
	encoded, err := json.Marshal(sign)
	if err != nil {
		return "", "request encoding failed"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil || out.Len() > 64<<10 {
		return "", helperFailure(err, stderr.String())
	}
	var reply struct {
		Signature string `json:"source_signature"`
		Authority string `json:"authority"`
	}
	if json.Unmarshal(out.Bytes(), &reply) != nil || reply.Authority != "relayd" || !validSourceSignature(reply.Signature) {
		return "", "invalid signature reply"
	}
	return reply.Signature, ""
}

// daemonDeclinedBeforeWrite matches only refusals relayd returns before it
// claims a receipt or saves a link, so the desktop path cannot duplicate a send.
func daemonDeclinedBeforeWrite(operation, stderr string) bool {
	switch operation {
	case "link":
		return strings.Contains(stderr, "both panes must belong to this daemon")
	case "send":
		return strings.Contains(stderr, "save the communication pair on this daemon before sending")
	}
	return false
}

// desktopLinkShadowHint is appended when a server without the daemon backend
// forwards a recipient-only link to the app. A Code session's own server would
// infer the sender; here the app answers with an unrelated pair error.
const desktopLinkShadowHint = " If this came from a Claude desktop Code session: a recipient-only link needs the daemon-backed Relay MCP server the session starts for itself. Claude desktop's \"relay\" entry in claude_desktop_config.json is probably answering in its place; rename that entry (for example to \"relay-desktop\") and restart Claude desktop."

// linkPanesError leaves the app's error unchanged except for a recipient-only
// link on a server without the daemon backend. The no-ID and two-ID forms are
// valid desktop uses and keep the app's own error.
func linkPanesError(message string, arguments map[string]json.RawMessage, daemonBacked bool) string {
	_, pane := arguments["pane_id"]
	_, source := arguments["source_pane_id"]
	if daemonBacked || !pane || source {
		return message
	}
	return message + desktopLinkShadowHint
}
