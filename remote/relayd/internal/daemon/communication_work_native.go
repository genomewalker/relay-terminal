package daemon

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// A Work route whose peer binding names workNativeEndpoint is carried by the
// Relay app over its existing host channel to each relayd instead of an HTTPS
// peer listener. The binding keeps the same pinned peer certificate; each wire
// travels in an envelope signed with the sending node's peer identity key, and
// the receiver accepts it only when the signing certificate is the one its
// saved link pins. The app is an untrusted carrier: it can delay or drop
// envelopes but cannot forge, alter or redirect them.
//
// Sender: workSendOrReceipt claims the outbound receipt and queues the text in
// a private pending record. The carrier lists pending items, claims one (a
// signed send of the same message each time), delivers it to the peer's
// relayd and hands the signed reply back to settle. The text is deleted when
// the peer confirms a final outcome, or after 24 h with the receipt saying so.
// The receiver delivers each message ID at most once.
const (
	workNativeEndpoint  = "relay-host-channel"
	workNativeAuth      = "relay_host_channel_signed_node"
	workNativeContext   = "relay-work-native/1\n"
	workNativeWireLimit = 130 << 10
	workNativeEnvLimit  = 192 << 10
	// A deliver_signed_work request: the envelope plus JSON escaping.
	communicationSignedWorkInputLimit = 224 << 10
	workNativeFreshness               = 2 * time.Minute
	workNativeClockSkew               = 30 * time.Second
	workNativeQueryWindow             = 24 * time.Hour
	workNativeListLimit               = 64
)

var errNativePeerRoute = errors.New("this route is carried by the Relay host channel; no HTTPS peer request is made")

// workNativeNow is replaced in tests.
var workNativeNow = func() time.Time { return time.Now().UTC() }

type workNativeEnvelope struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	Node           string `json:"node"`
	Payload        string `json:"payload"`
	Signature      string `json:"signature"`
	CertificatePEM string `json:"certificate_pem"`
}

// The sender attests that it observed its own Work endpoint and caller as
// current when it dispatched. This replaces the HTTPS observe callback.
type workNativeSend struct {
	Wire            workWire  `json:"wire"`
	SourceCurrentAt time.Time `json:"source_current_at"`
}

type workNativeReply struct {
	MessageID   string         `json:"message_id"`
	LinkID      string         `json:"link_id"`
	Fingerprint string         `json:"fingerprint"`
	Result      map[string]any `json:"result"`
}

type workNativePending struct {
	Version     int       `json:"version"`
	MessageID   string    `json:"message_id"`
	LinkID      string    `json:"link_id"`
	PeerNodeID  string    `json:"peer_node_id"`
	Fingerprint string    `json:"fingerprint"`
	Text        string    `json:"text,omitempty"`
	Dispatched  bool      `json:"dispatched"`
	Queries     int       `json:"queries"`
	Created     time.Time `json:"created"`
}

func workNativePendingPath(root, id string) string {
	return filepath.Join(root, "work-native-pending-"+id+".json")
}

// workNativeSendable refuses before any receipt is claimed, so an ID is never
// burned on a message the carrier could not deliver.
func workNativeSendable(m workWire, text string, file []byte) error {
	sized := m
	sized.Text = text
	if file != nil {
		sized.FileContent = base64.StdEncoding.EncodeToString(file)
	}
	sized.PaneSignature = strings.Repeat("x", 4096)
	if body, e := json.Marshal(workNativeSend{Wire: sized, SourceCurrentAt: time.Now().UTC()}); e != nil || len(body) > workNativeWireLimit {
		return errors.New("file and note exceed the 128 KiB Work transfer limit; shorten the note or send a smaller file; no request submitted")
	}
	return nil
}

// A queued file is kept in its own private record beside the pending text,
// until the peer confirms the message or the 24 h window ends.
type workNativeFile struct {
	Version int    `json:"version"`
	SHA256  string `json:"sha256"`
	Content string `json:"content"`
}

func workNativeFilePath(root, id string) string {
	return filepath.Join(root, "work-native-file-"+id+".json")
}

// workNativeDrop removes a message's queued text and file.
func workNativeDrop(root, id string) error {
	if e := os.Remove(workNativeFilePath(root, id)); e != nil && !errors.Is(e, os.ErrNotExist) {
		return e
	}
	return os.Remove(workNativePendingPath(root, id))
}

// Called under the communication lock before the outbound receipt is written.
func workNativeQueue(root string, receipt workTransportReceipt, link communicationTypedRemoteLink, text string, file []byte) error {
	if file != nil {
		if e := communicationAtomic(workNativeFilePath(root, receipt.Wire.MessageID), workNativeFile{Version: 1, SHA256: receipt.Wire.FileSHA256, Content: base64.StdEncoding.EncodeToString(file)}); e != nil {
			return e
		}
	}
	return communicationAtomic(workNativePendingPath(root, receipt.Wire.MessageID), workNativePending{Version: 1, MessageID: receipt.Wire.MessageID, LinkID: link.ID, PeerNodeID: link.Peer.NodeID, Fingerprint: receipt.Wire.Fingerprint, Text: text, Created: workNativeNow()})
}

func workNativeReceiptResult(receipt workTransportReceipt) map[string]any {
	result := workReceiptResult(receipt)
	if workOutcomeUnknown(receipt.Result) {
		result["carrier"] = "relay_host_channel"
		result["note"] = "carried by the Relay app; query this receipt later, never resend"
	}
	return result
}

func workNativeSign(root, node, kind string, payload []byte) (string, error) {
	identity, pair, err := peerIdentity(root, node)
	if err != nil {
		return "", err
	}
	key, ok := pair.PrivateKey.(ed25519.PrivateKey)
	if !ok {
		return "", errors.New("peer identity key is not ed25519")
	}
	signature := ed25519.Sign(key, []byte(workNativeContext+kind+"\n"+string(payload)))
	body, err := json.Marshal(workNativeEnvelope{Version: 1, Kind: kind, Node: node, Payload: base64.StdEncoding.EncodeToString(payload),
		Signature: base64.StdEncoding.EncodeToString(signature), CertificatePEM: identity.CertificatePEM})
	if err != nil {
		return "", err
	}
	if len(body) > workNativeEnvLimit {
		return "", errors.New("Work envelope exceeds the Relay host channel limit")
	}
	return string(body), nil
}

// workNativeVerify checks the envelope signature against the certificate it
// carries, and returns that certificate's fingerprint. Callers must compare
// the fingerprint with their saved pin; pin may be given to do so here.
func workNativeVerify(text, kind, node, pin string) ([]byte, string, error) {
	var env workNativeEnvelope
	if len(text) == 0 || len(text) > workNativeEnvLimit || communicationStrictWorkJSONLimit([]byte(text), &env, workNativeEnvLimit) != nil {
		return nil, "", errors.New("invalid Work envelope")
	}
	if env.Version != 1 || env.Kind != kind || env.Node != node || !canonicalRouteToken(node) {
		return nil, "", errors.New("Work envelope kind or node mismatch")
	}
	cert, err := peerCertificate(env.CertificatePEM, node)
	if err != nil {
		return nil, "", err
	}
	fingerprint := peerFingerprint(cert)
	if pin != "" && fingerprint != pin {
		return nil, "", errors.New("Work envelope signer is not the pinned peer")
	}
	public, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok {
		return nil, "", errors.New("Work envelope signer key is not ed25519")
	}
	payload, err1 := base64.StdEncoding.Strict().DecodeString(env.Payload)
	signature, err2 := base64.StdEncoding.Strict().DecodeString(env.Signature)
	if err1 != nil || err2 != nil || len(payload) > workNativeWireLimit || len(signature) != ed25519.SignatureSize ||
		!ed25519.Verify(public, []byte(workNativeContext+kind+"\n"+string(payload)), signature) {
		return nil, "", errors.New("Work envelope signature invalid")
	}
	return payload, fingerprint, nil
}

func workNativeRouteBinding(root, node string, link communicationTypedRemoteLink) error {
	_, b, _, err := activePeerRoute(root, node, link.RouteID)
	if err != nil {
		return err
	}
	if b.Endpoint != workNativeEndpoint {
		return errors.New("Work route is not carried by the Relay host channel")
	}
	return nil
}

func communicationWorkNative(ctx context.Context, root, node string, r CommunicationRequest) (map[string]any, error) {
	return communicationWorkNativeWith(ctx, root, node, r, communicationGroupNative{observe: communicationObserve, send: communicationNative})
}

// communicationWorkNativeWith is the carrier entry point. hooks observe and
// deliver to local panes for a carried remote-link message.
func communicationWorkNativeWith(ctx context.Context, root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	r.MessageID = strings.ToLower(r.MessageID)
	switch r.Operation {
	case "work_native_pending":
		return workNativeList(root, node)
	case "work_native_claim":
		if remoteNativePendingFor(root, r.MessageID) {
			return remoteNativeClaim(root, node, r.MessageID)
		}
		return workNativeClaim(ctx, root, node, r.MessageID)
	case "deliver_signed_work":
		var env workNativeEnvelope
		if len(r.WorkEnvelope) <= workNativeEnvLimit && communicationStrictWorkJSONLimit([]byte(r.WorkEnvelope), &env, workNativeEnvLimit) == nil && env.Kind == remoteNativeKind {
			return remoteNativeDeliver(ctx, root, node, env, r.WorkEnvelope, hooks)
		}
		return workNativeDeliver(ctx, root, node, r.WorkEnvelope)
	case "work_native_settle":
		if remoteNativePendingFor(root, r.MessageID) {
			return remoteNativeSettle(root, node, r.MessageID, r.WorkReply)
		}
		return workNativeSettle(ctx, root, node, r.MessageID, r.WorkReply)
	}
	return nil, errors.New("unsupported Work carrier operation")
}

func workNativeList(root, node string) (map[string]any, error) {
	items := []map[string]any{}
	native := 0
	err := communicationFanoutLocked(root, func() error {
		paths, e := filepath.Glob(filepath.Join(root, "work-native-pending-*.json"))
		if e != nil {
			return e
		}
		bindings, e := filepath.Glob(filepath.Join(root, "peer-binding-*.json"))
		if e != nil {
			return e
		}
		for _, path := range bindings {
			var b CommunicationPeerBinding
			if communicationRead(path, &b) == nil && b.Endpoint == workNativeEndpoint {
				native++
			}
		}
		sort.Strings(paths)
		for _, path := range paths {
			if len(items) >= workNativeListLimit {
				break
			}
			var p workNativePending
			if communicationRead(path, &p) != nil || p.Version != 1 || workNativePendingPath(root, p.MessageID) != path {
				continue
			}
			items = append(items, map[string]any{"message_id": p.MessageID, "link_id": p.LinkID, "peer_node_id": p.PeerNodeID, "dispatched": p.Dispatched})
		}
		if len(items) < workNativeListLimit {
			remote, e := remoteNativeListItems(root, workNativeListLimit-len(items))
			if e != nil {
				return e
			}
			items = append(items, remote...)
		}
		repins, e := workNativeRepinPending(root)
		if e != nil {
			return e
		}
		for _, r := range repins {
			if len(items) >= workNativeListLimit {
				break
			}
			items = append(items, map[string]any{"message_id": r.MessageID, "link_id": r.LinkID, "peer_node_id": r.PeerNodeID, "dispatched": r.Fingerprint != "", "kind": "repin"})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"node_id": node, "items": items, "native_routes": native, "authority": "relayd"}, nil
}

// workNativeOutbound reads and cross-checks the pending record, the outbound
// receipt and the current link. Called under the communication lock.
func workNativeOutbound(ctx context.Context, root, node, id string) (workNativePending, workTransportReceipt, communicationTypedRemoteLink, error) {
	var p workNativePending
	var receipt workTransportReceipt
	var link communicationTypedRemoteLink
	if !validSessionID.MatchString(id) {
		return p, receipt, link, errors.New("message UUID required")
	}
	if e := communicationRead(workNativePendingPath(root, id), &p); e != nil {
		return p, receipt, link, e
	}
	if e := communicationRead(workOutboundPath(root, id), &receipt); e != nil {
		return p, receipt, link, e
	}
	if p.Version != 1 || p.MessageID != id || !validWorkTransportReceipt(receipt) || receipt.Node != node ||
		receipt.Wire.MessageID != id || receipt.Wire.Fingerprint != p.Fingerprint || receipt.Wire.LinkID != p.LinkID {
		return p, receipt, link, errors.New("pending Work message does not match its receipt")
	}
	var e error
	link, e = communicationReadTypedActiveLink(ctx, root, node, receipt.Wire.LinkID)
	if e != nil {
		return p, receipt, link, e
	}
	if link.RouteID != receipt.RouteID || link.RouteRevision != receipt.RouteRevision || link.PeerCertificateSHA256 != receipt.PeerCertificateSHA256 ||
		!workLinkMatchesWire(link, receipt.Wire, false) || link.Peer.NodeID != p.PeerNodeID {
		return p, receipt, link, errors.New("Work relationship changed")
	}
	return p, receipt, link, workNativeRouteBinding(root, node, link)
}

func workNativeClaim(ctx context.Context, root, node, id string) (map[string]any, error) {
	if r, ok := workNativeRepinFor(root, id); ok {
		return workNativeRepinClaim(ctx, root, node, r)
	}
	var p workNativePending
	var receipt workTransportReceipt
	var link communicationTypedRemoteLink
	settled := false
	err := communicationFanoutLocked(root, func() error {
		var e error
		p, receipt, link, e = workNativeOutbound(ctx, root, node, id)
		if e != nil {
			return e
		}
		if !workOutcomeUnknown(receipt.Result) {
			settled = true
			return workNativeDrop(root, id)
		}
		if workNativeNow().Sub(p.Created) > workNativeQueryWindow {
			// Say so in the receipt the sender reads, then stop carrying.
			receipt.Result = map[string]any{"status": "outcome_unknown", "carrier": "relay_host_channel",
				"error": "the peer did not confirm this message within 24 h; ask the recipient before sending it again under a new ID"}
			if e := communicationAtomic(workOutboundPath(root, id), receipt); e != nil {
				return e
			}
			if e := workNativeDrop(root, id); e != nil {
				return e
			}
			return errors.New("not confirmed by the peer within 24 h; the receipt says so")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if settled {
		return map[string]any{"status": "settled", "result": workReceiptResult(receipt)}, nil
	}
	// The text stays queued until the peer confirms a final outcome, so a
	// lost hop is repaired by sending the same signed message again. The
	// receiver records each message ID before delivering and answers a
	// repeat from that record, so a repeat is never delivered twice.
	// Attest the source as the HTTPS observe callback would.
	wire := receipt.Wire
	if err := communicationFanoutLocked(root, func() error { return workSourceCallerAvailable(root, wire.Caller) }); err != nil {
		return nil, err
	}
	source, err := workObserveEndpoint(ctx, link.Local)
	if err != nil || !communicationEndpointEqual(source, link.Local) {
		return nil, errors.New("source conversation changed; message not dispatched")
	}
	if link.Local.Kind == "pane" {
		signature, e := workNativeAttestPane(root, node, link, wire.Caller, wire.MessageID, p.Text)
		if e != nil {
			return nil, e
		}
		wire.PaneSignature = signature
	}
	err = communicationFanoutLocked(root, func() error {
		current, _, _, e := workNativeOutbound(ctx, root, node, id)
		if e != nil {
			return e
		}
		current.Dispatched = true
		current.Queries++
		return communicationAtomic(workNativePendingPath(root, id), current)
	})
	if err != nil {
		return nil, err
	}
	wire.Text = p.Text
	if wire.FileSHA256 != "" {
		// The file travels inside the same signed send; check it against the
		// fingerprinted size and digest before it leaves this host.
		var f workNativeFile
		if e := communicationFanoutLocked(root, func() error { return communicationRead(workNativeFilePath(root, id), &f) }); e != nil || f.Version != 1 || f.SHA256 != wire.FileSHA256 {
			return nil, errors.New("queued Work file unavailable; message not dispatched")
		}
		wire.FileContent = f.Content
		if _, e := decodeWorkWireFile(wire); e != nil {
			return nil, e
		}
	}
	return workNativeEnvelopeResult(root, node, link, "send", workNativeSend{Wire: wire, SourceCurrentAt: workNativeNow()})
}

func workNativeEnvelopeResult(root, node string, link communicationTypedRemoteLink, operation string, send workNativeSend) (map[string]any, error) {
	payload, err := json.Marshal(send)
	if err != nil {
		return nil, err
	}
	var envelope string
	if err := communicationFanoutLocked(root, func() error { var e error; envelope, e = workNativeSign(root, node, "work", payload); return e }); err != nil {
		return nil, err
	}
	return map[string]any{"status": "dispatch", "operation": operation, "message_id": send.Wire.MessageID, "peer_node_id": link.Peer.NodeID, "work_envelope": envelope}, nil
}

func workNativeDeliver(ctx context.Context, root, node, text string) (map[string]any, error) {
	var env workNativeEnvelope
	if len(text) > workNativeEnvLimit || communicationStrictWorkJSONLimit([]byte(text), &env, workNativeEnvLimit) != nil {
		return nil, errors.New("invalid Work envelope")
	}
	payload, peerCert, err := workNativeVerify(text, "work", env.Node, "")
	if err != nil {
		return nil, err
	}
	var send workNativeSend
	if err := communicationStrictWorkJSONLimit(payload, &send, workNativeWireLimit); err != nil {
		return nil, errors.New("invalid Work envelope payload")
	}
	m := send.Wire
	if m.Source.NodeID != env.Node || (m.Operation != "send" && m.Operation != "receipt" && !workNativeRepinDeliverable(m)) {
		return nil, errors.New("Work envelope does not match its signer")
	}
	// The pin comparison itself happens in workReceiveWith against the saved
	// link; here the route must also be the one carried by the host channel.
	err = communicationFanoutLocked(root, func() error {
		link, e := communicationReadTypedAuthorizedLink(ctx, root, node, m.LinkID)
		if e != nil {
			return e
		}
		return workNativeRouteBinding(root, node, link)
	})
	if err != nil {
		return nil, err
	}
	fresh := func(context.Context) error {
		age := workNativeNow().Sub(send.SourceCurrentAt)
		if send.SourceCurrentAt.IsZero() || age > workNativeFreshness || age < -workNativeClockSkew {
			return errors.New("source attestation is not current")
		}
		return nil
	}
	if m.Operation == "repin" {
		// A delayed re-pin is refused like a delayed send; the generation
		// check in the receiver refuses an old one regardless.
		if e := fresh(ctx); e != nil {
			return nil, e
		}
	}
	result, err := workReceiveWith(ctx, root, node, peerCert, m, fresh, workNativeAuth)
	if err != nil {
		return nil, err
	}
	reply, err := json.Marshal(workNativeReply{MessageID: m.MessageID, LinkID: m.LinkID, Fingerprint: m.Fingerprint, Result: result})
	if err != nil {
		return nil, err
	}
	var envelope string
	if err := communicationFanoutLocked(root, func() error { var e error; envelope, e = workNativeSign(root, node, "reply", reply); return e }); err != nil {
		return nil, err
	}
	return map[string]any{"status": "delivered_reply", "message_id": m.MessageID, "work_reply": envelope}, nil
}

func workNativeSettle(ctx context.Context, root, node, id, text string) (map[string]any, error) {
	if r, ok := workNativeRepinFor(root, id); ok {
		return workNativeRepinSettle(ctx, root, node, r, text)
	}
	var receipt workTransportReceipt
	err := communicationFanoutLocked(root, func() error {
		_, current, link, e := workNativeOutbound(ctx, root, node, id)
		if e != nil {
			return e
		}
		payload, _, e := workNativeVerify(text, "reply", link.Peer.NodeID, current.PeerCertificateSHA256)
		if e != nil {
			return e
		}
		var reply workNativeReply
		if e := communicationStrictWorkJSONLimit(payload, &reply, workNativeWireLimit); e != nil {
			return errors.New("invalid Work reply")
		}
		if reply.MessageID != current.Wire.MessageID || reply.LinkID != current.Wire.LinkID || reply.Fingerprint != current.Wire.Fingerprint || reply.Result == nil {
			return errors.New("Work reply does not match this message")
		}
		receipt = current
		if !workOutcomeUnknown(current.Result) {
			return workNativeDrop(root, id)
		}
		result := communicationNativeOutcome(reply.Result, nil)
		if workOutcomeUnknown(result) {
			// The peer holds no final outcome yet; keep polling by receipt.
			return nil
		}
		result["peer_authentication"] = workNativeAuth
		current.Result = result
		if e := communicationAtomic(workOutboundPath(root, id), current); e != nil {
			return e
		}
		receipt = current
		return workNativeDrop(root, id)
	})
	if err != nil {
		return nil, err
	}
	return workNativeReceiptResult(receipt), nil
}

// communicationBindingTransportSet moves an existing peer binding between the
// HTTPS peer listener and the Relay host channel. Only the endpoint changes:
// the binding identity, peer node and pinned certificate stay the same, so
// routes, links, pins and receipts are untouched. Switching back restores the
// HTTPS endpoint saved when the binding moved to the host channel.
// Owner administration; the communication lock is held by the caller.
func communicationBindingTransportSet(root, node string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	id := strings.ToLower(r.TransportBindingID)
	previous, cert, err := peerBinding(root, node, id)
	if err != nil {
		return nil, err
	}
	if r.PeerBinding == nil || strings.ToLower(r.PeerBinding.ID) != id {
		return nil, errors.New("binding identity and target endpoint required")
	}
	target := r.PeerBinding.Endpoint
	if target == previous.Endpoint {
		return map[string]any{"binding": previous, "certificate_sha256": peerFingerprint(cert), "changed": false, "authority": "relayd"}, nil
	}
	saved := filepath.Join(root, "saved-https-binding-"+id+".json")
	next := previous
	next.Endpoint = target
	if target == workNativeEndpoint {
		if e := communicationAtomic(saved, previous); e != nil {
			return nil, e
		}
	} else {
		var https CommunicationPeerBinding
		if previous.Endpoint != workNativeEndpoint || communicationRead(saved, &https) != nil || https.Endpoint != target ||
			https.ID != id || https.PeerNodeID != previous.PeerNodeID || https.CertificatePEM != previous.CertificatePEM {
			return nil, errors.New("only the saved HTTPS endpoint of this binding can be restored")
		}
	}
	if _, e := validPeerBinding(next, node); e != nil {
		return nil, e
	}
	if e := communicationAtomic(filepath.Join(root, "peer-binding-"+id+".json"), next); e != nil {
		return nil, e
	}
	if e := communicationEvent(root, node, "communication_peer_binding_transport_changed", []map[string]string{{"binding_id": id, "transport": map[bool]string{true: "relay_host_channel", false: "https_peer"}[target == workNativeEndpoint]}}); e != nil {
		return nil, errors.New("binding transport changed but event append failed; inspect before recovery")
	}
	return map[string]any{"binding": next, "certificate_sha256": peerFingerprint(cert), "changed": true, "authority": "relayd"}, nil
}

// workNativeAttestPane signs a queued pane message again when the carrier
// dispatches it. The pane's statement from send time is valid for only
// communicationStatementTTL, while a host-channel message can wait in the queue
// much longer (an offline peer, a slow carrier), so the peer would refuse the
// old statement as expired. The pane proved its authorship when the message
// was queued: only a kernel-verified actor gets a receipt. Here the source host
// observes that the same pane still runs the same provider session and
// attests it again for the same message ID, text, link revisions and target.
// The fingerprint does not cover the signature, so the message is unchanged.
// A pane whose session has changed is refused, never re-signed.
func workNativeAttestPane(root, node string, link communicationTypedRemoteLink, caller, messageID, text string) (string, error) {
	if link.Local.Kind != "pane" || link.Peer.Work == nil || !validSessionID.MatchString(link.Local.PaneID) || !validSessionID.MatchString(link.Local.SessionID) {
		return "", errors.New("Work relationship changed")
	}
	d := defaultCommunicationSigningDeps(root, node)
	d.observe = workPaneObserve
	request := CommunicationRequest{Operation: "remote_send", SourcePaneID: link.Local.PaneID, ActorPaneID: link.Local.PaneID,
		MessageID: messageID, Text: text, ClientID: caller, actorVerified: true}
	var signature string
	if err := communicationFanoutLocked(root, func() error {
		var e error
		signature, e = communicationSignWork(root, node, request, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, d)
		return e
	}); err != nil {
		return "", errors.New("the sending pane has no verified native session; message not dispatched")
	}
	_, hostCert, err := d.keys.HostKey()
	if err != nil || hostCert == nil {
		return "", errors.New("source host identity unavailable")
	}
	if _, err := communicationVerifyWorkMessage(signature, []communicationTrustedNode{{NodeID: node, CertificateSHA256: peerFingerprint(hostCert)}}, d.now().UTC(),
		link.Local.NodeID, link.Local.PaneID, link.Local.Provider, link.Local.SessionID, link.Peer.NodeID, messageID, link.ID, link.Revision, link.PeerRevision, []byte(text), *link.Peer.Work); err != nil {
		return "", errors.New("the sending pane could not be attested again; message not dispatched: " + err.Error())
	}
	return signature, nil
}
