package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// Both owners explicitly review the pair and the reciprocal link revision.
// AllowedPeerCallers attributes credentials on that peer daemon, not authorship.
type CommunicationRemoteLink struct {
	Version               int                             `json:"version"`
	ID                    string                          `json:"id"`
	NodeID                string                          `json:"node_id"`
	PeerNodeID            string                          `json:"peer_node_id"`
	LocalPaneID           string                          `json:"local_pane_id"`
	PeerPaneID            string                          `json:"peer_pane_id"`
	RouteID               string                          `json:"route_id"`
	RouteRevision         uint64                          `json:"route_revision"`
	PeerCertificateSHA256 string                          `json:"peer_certificate_sha256"`
	LocalConversation     communicationPinnedConversation `json:"local_conversation"`
	PeerConversation      communicationPinnedConversation `json:"peer_conversation"`
	AllowedPeerCallers    []string                        `json:"allowed_peer_callers"`
	// DesktopAccountRoot is the Claude account a desktop session was approved in.
	// Empty for pane links. Replies are refused when the session registers elsewhere.
	DesktopAccountRoot string    `json:"desktop_account_root,omitempty"`
	PeerRevision       uint64    `json:"peer_revision"`
	Revision           uint64    `json:"revision"`
	Retired            bool      `json:"retired"`
	CreatedAt          time.Time `json:"created_at"`
	UpdatedAt          time.Time `json:"updated_at"`
	// LocalPID and LocalStart pin the local member's process, learned from
	// kernel observation on the first use that matches LocalConversation. A
	// conversation change in that same process (/clear) is followed.
	LocalPID   int    `json:"local_pid,omitempty"`
	LocalStart string `json:"local_start,omitempty"`
	// LocalRootPID and LocalRootStart pin the local pane's root process (its
	// worker and shell incarnation): an agent restarted under it is followed.
	LocalRootPID   int    `json:"local_root_pid,omitempty"`
	LocalRootStart string `json:"local_root_start,omitempty"`
	// LocalAccount is the local agent account directory at the last use; a
	// restart under the pane root is followed only within it.
	LocalAccount string `json:"local_account,omitempty"`
	// LocalFollowedFrom lists earlier conversations of the local member in the
	// pinned process that the peer may still name, oldest first. It is sent to
	// the peer with each message and cleared once the peer names the current one.
	LocalFollowedFrom []communicationPinnedConversation `json:"local_followed_from,omitempty"`
	// PeerFollowedFrom lists earlier peer conversations this host followed,
	// oldest first, so a message the peer sent before its change (for example
	// one the carrier delivers late) is still accepted. Bounded like the above.
	PeerFollowedFrom []communicationPinnedConversation `json:"peer_followed_from,omitempty"`
}

type communicationRemoteMessage struct {
	Version            int                             `json:"version"`
	Operation          string                          `json:"operation"`
	LinkID             string                          `json:"link_id"`
	SourceLinkRevision uint64                          `json:"source_link_revision"`
	TargetLinkRevision uint64                          `json:"target_link_revision"`
	SourceNodeID       string                          `json:"source_node_id"`
	TargetNodeID       string                          `json:"target_node_id"`
	SourcePaneID       string                          `json:"source_pane_id"`
	TargetPaneID       string                          `json:"target_pane_id"`
	CallerID           string                          `json:"caller_id"`
	SourceConversation communicationPinnedConversation `json:"source_conversation"`
	TargetConversation communicationPinnedConversation `json:"target_conversation"`
	MessageID          string                          `json:"message_id"`
	Fingerprint        string                          `json:"fingerprint"`
	Text               string                          `json:"text,omitempty"`
	// SourceFollowedFrom is the sender's LocalFollowedFrom: earlier conversations
	// of the sending pane in the same process. Covered by the fingerprint.
	SourceFollowedFrom []communicationPinnedConversation `json:"source_followed_from,omitempty"`
	// SourceSignature is the sender's session-signed statement for this
	// message, issued by the sending node's relayd. It is outside the
	// fingerprint, so older peers ignore it and deliver a claimed label.
	SourceSignature string `json:"source_signature,omitempty"`
}
type communicationRemoteReceipt struct {
	Version      int            `json:"version"`
	NodeID       string         `json:"node_id"`
	PeerNodeID   string         `json:"peer_node_id"`
	LinkID       string         `json:"link_id"`
	SourcePaneID string         `json:"source_pane_id"`
	TargetPaneID string         `json:"target_pane_id"`
	CallerID     string         `json:"caller_id"`
	MessageID    string         `json:"message_id"`
	Fingerprint  string         `json:"fingerprint"`
	CreatedAt    time.Time      `json:"created_at"`
	Result       map[string]any `json:"result"`
}

func remotePairID(node, pane, peer, peerPane string) string {
	ends := []string{node + ":" + pane, peer + ":" + peerPane}
	sort.Strings(ends)
	hash := sha256.Sum256([]byte(strings.Join(ends, "\n")))
	return hex.EncodeToString(hash[:])
}
func remoteDigest(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == strings.ToLower(value)
}
func validRemoteConversation(pin communicationPinnedConversation) bool {
	return (pin.Provider == "claude" || pin.Provider == "codex") && validSessionID.MatchString(pin.SessionID)
}
func validRemoteLink(link CommunicationRemoteLink, node string) bool {
	if link.Version != 1 || link.NodeID != node || !canonicalRouteToken(node) || !canonicalRouteToken(link.PeerNodeID) || link.PeerNodeID == node ||
		!canonicalRouteToken(link.LocalPaneID) || !canonicalRouteToken(link.PeerPaneID) || !canonicalRouteToken(link.RouteID) || link.RouteRevision == 0 ||
		link.ID != remotePairID(node, link.LocalPaneID, link.PeerNodeID, link.PeerPaneID) || !remoteDigest(link.PeerCertificateSHA256) ||
		!validRemoteConversation(link.LocalConversation) || !validRemoteConversation(link.PeerConversation) || link.PeerRevision == 0 || link.Revision == 0 ||
		link.CreatedAt.IsZero() || link.UpdatedAt.Before(link.CreatedAt) || len(link.AllowedPeerCallers) == 0 || len(link.AllowedPeerCallers) > 128 ||
		link.LocalPID < 0 || len(link.LocalStart) > 64 || link.LocalRootPID < 0 || len(link.LocalRootStart) > 64 || len(link.LocalAccount) > 4096 || !validFollowedFrom(link.LocalFollowedFrom, link.LocalConversation) ||
		!validFollowedFrom(link.PeerFollowedFrom, link.PeerConversation) {
		return false
	}
	previous := ""
	for _, caller := range link.AllowedPeerCallers {
		if !canonicalRouteToken(caller) || caller <= previous {
			return false
		}
		previous = caller
	}
	return true
}
func remoteLinkPath(root, id string) string { return filepath.Join(root, "remote-link-"+id+".json") }
func readRemoteLink(root, node, id string) (CommunicationRemoteLink, error) {
	var link CommunicationRemoteLink
	if !remoteDigest(id) {
		return link, errors.New("valid remote pair identity required")
	}
	if err := communicationRead(remoteLinkPath(root, id), &link); err != nil {
		return link, err
	}
	if !validRemoteLink(link, node) || link.ID != id {
		return link, errors.New("invalid stored remote pair")
	}
	return link, nil
}

func communicationRemoteLinkSet(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.RemoteLink == nil {
		return nil, errors.New("reviewed remote pair required")
	}
	err := communicationFanoutLocked(root, func() error { _, err := communicationAuthorize(root, r); return err })
	if err != nil {
		return nil, err
	}
	// Discover native state outside the metadata lock; changed conversation pins
	// cannot be enrolled. The peer pin is reviewed explicitly by the owner.
	local := hooks.observe(strings.ToLower(r.RemoteLink.LocalPaneID))
	if !communicationPinMatches(r.RemoteLink.LocalConversation, local) {
		return nil, errors.New("reviewed local conversation is unavailable or changed")
	}
	var result map[string]any
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		var err error
		result, err = communicationRemoteLinkOperation(root, node, r)
		return err
	})
	return result, err
}

// Owner authorization and the metadata flock precede this reducer.
func communicationRemoteLinkOperation(root, node string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if r.Operation == "route_link_received_receipt" {
		peer, id := strings.ToLower(r.PeerNodeID), strings.ToLower(r.MessageID)
		if !canonicalRouteToken(peer) || !canonicalRouteToken(id) {
			return nil, errors.New("valid received message scope required")
		}
		var receipt communicationRemoteReceipt
		if err := communicationRead(remoteReceiptPath(root, peer, id), &receipt); err != nil {
			return nil, err
		}
		if receipt.Version != 1 || receipt.NodeID != node || receipt.PeerNodeID != peer || receipt.MessageID != id || !remoteDigest(receipt.LinkID) || !remoteDigest(receipt.Fingerprint) || receipt.Result == nil {
			return nil, errors.New("invalid received message receipt")
		}
		return remoteReceiptResult(receipt), nil
	}
	if r.Operation == "route_link_list" {
		paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
		if err != nil {
			return nil, err
		}
		if len(paths) > 256 {
			return nil, errors.New("remote pair catalogue exceeds limit")
		}
		links := []CommunicationRemoteLink{}
		typed := []communicationTypedRemoteLink{}
		for _, path := range paths {
			id := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "remote-link-"), ".json")
			var header struct {
				Version int `json:"version"`
			}
			if err := communicationRead(path, &header); err != nil {
				return nil, err
			}
			switch header.Version {
			case 1:
				link, err := readRemoteLink(root, node, id)
				if err != nil {
					return nil, err
				}
				links = append(links, link)
			case 2:
				link, err := readTypedRemoteLink(root, node, id)
				if err != nil {
					return nil, err
				}
				typed = append(typed, link)
			default:
				return nil, errors.New("unknown remote pair version")
			}
		}
		result := map[string]any{"links": links, "authority": "relayd", "desktop_required": false}
		if len(typed) != 0 {
			result["typed_links"] = typed
		}
		return result, nil
	}
	id := strings.ToLower(r.LinkID)
	var requested CommunicationRemoteLink
	if r.Operation == "route_link_set" {
		if r.RemoteLink == nil {
			return nil, errors.New("reviewed remote pair required")
		}
		requested = *r.RemoteLink
		requested.NodeID, requested.Version = node, 1
		requested.LocalPaneID, requested.PeerPaneID = strings.ToLower(requested.LocalPaneID), strings.ToLower(requested.PeerPaneID)
		requested.PeerNodeID, requested.RouteID = strings.ToLower(requested.PeerNodeID), strings.ToLower(requested.RouteID)
		id = remotePairID(node, requested.LocalPaneID, requested.PeerNodeID, requested.PeerPaneID)
		if r.LinkID != "" && strings.ToLower(r.LinkID) != id {
			return nil, errors.New("remote pair identity mismatch")
		}
		requested.ID = id
		requested.AllowedPeerCallers = append([]string(nil), requested.AllowedPeerCallers...)
		for i, caller := range requested.AllowedPeerCallers {
			requested.AllowedPeerCallers[i] = strings.ToLower(caller)
		}
		sort.Strings(requested.AllowedPeerCallers)
	}
	previous, err := readRemoteLink(root, node, id)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if r.Operation == "route_link_get" {
		if !exists {
			return nil, errors.New("remote pair not found")
		}
		return map[string]any{"link": previous, "authority": "relayd", "desktop_required": false}, nil
	}
	if r.Operation != "route_link_set" && r.Operation != "route_link_retire" {
		return nil, errors.New("unsupported remote pair operation")
	}
	if !exists && r.Operation == "route_link_retire" {
		return nil, errors.New("remote pair not found")
	}
	if r.ExpectedRemoteLinkRevision != previous.Revision || previous.Revision == math.MaxUint64 {
		return nil, errors.New("remote pair revision conflict")
	}
	link := previous
	if r.Operation == "route_link_set" {
		if !exists {
			paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
			if err != nil {
				return nil, err
			}
			if len(paths) >= 256 {
				return nil, errors.New("remote pair limit reached")
			}
		}
		link = requested
		route, _, cert, err := activePeerRoute(root, node, link.RouteID)
		if err != nil {
			return nil, err
		}
		if route.PeerNodeID != link.PeerNodeID || route.Revision != link.RouteRevision || peerFingerprint(cert) != link.PeerCertificateSHA256 {
			return nil, errors.New("reviewed peer route changed")
		}
	}
	now := time.Now().UTC()
	link.Revision, link.UpdatedAt, link.Retired = previous.Revision+1, now, r.Operation == "route_link_retire"
	link.CreatedAt = previous.CreatedAt
	if !exists {
		link.CreatedAt = now
	}
	if !validRemoteLink(link, node) {
		return nil, errors.New("invalid reviewed remote pair")
	}
	if err := communicationAtomic(remoteLinkPath(root, id), link); err != nil {
		return nil, err
	}
	kind := "communication_remote_pair_saved"
	if link.Retired {
		kind = "communication_remote_pair_retired"
	}
	if err := communicationEvent(root, node, kind, []map[string]string{{"link_id": id, "peer_node_id": link.PeerNodeID}}); err != nil {
		return nil, errors.New("remote pair saved but event append failed; read current revision before recovery")
	}
	return map[string]any{"link": link, "authority": "relayd", "desktop_required": false}, nil
}

func remoteMessageFingerprint(message communicationRemoteMessage) string {
	message.Operation = "send"
	message.Fingerprint = ""
	message.SourceSignature = ""
	data, _ := json.Marshal(message)
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}
func validRemoteMessage(message communicationRemoteMessage, node string) bool {
	return canonicalRouteToken(node) && message.Version == 1 && (message.Operation == "send" || message.Operation == "receipt") && message.TargetNodeID == node &&
		canonicalRouteToken(message.SourceNodeID) && message.SourceNodeID != node && canonicalRouteToken(message.SourcePaneID) && canonicalRouteToken(message.TargetPaneID) &&
		canonicalRouteToken(message.CallerID) && canonicalRouteToken(message.MessageID) && remoteDigest(message.Fingerprint) &&
		message.LinkID == remotePairID(node, message.TargetPaneID, message.SourceNodeID, message.SourcePaneID) &&
		message.SourceLinkRevision != 0 && message.TargetLinkRevision != 0 && validRemoteConversation(message.SourceConversation) && validRemoteConversation(message.TargetConversation) &&
		validFollowedFrom(message.SourceFollowedFrom, message.SourceConversation)
}
func remoteReceiptPath(root, peer, id string) string {
	digest := sha256.Sum256([]byte(peer + "\n" + id))
	return filepath.Join(root, "remote-message-"+hex.EncodeToString(digest[:])+".json")
}
func remoteReceiptMatches(receipt communicationRemoteReceipt, message communicationRemoteMessage, node string) bool {
	return receipt.Version == 1 && receipt.NodeID == node && receipt.PeerNodeID == message.SourceNodeID && receipt.LinkID == message.LinkID &&
		receipt.SourcePaneID == message.SourcePaneID && receipt.TargetPaneID == message.TargetPaneID && receipt.CallerID == message.CallerID &&
		receipt.MessageID == message.MessageID && receipt.Fingerprint == message.Fingerprint && receipt.Result != nil && !receipt.CreatedAt.IsZero()
}
func remoteReceiptResult(receipt communicationRemoteReceipt) map[string]any {
	result := communicationNativeOutcome(receipt.Result, nil)
	result["message_id"], result["source_node_id"], result["source_pane_id"] = receipt.MessageID, receipt.PeerNodeID, receipt.SourcePaneID
	result["target_node_id"], result["pane_id"], result["submitting_client_id"] = receipt.NodeID, receipt.TargetPaneID, receipt.CallerID
	result["peer_authentication"], result["source_authentication"] = "mutual_tls_pinned_node", "claimed_pane_label"
	if receipt.Result["source_authentication"] == "source_signed" {
		result["source_authentication"] = "source_signed"
	}
	result["authority"], result["desktop_required"], result["replay_permitted"] = "relayd", false, false
	result["fingerprint"] = receipt.Fingerprint
	return result
}
func authorizeRemoteMessage(root, node, certificateHash string, message communicationRemoteMessage) (CommunicationRemoteLink, error) {
	link, err := readRemoteLink(root, node, message.LinkID)
	if err != nil {
		return link, err
	}
	if link.Retired || link.Revision != message.TargetLinkRevision || link.PeerRevision != message.SourceLinkRevision ||
		link.PeerNodeID != message.SourceNodeID || link.PeerPaneID != message.SourcePaneID || link.LocalPaneID != message.TargetPaneID ||
		!containsCommunicationPane(link.AllowedPeerCallers, message.CallerID) {
		return link, errors.New("remote pair permission or reviewed conversation changed")
	}
	// A receipt query only reads the durable receipt its fingerprint names, so
	// a conversation followed since the message was sent does not block it.
	// A send must name the current conversations, or ones they followed from
	// in the same process (see communication_remote_follow.go).
	if message.Operation == "send" && (!remoteAcceptsTarget(link, message.TargetConversation) || !remoteAcceptsSource(link, message)) {
		return link, errors.New("remote pair permission or reviewed conversation changed")
	}
	route, _, cert, err := activePeerRoute(root, node, link.RouteID)
	if err != nil {
		return link, err
	}
	if route.Revision != link.RouteRevision || route.PeerNodeID != link.PeerNodeID || peerFingerprint(cert) != certificateHash || certificateHash != link.PeerCertificateSHA256 {
		return link, errors.New("remote pair route or certificate changed")
	}
	if message.Operation == "send" {
		if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "remote_receive"}); err != nil {
			return link, err
		}
	}
	return link, nil
}

// A remote node certificate authenticates the daemon channel only. Both owner
// reviews, scoped caller permission and live recipient identity are required.
func communicationReceiveRemote(ctx context.Context, root, node, certificateHash string, message communicationRemoteMessage, hooks communicationGroupNative) (map[string]any, error) {
	if !validRemoteMessage(message, node) {
		return nil, errors.New("invalid remote message scope")
	}
	if message.Operation == "send" && (!utf8.ValidString(message.Text) || len(message.Text) == 0 || len(message.Text) > 16384 || strings.TrimSpace(message.Text) == "" || remoteMessageFingerprint(message) != message.Fingerprint) {
		return nil, errors.New("invalid remote message text or fingerprint")
	}
	if message.Operation == "receipt" && message.Text != "" {
		return nil, errors.New("receipt query cannot include message text")
	}
	path := remoteReceiptPath(root, message.SourceNodeID, message.MessageID)
	var receipt communicationRemoteReceipt
	existing := false
	err := communicationFanoutLocked(root, func() error {
		if _, err := authorizeRemoteMessage(root, node, certificateHash, message); err != nil {
			return err
		}
		if err := communicationRead(path, &receipt); err == nil {
			if !remoteReceiptMatches(receipt, message, node) {
				return errors.New("remote message identity conflict")
			}
			existing = true
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if existing {
		return remoteReceiptResult(receipt), nil
	}
	if message.Operation == "receipt" {
		return remoteReceiptResult(communicationRemoteReceipt{NodeID: node, PeerNodeID: message.SourceNodeID, SourcePaneID: message.SourcePaneID,
			TargetPaneID: message.TargetPaneID, CallerID: message.CallerID, MessageID: message.MessageID, Fingerprint: message.Fingerprint, Result: map[string]any{"status": "unknown"}}), nil
	}
	target := hooks.observe(message.TargetPaneID)
	// A sender signature is verified against this route's own pinned peer: the
	// node that authenticated the channel must be the node that signed.
	source, authentication, signatureError := communicationRemoteSourcePacket(message, certificateHash, time.Now().UTC())
	claimed := false
	err = communicationFanoutLocked(root, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		link, err := authorizeRemoteMessage(root, node, certificateHash, message)
		if err != nil {
			return err
		}
		if err := communicationRead(path, &receipt); err == nil {
			if !remoteReceiptMatches(receipt, message, node) {
				return errors.New("remote message identity conflict")
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		// A recipient pane that ran /clear in the same process keeps the pair;
		// the message also tells this host which conversation the sender is in.
		before := link
		followed, moved, err := remoteLinkFollowLocal(root, link, target)
		if err != nil {
			if err.Error() == communicationLinkRelinkNeeded {
				return err
			}
			return errors.New("reviewed recipient conversation changed or is unavailable")
		}
		var audit []map[string]any
		if moved {
			audit = append(audit, remoteFollowAudit(followed, link))
		}
		followed, learned := remoteLinkLearnFromMessage(followed, message)
		audit = append(audit, learned...)
		link = followed
		if link.DesktopAccountRoot != "" {
			// A desktop session replies only in the account it was approved in.
			endpoint, err := readClaudeSessionEndpoint(root, link.LocalConversation.SessionID)
			if err != nil || endpoint.AccountRoot != link.DesktopAccountRoot {
				return errors.New("desktop session registration changed; reply refused")
			}
		}
		if !communicationPinMatches(link.LocalConversation, target) {
			return errors.New("reviewed recipient conversation changed or is unavailable")
		}
		if !reflect.DeepEqual(before, link) {
			if err := communicationAtomic(remoteLinkPath(root, link.ID), link); err != nil {
				return err
			}
			remoteAppendRepins(root, link.ID, audit...)
		}
		receipt = communicationRemoteReceipt{Version: 1, NodeID: node, PeerNodeID: message.SourceNodeID, LinkID: message.LinkID,
			SourcePaneID: message.SourcePaneID, TargetPaneID: message.TargetPaneID, CallerID: message.CallerID, MessageID: message.MessageID,
			Fingerprint: message.Fingerprint, CreatedAt: time.Now().UTC(), Result: map[string]any{"status": "outcome_unknown", "message_id": message.MessageID,
				"source_node_id": message.SourceNodeID, "source_pane_id": message.SourcePaneID, "target_node_id": node, "pane_id": message.TargetPaneID,
				"submitting_client_id": message.CallerID, "peer_authentication": "mutual_tls_pinned_node", "source_authentication": authentication,
				"authority": "relayd", "desktop_required": false, "replay_permitted": false}}
		if signatureError != "" {
			receipt.Result["source_signature_error"] = signatureError
		}
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "remote_message_claimed", []map[string]string{{"link_id": message.LinkID, "message_id": message.MessageID, "peer_node_id": message.SourceNodeID}}); err != nil {
			return err
		}
		claimed = true
		return nil
	})
	if err != nil {
		if receipt.Result != nil {
			return remoteReceiptResult(receipt), err
		}
		return nil, err
	}
	if !claimed {
		return remoteReceiptResult(receipt), nil
	}
	packet := map[string]any{"operation": "send", "expected": target.Endpoint, "messageID": message.MessageID, "targetPaneID": message.TargetPaneID,
		"text": message.Text, "submittingClientID": message.CallerID, "source": source}
	native, sendErr := hooks.send(message.TargetPaneID, packet)
	outcome := communicationNativeOutcome(native, sendErr)
	err = communicationFanoutLocked(root, func() error {
		if err := communicationRead(path, &receipt); err != nil {
			return err
		}
		if !remoteReceiptMatches(receipt, message, node) {
			return errors.New("remote receipt changed during native delivery")
		}
		for key, value := range outcome {
			receipt.Result[key] = value
		}
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "remote_message_outcome", []map[string]string{{"message_id": message.MessageID, "status": fmtRemoteStatus(receipt.Result)}}); err != nil {
			return err
		}
		return nil
	})
	if err == nil && message.TargetConversation.Provider == "claude" && deliveredToDesktop(receipt.Result) {
		// A reply the desktop session can read back, under its current registration.
		if endpoint, eErr := readClaudeSessionEndpoint(root, message.TargetConversation.SessionID); eErr == nil {
			if iErr := appendDesktopInbox(root, message.TargetConversation.SessionID, desktopInboxEntry{MessageID: message.MessageID,
				SourceNode: message.SourceNodeID, SourcePane: message.SourcePaneID, Text: message.Text, AccountRoot: endpoint.AccountRoot, ReceivedAt: time.Now().UTC()}); iErr != nil {
				return remoteReceiptResult(receipt), iErr
			}
		}
	}
	return remoteReceiptResult(receipt), err
}

// communicationRemoteSourcePacket builds the sender packet for a peer-route
// message. Without a valid signature from this route's pinned peer it is the
// claimed pane label, as before; with one it is source_signed and carries the
// sender's permission class as observed on the sending node.
func communicationRemoteSourcePacket(message communicationRemoteMessage, certificateHash string, now time.Time) (map[string]any, string, string) {
	claimed := map[string]any{"hostID": message.SourceNodeID, "paneID": message.SourcePaneID, "sessionID": message.SourceConversation.SessionID}
	if message.Operation != "send" || message.SourceSignature == "" {
		return claimed, "claimed_pane_label", ""
	}
	verified, err := communicationVerifyEnvelope(message.SourceSignature,
		[]communicationTrustedNode{{NodeID: message.SourceNodeID, CertificateSHA256: certificateHash}}, now)
	if err != nil {
		return claimed, "claimed_pane_label", communicationBoundedString(err.Error(), 200)
	}
	statement := verified.Statement
	if statement.SourceNodeID != message.SourceNodeID || statement.SourcePaneID != message.SourcePaneID ||
		statement.TargetPaneID != message.TargetPaneID || statement.MessageID != message.MessageID ||
		statement.SourceSessionID != message.SourceConversation.SessionID ||
		statement.TextSHA256 != communicationTextDigest(message.Text) {
		return claimed, "claimed_pane_label", "signed statement does not match this message"
	}
	return communicationSignedSourcePacket(verified), "source_signed", ""
}

func fmtRemoteStatus(result map[string]any) string {
	status, _ := result["status"].(string)
	return status
}

func peerHandler(root, node string, hooks communicationGroupNative) http.Handler {
	probe := peerProbeHandler(root, node)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/relay-peer/message" {
			probe.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodPost || r.URL.RawQuery != "" || r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "rejected", http.StatusForbidden)
			return
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, 128<<10+1))
		if err == nil && len(data) <= 128<<10 && establishWireDetected(data) {
			handleEstablishWire(w, root, node, peerFingerprint(r.TLS.PeerCertificates[0]), data, hooks)
			return
		}
		if err == nil && len(data) <= 128<<10 && workWireVersion(data) {
			handleWorkWire(w, r, root, node, peerFingerprint(r.TLS.PeerCertificates[0]), data)
			return
		}
		var message communicationRemoteMessage
		if err != nil || len(data) > 128<<10 || json.Unmarshal(data, &message) != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		result, err := communicationReceiveRemote(r.Context(), root, node, peerFingerprint(r.TLS.PeerCertificates[0]), message, hooks)
		if err != nil {
			http.Error(w, "remote request rejected; inspect durable receipts before recovery", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(result)
	})
}
