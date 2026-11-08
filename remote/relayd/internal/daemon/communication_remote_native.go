package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// A route-link message (desktop session <-> pane, or pane <-> pane) on a route
// whose peer binding is the Relay host channel is carried by the app's Work
// carrier, exactly like a Work message: the sender claims its outbound receipt
// and queues the text in a private pending record; the carrier lists it,
// claims a signed "remote" envelope, hands it to the peer's relayd, and brings
// the signed "remote_reply" back to settle. The receiver runs the same checks
// as the HTTPS listener (communicationReceiveRemote): pinned peer key, link
// revisions, reviewed conversations, allowed caller and fingerprint, and it
// delivers each message ID at most once. Until the peer answers, the receipt
// stays outcome_unknown and says it is carried.

const (
	remoteNativeKind      = "remote"
	remoteNativeReplyKind = "remote_reply"
	remoteNativeNote      = "carried by the Relay app over the host channel; query this receipt later, never resend"
	// remoteNativeTooLatePrefix starts both too-late messages; remoteNativeFinalState
	// classifies by it.
	remoteNativeTooLatePrefix = "carried too late"
	// remoteNativeTooLate names a signed message the carrier could not deliver
	// while the sender's signed statement was still valid.
	remoteNativeTooLate = remoteNativeTooLatePrefix + ": the sender's signed statement would expire before delivery; nothing was sent. Resend under a new message ID"
	// remoteNativeTooLateDelivery is the receiver's refusal of a signed message
	// whose statement expired in transit. An earlier copy may have arrived.
	remoteNativeTooLateDelivery = remoteNativeTooLatePrefix + ": the sender's signed statement expired before delivery; it was not delivered now. Ask the recipient whether an earlier copy arrived, then resend under a new message ID"
	// remoteNativeSignedWindow leaves the carrier time to deliver before the
	// statement expires.
	remoteNativeSignedWindow = communicationStatementTTL - time.Minute
)

type remoteNativePending struct {
	Version     int       `json:"version"`
	MessageID   string    `json:"message_id"`
	LinkID      string    `json:"link_id"`
	PeerNodeID  string    `json:"peer_node_id"`
	Fingerprint string    `json:"fingerprint"`
	Text        string    `json:"text"`
	Dispatched  bool      `json:"dispatched"`
	Queries     int       `json:"queries"`
	Created     time.Time `json:"created"`
}

type remoteNativeSend struct {
	Wire communicationRemoteMessage `json:"wire"`
}

type remoteNativeReply struct {
	MessageID   string         `json:"message_id"`
	LinkID      string         `json:"link_id"`
	Fingerprint string         `json:"fingerprint"`
	Result      map[string]any `json:"result"`
}

func remoteNativePendingPath(root, id string) string {
	return filepath.Join(root, "remote-native-pending-"+id+".json")
}

// remoteNativePendingFor reports whether id names a queued route-link message.
func remoteNativePendingFor(root, id string) bool {
	if !canonicalRouteToken(id) {
		return false
	}
	_, err := os.Stat(remoteNativePendingPath(root, id))
	return err == nil
}

// remoteNativeQueue records the text for the carrier. Called under the
// communication lock, before the outbound receipt is written.
func remoteNativeQueue(root string, wire communicationRemoteMessage, text string) error {
	return communicationAtomic(remoteNativePendingPath(root, wire.MessageID), remoteNativePending{Version: 1, MessageID: wire.MessageID,
		LinkID: wire.LinkID, PeerNodeID: wire.TargetNodeID, Fingerprint: wire.Fingerprint, Text: text, Created: workNativeNow()})
}

// remoteNativeCarried marks an outbound result as waiting for the carrier.
func remoteNativeCarried(result map[string]any) map[string]any {
	if fmtRemoteStatus(result) == "outcome_unknown" || fmtRemoteStatus(result) == "unknown" {
		result["carrier"] = "relay_host_channel"
		result["note"] = remoteNativeNote
		delete(result, "error")
	}
	return result
}

// remoteNativeListItems lists queued route-link messages for the carrier.
func remoteNativeListItems(root string, limit int) ([]map[string]any, error) {
	paths, err := filepath.Glob(filepath.Join(root, "remote-native-pending-*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	items := []map[string]any{}
	for _, path := range paths {
		if len(items) >= limit {
			break
		}
		var p remoteNativePending
		if communicationRead(path, &p) != nil || p.Version != 1 || remoteNativePendingPath(root, p.MessageID) != path {
			continue
		}
		items = append(items, map[string]any{"message_id": p.MessageID, "link_id": p.LinkID, "peer_node_id": p.PeerNodeID, "dispatched": p.Dispatched, "kind": remoteNativeKind})
	}
	return items, nil
}

// remoteNativeOutbound cross-checks the pending record, the outbound receipt,
// the current link and its route. Called under the communication lock.
func remoteNativeOutbound(root, node, id string) (remoteNativePending, communicationRemoteOutbound, CommunicationRemoteLink, error) {
	var p remoteNativePending
	var receipt communicationRemoteOutbound
	var link CommunicationRemoteLink
	if err := communicationRead(remoteNativePendingPath(root, id), &p); err != nil {
		return p, receipt, link, err
	}
	if err := communicationRead(remoteOutboundPath(root, id), &receipt); err != nil {
		return p, receipt, link, err
	}
	if p.Version != 1 || p.MessageID != id || !validRemoteOutbound(receipt, node) || receipt.Wire.MessageID != id ||
		receipt.Wire.Fingerprint != p.Fingerprint || receipt.Wire.LinkID != p.LinkID || receipt.Wire.TargetNodeID != p.PeerNodeID {
		return p, receipt, link, errors.New("pending remote message does not match its receipt")
	}
	var err error
	link, err = readRemoteLink(root, node, receipt.Wire.LinkID)
	if err != nil {
		return p, receipt, link, err
	}
	if link.Retired || link.Revision != receipt.Wire.SourceLinkRevision || link.PeerRevision != receipt.Wire.TargetLinkRevision ||
		link.RouteID != receipt.RouteID || link.RouteRevision != receipt.RouteRevision || link.PeerCertificateSHA256 != receipt.PeerCertificateSHA256 ||
		link.PeerNodeID != receipt.Wire.TargetNodeID || link.PeerPaneID != receipt.Wire.TargetPaneID || link.LocalPaneID != receipt.Wire.SourcePaneID {
		return p, receipt, link, errors.New("reviewed remote pair changed; message not dispatched")
	}
	binding, err := remoteOutboundRoute(root, node, receipt)
	if err != nil {
		return p, receipt, link, err
	}
	if binding.Endpoint != workNativeEndpoint {
		return p, receipt, link, errors.New("remote route is not carried by the Relay host channel")
	}
	return p, receipt, link, nil
}

// remoteNativeClaim returns the signed send for one queued message. The same
// signed message is sent again until the peer confirms; the receiver answers a
// repeat from its record and never delivers it twice.
func remoteNativeClaim(root, node, id string) (map[string]any, error) {
	var p remoteNativePending
	var receipt communicationRemoteOutbound
	settled := false
	err := communicationFanoutLocked(root, func() error {
		var err error
		p, receipt, _, err = remoteNativeOutbound(root, node, id)
		if err != nil {
			return err
		}
		if status := fmtRemoteStatus(receipt.Result); status != "outcome_unknown" && status != "unknown" {
			settled = true
			return os.Remove(remoteNativePendingPath(root, id))
		}
		if !p.Dispatched && receipt.Wire.SourceSignature != "" && workNativeNow().Sub(p.Created) > remoteNativeSignedWindow {
			// Nothing left this host, and the sender's signed statement would have
			// expired on arrival: say so rather than deliver an unverified label.
			receipt.Result = map[string]any{"status": "not_sent", "carrier": "relay_host_channel", "error": remoteNativeTooLate}
			receipt.RequestFinished = true
			if err := communicationAtomic(remoteOutboundPath(root, id), receipt); err != nil {
				return err
			}
			if err := os.Remove(remoteNativePendingPath(root, id)); err != nil {
				return err
			}
			return errors.New(remoteNativeTooLate)
		}
		if workNativeNow().Sub(p.Created) > workNativeQueryWindow {
			receipt.Result = map[string]any{"status": "outcome_unknown", "carrier": "relay_host_channel",
				"error": "the peer did not confirm this message within 24 h; ask the recipient before sending it again under a new ID"}
			if err := communicationAtomic(remoteOutboundPath(root, id), receipt); err != nil {
				return err
			}
			if err := os.Remove(remoteNativePendingPath(root, id)); err != nil {
				return err
			}
			return errors.New("not confirmed by the peer within 24 h; the receipt says so")
		}
		p.Dispatched = true
		p.Queries++
		return communicationAtomic(remoteNativePendingPath(root, id), p)
	})
	if err != nil {
		return nil, err
	}
	if settled {
		return map[string]any{"status": "settled", "result": remoteOutboundResult(receipt)}, nil
	}
	wire := receipt.Wire
	wire.Text = p.Text
	payload, err := json.Marshal(remoteNativeSend{Wire: wire})
	if err != nil {
		return nil, err
	}
	var envelope string
	if err := communicationFanoutLocked(root, func() error {
		var e error
		envelope, e = workNativeSign(root, node, remoteNativeKind, payload)
		return e
	}); err != nil {
		return nil, err
	}
	return map[string]any{"status": "dispatch", "operation": "send", "message_id": id, "peer_node_id": wire.TargetNodeID, "work_envelope": envelope}, nil
}

// remoteNativeDeliver verifies a carried route-link message and runs the same
// receiver as the HTTPS listener, with the envelope signer's key fingerprint
// standing in for the TLS peer certificate.
func remoteNativeDeliver(ctx context.Context, root, node string, env workNativeEnvelope, text string, hooks communicationGroupNative) (map[string]any, error) {
	payload, signer, err := workNativeVerify(text, remoteNativeKind, env.Node, "")
	if err != nil {
		return nil, err
	}
	var send remoteNativeSend
	if err := communicationStrictWorkJSONLimit(payload, &send, workNativeWireLimit); err != nil {
		return nil, errors.New("invalid remote envelope payload")
	}
	m := send.Wire
	if m.SourceNodeID != env.Node || m.TargetNodeID != node || m.Operation != "send" {
		return nil, errors.New("remote envelope does not match its signer")
	}
	tooLate := false
	err = communicationFanoutLocked(root, func() error {
		link, e := readRemoteLink(root, node, m.LinkID)
		if e != nil {
			return e
		}
		// The envelope signer must be the key this link pins for the sending
		// node, before anything is answered or signed for it.
		if signer != link.PeerCertificateSHA256 {
			return errors.New("remote envelope signer is not the pinned peer")
		}
		_, binding, _, e := activePeerRoute(root, node, link.RouteID)
		if e != nil {
			return e
		}
		if binding.Endpoint != workNativeEndpoint {
			return errors.New("remote route is not carried by the Relay host channel")
		}
		// Pair, revisions, conversations, caller and route pin, as the receiver checks.
		if _, e := authorizeRemoteMessage(root, node, signer, m); e != nil {
			return e
		}
		if !validRemoteMessage(m, node) || remoteMessageFingerprint(m) != m.Fingerprint {
			return errors.New("invalid remote message scope or fingerprint")
		}
		// A signed message whose statement expired in transit is refused by
		// name, never delivered with a downgraded label. A repeat of a
		// delivered message is still answered from its receipt.
		if m.SourceSignature != "" {
			if _, e := os.Stat(remoteReceiptPath(root, m.SourceNodeID, m.MessageID)); errors.Is(e, os.ErrNotExist) {
				_, e := communicationVerifyEnvelope(m.SourceSignature,
					[]communicationTrustedNode{{NodeID: m.SourceNodeID, CertificateSHA256: link.PeerCertificateSHA256}}, workNativeNow())
				tooLate = errors.Is(e, errSignedStatementExpired)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if tooLate {
		// Answered, signed and unrecorded: the sender settles on this refusal.
		result = map[string]any{"status": "not_delivered", "error": remoteNativeTooLateDelivery, "message_id": m.MessageID,
			"source_node_id": m.SourceNodeID, "source_pane_id": m.SourcePaneID, "target_node_id": m.TargetNodeID, "pane_id": m.TargetPaneID,
			"submitting_client_id": m.CallerID, "fingerprint": m.Fingerprint}
	} else if result, err = communicationReceiveRemote(ctx, root, node, signer, m, hooks); err != nil {
		return nil, err
	}
	reply, err := json.Marshal(remoteNativeReply{MessageID: m.MessageID, LinkID: m.LinkID, Fingerprint: m.Fingerprint, Result: result})
	if err != nil {
		return nil, err
	}
	var envelope string
	if err := communicationFanoutLocked(root, func() error {
		var e error
		envelope, e = workNativeSign(root, node, remoteNativeReplyKind, reply)
		return e
	}); err != nil {
		return nil, err
	}
	return map[string]any{"status": "delivered_reply", "message_id": m.MessageID, "work_reply": envelope}, nil
}

// remoteNativeSettle records the peer's signed outcome on the outbound receipt,
// after the same checks the HTTPS path makes on the peer's answer.
func remoteNativeSettle(root, node, id, text string) (map[string]any, error) {
	var receipt communicationRemoteOutbound
	err := communicationFanoutLocked(root, func() error {
		_, current, _, err := remoteNativeOutbound(root, node, id)
		if err != nil {
			return err
		}
		payload, _, err := workNativeVerify(text, remoteNativeReplyKind, current.Wire.TargetNodeID, current.PeerCertificateSHA256)
		if err != nil {
			return err
		}
		var reply remoteNativeReply
		if err := communicationStrictWorkJSONLimit(payload, &reply, workNativeWireLimit); err != nil {
			return errors.New("invalid remote reply")
		}
		wire, r := current.Wire, reply.Result
		if reply.MessageID != wire.MessageID || reply.LinkID != wire.LinkID || reply.Fingerprint != wire.Fingerprint || r == nil ||
			r["message_id"] != wire.MessageID || r["source_node_id"] != node || r["source_pane_id"] != wire.SourcePaneID ||
			r["target_node_id"] != wire.TargetNodeID || r["pane_id"] != wire.TargetPaneID || r["submitting_client_id"] != wire.CallerID ||
			r["fingerprint"] != wire.Fingerprint {
			return errors.New("remote reply does not match this message")
		}
		receipt = current
		if status := fmtRemoteStatus(current.Result); status != "outcome_unknown" && status != "unknown" {
			return os.Remove(remoteNativePendingPath(root, id))
		}
		outcome := communicationNativeOutcome(r, nil)
		if status := fmtRemoteStatus(outcome); status == "outcome_unknown" || status == "unknown" {
			// The peer holds no final outcome yet; the carrier asks again.
			return nil
		}
		if r["source_authentication"] == "source_signed" {
			outcome["source_authentication"] = "source_signed"
		}
		outcome["peer_authentication"] = workNativeAuth
		current.Result, current.PeerConfirmed, current.RequestFinished = outcome, true, true
		if err := communicationAtomic(remoteOutboundPath(root, id), current); err != nil {
			return err
		}
		receipt = current
		if err := os.Remove(remoteNativePendingPath(root, id)); err != nil {
			return err
		}
		return communicationEvent(root, node, "remote_outbound_outcome", []map[string]string{{"message_id": id, "status": fmtRemoteStatus(outcome)}})
	})
	if err != nil {
		return nil, err
	}
	return remoteNativeQueuedResult(root, receipt), nil
}

// communicationRemoteReceiptLookup answers a plain receipt query for a message
// this node sent over a route link. Pane-to-pane messages keep their own
// record; only an ID with a remote outbound receipt and no local record is
// answered here, under the same submitting-caller and sender checks as
// remote_receipt.
func communicationRemoteReceiptLookup(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, bool, error) {
	id := strings.ToLower(r.MessageID)
	// A caller with neither credential nor proven pane keeps the local receipt
	// only; remote_receipt would treat it as the owner.
	if r.Operation != "receipt" || !canonicalRouteToken(id) || (r.ClientToken == "" && r.ActorPaneID == "") {
		return nil, false, nil
	}
	if _, err := os.Stat(filepath.Join(root, "message-"+id+".json")); err == nil {
		return nil, false, nil
	}
	if _, err := os.Stat(remoteOutboundPath(root, id)); err != nil {
		return nil, false, nil
	}
	query := r
	query.Operation, query.MessageID, query.Text = "remote_receipt", id, ""
	result, err := communicationSendRemote(root, node, query, hooks)
	return result, true, err
}

// remoteNativeUnsettled answers a receipt query for a host-channel message the
// peer has not confirmed. A message with no pending record was never queued
// (relayd before host-channel route links refused it before any I/O), so its
// receipt says so instead of promising a carrier that will never come.
func remoteNativeUnsettled(root string, receipt communicationRemoteOutbound) map[string]any {
	if remoteNativePendingFor(root, receipt.Wire.MessageID) {
		return remoteNativeQueuedResult(root, receipt)
	}
	result := remoteOutboundResult(receipt)
	result["carrier"] = "relay_host_channel"
	if stored, _ := receipt.Result["error"].(string); stored != "" && receipt.Result["carrier"] != nil {
		return result
	}
	result["error"] = "this message was never queued for the Relay host channel and no peer request was made; ask the recipient before sending it again under a new ID"
	return result
}

// remoteNativeQueuedResult is the outbound result of a message that may be
// waiting in this host's queue for the Relay app's carrier. Its status stays
// outcome_unknown for older readers; carrier_state says queued, with
// queued_at and carry_deadline: queued_at plus remoteNativeSignedWindow for a
// signed message (later, it is not sent), or plus the 24 h query window for
// an unsigned one. Once the pending record is gone, the receipt's own final
// carrier_state stands (see remoteNativeFinalState).
func remoteNativeQueuedResult(root string, receipt communicationRemoteOutbound) map[string]any {
	result := remoteNativeCarried(remoteOutboundResult(receipt))
	if status := fmtRemoteStatus(result); status != "outcome_unknown" && status != "unknown" {
		return result
	}
	var p remoteNativePending
	if communicationRead(remoteNativePendingPath(root, receipt.Wire.MessageID), &p) != nil || p.Version != 1 || p.MessageID != receipt.Wire.MessageID {
		return result
	}
	window := workNativeQueryWindow
	if receipt.Wire.SourceSignature != "" {
		window = remoteNativeSignedWindow
	}
	result["carrier_state"] = "queued"
	result["dispatched"] = p.Dispatched
	result["queued_at"] = p.Created.UTC()
	result["carry_deadline"] = p.Created.UTC().Add(window)
	return result
}

// remoteNativeFinalState names how a host-channel message ended: too_late
// (not sent, or refused by the peer because its signed statement expired),
// refused (the peer answered with an error), or carried. Empty while
// unsettled or for a message that never used the host channel.
func remoteNativeFinalState(receipt communicationRemoteOutbound) string {
	errText, _ := receipt.Result["error"].(string)
	if strings.HasPrefix(errText, remoteNativeTooLatePrefix) {
		return "too_late"
	}
	if !receipt.PeerConfirmed || receipt.Result["peer_authentication"] != workNativeAuth {
		return ""
	}
	switch fmtRemoteStatus(receipt.Result) {
	case "outcome_unknown", "unknown":
		return ""
	case "not_delivered", "not_sent", "refused", "rejected":
		return "refused"
	}
	if errText != "" {
		return "refused"
	}
	return "carried"
}
