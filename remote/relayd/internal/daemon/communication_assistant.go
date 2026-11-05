package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The Relay assistant ("Miko") is not a pane. It sends through this daemon's
// ordinary message system as its own principal, submitted by the host owner
// (the Relay app reaches this daemon over its owner-authenticated host
// channel). Any process running as this user can submit the same owner
// request, and a key pinned on first use cannot prove otherwise, so relayd
// makes no claim that the Relay app or a user's Run approval sent it: the
// provenance is relay_assistant_owner_submitted, never kernel_verified,
// source_host_attested or an app/Run attestation. The Run decision is recorded
// by the Relay app itself. The reserved caller ID is refused by generic caller
// registration and import, and messages travel only over a pair saved on
// this host.
const (
	communicationAssistantCallerID    = "a5515700-0000-4000-8000-00000000a551"
	communicationAssistantInboxID     = "a5515700-0000-4000-8000-00000000b0c5"
	communicationAssistantAuth        = "relay_assistant_owner_submitted"
	communicationAssistantPrincipal   = "relay-assistant"
	communicationAssistantDisplayName = "Miko (Relay assistant)"
)

// A cross-host pair (the user's pane on another host and a recipient here),
// saved on this host by its owner when the user links them in Relay.
type communicationAssistantLink struct {
	Version    int       `json:"version"`
	HerePaneID string    `json:"here_pane_id"`
	HereHost   string    `json:"here_host"`
	PaneID     string    `json:"pane_id"`
	Provider   string    `json:"provider,omitempty"`
	SessionID  string    `json:"session_id,omitempty"`
	SavedAt    time.Time `json:"saved_at"`
}

// The approved recipient incarnation, kept per outstanding message.
type communicationAssistantBinding struct {
	MessageID string `json:"message_id"`
	Provider  string `json:"provider"`
	SessionID string `json:"session_id"`
	PID       int    `json:"pid"`
	Start     string `json:"start"`
}

type communicationAssistantOutstanding struct {
	Version  int                             `json:"version"`
	PaneID   string                          `json:"pane_id"`
	Messages []communicationAssistantBinding `json:"messages"`
}

type communicationAssistantInboxRecord struct {
	Version    int       `json:"version"`
	MessageID  string    `json:"message_id"`
	FromPaneID string    `json:"from_pane_id"`
	SessionID  string    `json:"session_id,omitempty"`
	Provider   string    `json:"provider,omitempty"`
	ReadAck    []string  `json:"read_acknowledges,omitempty"`
	Text       string    `json:"text"`
	ReceivedAt time.Time `json:"received_at"`
}

func communicationAssistantOutstandingPath(root, pane string) string {
	return filepath.Join(root, "assistant-outstanding-"+strings.ToLower(pane)+".json")
}

func communicationAssistantOwner(r CommunicationRequest) error {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return errors.New("relay-assistant messages are owner requests; a pane or caller credential cannot send as Miko")
	}
	return nil
}

func communicationAssistantLinkPath(root, here, pane string) string {
	return filepath.Join(root, "assistant-link-"+strings.ToLower(here)+"-"+strings.ToLower(pane)+".json")
}

// communicationAssistantLinkSet saves a cross-host pair on the recipient's
// host. The recipient must be a pane of this daemon with a live endpoint.
func communicationAssistantLinkSet(root, nodeID string, r CommunicationRequest, native communicationGroupNative) (map[string]any, error) {
	if err := communicationAssistantOwner(r); err != nil {
		return nil, err
	}
	here, pane := strings.ToLower(r.SourcePaneID), strings.ToLower(r.PaneID)
	if !validSessionID.MatchString(here) || !validSessionID.MatchString(pane) || here == pane ||
		r.HereHost == "" || len(r.HereHost) > 256 {
		return nil, errors.New("two distinct panes and the user's host are required")
	}
	catalog, err := NewServer().CatalogSnapshot()
	if err != nil {
		return nil, err
	}
	known := false
	for _, entry := range catalog.Panes {
		known = known || strings.EqualFold(entry.PaneID, pane)
	}
	if !known {
		return nil, errors.New("the recipient must be a pane of this host")
	}
	member := native.observe(pane)
	link := communicationAssistantLink{Version: 1, HerePaneID: here, HereHost: r.HereHost, PaneID: pane,
		Provider: member.Provider, SessionID: member.SessionID, SavedAt: time.Now().UTC()}
	if err := communicationAtomic(communicationAssistantLinkPath(root, here, pane), link); err != nil {
		return nil, err
	}
	_ = communicationEvent(root, nodeID, "communication_pair_saved", []map[string]string{
		{"from": "pane:" + here, "to": "pane:" + pane, "kind": "assistant_cross_host_member"}})
	return map[string]any{"status": "linked", "authority": "relayd", "scope": "cross_host", "link_revision": link.SavedAt.Format(time.RFC3339Nano)}, nil
}

// communicationAssistantSend delivers one Miko message to a pane on this node
// through the same claim/receipt/native path as a pane message.
func communicationAssistantSend(root, nodeID string, r CommunicationRequest, native communicationGroupNative) (map[string]any, error) {
	if err := communicationAssistantOwner(r); err != nil {
		return nil, err
	}
	if r.ShepherdReport && (!strings.HasPrefix(r.Text, communicationShepherdPrefix+"\n") || r.ExpectedLinkRevision == "" || len(r.ExpectedLinkRevision) > 128) {
		return nil, errors.New("shepherd report prefix and the Settings-pinned link revision are required")
	}
	r.PaneID, r.SourcePaneID, r.MessageID = strings.ToLower(r.PaneID), strings.ToLower(r.SourcePaneID), strings.ToLower(r.MessageID)
	if !validSessionID.MatchString(r.MessageID) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" ||
		!validSessionID.MatchString(r.PaneID) || !validSessionID.MatchString(r.SourcePaneID) ||
		!validSessionID.MatchString(r.AssistantRequestID) {
		return nil, errors.New("a message UUID, a request ID, the user's pane, a recipient and 1-16384 bytes of text are required")
	}
	encoded, _ := json.Marshal(struct {
		Principal, Target, Message, Text string
	}{communicationAssistantPrincipal, r.PaneID, r.MessageID, r.Text})
	hash := sha256.Sum256(encoded)
	fingerprintOfMessage := hex.EncodeToString(hash[:])
	receiptPath := filepath.Join(root, "message-"+r.MessageID+".json")
	var receipt communicationReceipt
	if err := communicationRead(receiptPath, &receipt); err == nil {
		if receipt.Fingerprint != fingerprintOfMessage {
			return nil, errors.New("message identity conflicts with a previous request")
		}
		return receipt.Result, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	// The existing rule: messages travel only over a saved pair (the user's
	// pane and the recipient), and the pair is always checked on this host:
	// a pair of two panes here, or a cross-host pair saved here.
	target := native.observe(r.PaneID)
	linkAuthority := ""
	linkID, _, err := communicationPair(r.SourcePaneID, r.PaneID)
	if err != nil {
		return nil, err
	}
	var link communicationLink
	var crossHost communicationAssistantLink
	if communicationRead(filepath.Join(root, "link-"+linkID+".json"), &link) == nil {
		for _, saved := range link.Members {
			if saved.PaneID == r.PaneID && saved.SessionID != "" && (saved.SessionID != target.SessionID || saved.Provider != target.Provider) {
				return nil, errors.New("linked conversation changed; review the pair before sending")
			}
		}
		linkAuthority = "relayd_node_pair"
		if r.ShepherdReport && r.ExpectedLinkRevision != link.UpdatedAt.Format(time.RFC3339Nano) {
			return nil, errors.New("shepherd link changed; register the report pane again in Settings")
		}
	} else if communicationRead(communicationAssistantLinkPath(root, r.SourcePaneID, r.PaneID), &crossHost) == nil {
		if crossHost.SessionID != "" && (crossHost.SessionID != target.SessionID || crossHost.Provider != target.Provider) {
			return nil, errors.New("linked conversation changed; review the pair before sending")
		}
		linkAuthority = "relayd_cross_host_pair"
		if r.ShepherdReport && r.ExpectedLinkRevision != crossHost.SavedAt.Format(time.RFC3339Nano) {
			return nil, errors.New("shepherd link changed; register the report pane again in Settings")
		}
	} else {
		return nil, errors.New("needs_link: save the pair between the user's pane and the recipient before Miko can message it")
	}
	if target.Endpoint == nil || target.Unavailable != "" {
		return nil, communicationUnverifiedEndpoint("the target pane has no verified native communication endpoint", communicationMember{}, target)
	}
	// The recipient must be exactly the conversation, process and endpoint shown on the card.
	for _, key := range []string{"provider", "sessionID", "pid", "start", "socketIdentity", "transport"} {
		if fmt.Sprint(r.ExpectedRecipient[key]) != fmt.Sprint(target.Endpoint[key]) {
			return nil, errors.New("recipient_changed: the recipient's conversation or endpoint changed since the card was shown")
		}
	}
	// No app or Run claim: this host cannot verify either.
	source := map[string]any{"authentication": communicationAssistantAuth, "principal": communicationAssistantPrincipal,
		"name": communicationAssistantDisplayName, "hostID": nodeID, "assistantRequestID": r.AssistantRequestID,
		"replyPaneID": communicationAssistantInboxID}
	if r.ShepherdReport {
		// Option C: an owner/Miko-submitted report, never an app or pane proof.
		source["reportKind"] = "shepherd"
	}
	receipt = communicationReceipt{Version: 1, Fingerprint: fingerprintOfMessage, CreatedAt: time.Now().UTC(), Result: map[string]any{
		"message_id": r.MessageID, "source_principal": communicationAssistantPrincipal, "link_pane_id": r.SourcePaneID,
		"pane_id": r.PaneID, "status": "outcome_unknown", "replay_permitted": false,
		"source_authentication": communicationAssistantAuth, "link_authority": linkAuthority,
		"assistant_request_id": r.AssistantRequestID, "authority": "relayd", "desktop_required": false}}
	// Durable claim before the only native delivery: never replayed.
	if err := communicationAtomic(receiptPath, receipt); err != nil {
		return nil, err
	}
	if err := communicationEvent(root, nodeID, "message_claimed", []map[string]string{
		{"from": "principal:" + communicationAssistantPrincipal, "to": "message:" + r.MessageID, "kind": "submitted"},
		{"from": "message:" + r.MessageID, "to": "pane:" + r.PaneID, "kind": "addressed_to"}}); err != nil {
		return receipt.Result, err
	}
	// Admit one reply route from exactly this recipient incarnation.
	var outstanding communicationAssistantOutstanding
	_ = communicationRead(communicationAssistantOutstandingPath(root, r.PaneID), &outstanding)
	outstanding.Version, outstanding.PaneID = 1, r.PaneID
	outstanding.Messages = append(outstanding.Messages, communicationAssistantBinding{MessageID: r.MessageID,
		Provider: target.Provider, SessionID: target.SessionID, PID: target.PID, Start: target.Start})
	if len(outstanding.Messages) > 32 {
		outstanding.Messages = outstanding.Messages[len(outstanding.Messages)-32:]
	}
	if err := communicationAtomic(communicationAssistantOutstandingPath(root, r.PaneID), outstanding); err != nil {
		return receipt.Result, err
	}
	result, sendErr := native.send(r.PaneID, map[string]any{"operation": "send", "expected": target.Endpoint,
		"messageID": r.MessageID, "targetPaneID": r.PaneID, "text": r.Text, "submittingClientID": communicationAssistantPrincipal,
		"source": source})
	for key, value := range communicationNativeOutcome(result, sendErr) {
		receipt.Result[key] = value
	}
	if err := communicationAtomic(receiptPath, receipt); err != nil {
		return nil, err
	}
	if err := communicationEvent(root, nodeID, "message_outcome", []map[string]string{
		{"from": "message:" + r.MessageID, "to": fmt.Sprint(receipt.Result["status"]), "kind": "status"}}); err != nil {
		return receipt.Result, err
	}
	return receipt.Result, nil
}

// communicationAssistantReadReceipts returns the IDs named on exact
// "Relay-Read-Receipt: <id>" lines. Mentions and quotes are reply content.
func communicationAssistantReadReceipts(text string) []string {
	ids := []string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if !strings.HasPrefix(line, "Relay-Read-Receipt: ") {
			continue
		}
		id := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(line, "Relay-Read-Receipt: ")))
		if validSessionID.MatchString(id) {
			ids = append(ids, id)
		}
	}
	return ids
}

// communicationAssistantReply stores a kernel-verified pane's reply to Miko.
// Only the exact recipient incarnation Miko messaged may reply, and only its
// own messages can be acknowledged as read.
func communicationAssistantReply(root, nodeID string, r CommunicationRequest, identity string, native communicationGroupNative) (map[string]any, error) {
	if !communicationSourceVerified(r) {
		return nil, errors.New("replies to the Relay assistant require a kernel-verified sending pane")
	}
	r.SourcePaneID, r.MessageID = strings.ToLower(r.SourcePaneID), strings.ToLower(r.MessageID)
	if !validSessionID.MatchString(r.MessageID) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" {
		return nil, errors.New("a message UUID and 1-16384 bytes of text are required")
	}
	var outstanding communicationAssistantOutstanding
	if err := communicationRead(communicationAssistantOutstandingPath(root, r.SourcePaneID), &outstanding); err != nil || len(outstanding.Messages) == 0 {
		return nil, errors.New("the Relay assistant has not messaged this pane; there is nothing to reply to")
	}
	sender := native.observe(r.SourcePaneID)
	owned := map[string]bool{}
	for _, binding := range outstanding.Messages {
		if binding.Provider == sender.Provider && binding.SessionID == sender.SessionID &&
			binding.PID == sender.PID && binding.Start == sender.Start && sender.SessionID != "" {
			owned[binding.MessageID] = true
		}
	}
	if len(owned) == 0 {
		return nil, errors.New("this conversation is not the one the Relay assistant messaged; the reply was not accepted")
	}
	receiptPath := filepath.Join(root, "message-"+r.MessageID+".json")
	encoded, _ := json.Marshal(struct{ Source, Target, Message, Text string }{r.SourcePaneID, communicationAssistantInboxID, r.MessageID, r.Text})
	hash := sha256.Sum256(encoded)
	fingerprint := hex.EncodeToString(hash[:])
	var prior communicationReceipt
	if err := communicationRead(receiptPath, &prior); err == nil {
		if prior.Fingerprint != fingerprint {
			return nil, errors.New("message identity conflicts with a previous request")
		}
		return prior.Result, nil
	}
	record := communicationAssistantInboxRecord{Version: 1, MessageID: r.MessageID, FromPaneID: r.SourcePaneID,
		SessionID: sender.SessionID, Provider: sender.Provider, Text: r.Text, ReceivedAt: time.Now().UTC()}
	for _, id := range communicationAssistantReadReceipts(r.Text) {
		if owned[id] {
			record.ReadAck = append(record.ReadAck, id)
		}
	}
	if err := communicationAtomic(filepath.Join(root, "assistant-inbox-"+r.MessageID+".json"), record); err != nil {
		return nil, err
	}
	for _, id := range record.ReadAck {
		var original communicationReceipt
		path := filepath.Join(root, "message-"+id+".json")
		if communicationRead(path, &original) == nil {
			original.Result["read_acknowledged"] = true
			original.Result["read_acknowledged_by"] = r.MessageID
			_ = communicationAtomic(path, original)
		}
	}
	result := map[string]any{"message_id": r.MessageID, "source_pane_id": r.SourcePaneID, "pane_id": communicationAssistantInboxID,
		"status": "delivered_to_relay_assistant_inbox", "source_authentication": "kernel_verified",
		"submitting_client_id": identity, "replay_permitted": false, "authority": "relayd", "read_acknowledges": record.ReadAck}
	if err := communicationAtomic(receiptPath, communicationReceipt{Version: 1, Fingerprint: fingerprint, CreatedAt: time.Now().UTC(), Result: result}); err != nil {
		return nil, err
	}
	_ = communicationEvent(root, nodeID, "assistant_reply_received", []map[string]string{
		{"from": "pane:" + r.SourcePaneID, "to": "principal:" + communicationAssistantPrincipal, "kind": "reply"}})
	return result, nil
}

// communicationAssistantInbox lists replies to Miko for the host owner.
func communicationAssistantInbox(root string, r CommunicationRequest) (map[string]any, error) {
	if err := communicationAssistantOwner(r); err != nil {
		return nil, err
	}
	paths, err := filepath.Glob(filepath.Join(root, "assistant-inbox-*.json"))
	if err != nil {
		return nil, err
	}
	records := []communicationAssistantInboxRecord{}
	for _, path := range paths {
		var record communicationAssistantInboxRecord
		if communicationRead(path, &record) == nil {
			records = append(records, record)
		}
	}
	sort.Slice(records, func(i, j int) bool { return records[i].ReceivedAt.After(records[j].ReceivedAt) })
	if len(records) > 50 {
		records = records[:50]
	}
	return map[string]any{"replies": records, "trust": "untrusted_collaborator_input", "authority": "relayd"}, nil
}
