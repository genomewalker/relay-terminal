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
// a private pending record. The carrier lists pending items, claims one
// (the first claim marks it dispatched and returns the signed send; every
// later claim returns a signed receipt query, never the text again), delivers
// it to the peer's relayd and hands the signed reply back to settle.
const (
	workNativeEndpoint   = "relay-host-channel"
	workNativeAuth       = "relay_host_channel_signed_node"
	workNativeContext    = "relay-work-native/1\n"
	workNativeWireLimit  = 36 << 10
	workNativeEnvLimit   = 56 << 10
	workNativeFreshness  = 2 * time.Minute
	workNativeClockSkew  = 30 * time.Second
	workNativeQueryLimit = 32
	workNativeListLimit  = 64
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
func workNativeSendable(m workWire, text string, file bool) error {
	if file {
		return errors.New("files are not carried over the Relay host channel yet; no request submitted")
	}
	sized := m
	sized.Text = text
	sized.PaneSignature = strings.Repeat("x", 4096)
	if body, e := json.Marshal(workNativeSend{Wire: sized, SourceCurrentAt: time.Now().UTC()}); e != nil || len(body) > workNativeWireLimit {
		return errors.New("note exceeds the Relay host channel Work limit; shorten it; no request submitted")
	}
	return nil
}

// Called under the communication lock before the outbound receipt is written.
func workNativeQueue(root string, receipt workTransportReceipt, link communicationTypedRemoteLink, text string) error {
	return communicationAtomic(workNativePendingPath(root, receipt.Wire.MessageID), workNativePending{Version: 1, MessageID: receipt.Wire.MessageID, LinkID: link.ID, PeerNodeID: link.Peer.NodeID, Fingerprint: receipt.Wire.Fingerprint, Text: text, Created: receipt.Created})
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
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	r.MessageID = strings.ToLower(r.MessageID)
	switch r.Operation {
	case "work_native_pending":
		return workNativeList(root, node)
	case "work_native_claim":
		return workNativeClaim(ctx, root, node, r.MessageID)
	case "deliver_signed_work":
		return workNativeDeliver(ctx, root, node, r.WorkEnvelope)
	case "work_native_settle":
		return workNativeSettle(ctx, root, node, r.MessageID, r.WorkReply)
	}
	return nil, errors.New("unsupported Work carrier operation")
}

func workNativeList(root, node string) (map[string]any, error) {
	items := []map[string]any{}
	err := communicationFanoutLocked(root, func() error {
		paths, e := filepath.Glob(filepath.Join(root, "work-native-pending-*.json"))
		if e != nil {
			return e
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
		return nil
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"node_id": node, "items": items, "authority": "relayd"}, nil
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
			return os.Remove(workNativePendingPath(root, id))
		}
		if p.Dispatched {
			// Never send the text again; ask the peer for its receipt.
			p.Queries++
			if p.Queries > workNativeQueryLimit {
				if e := os.Remove(workNativePendingPath(root, id)); e != nil {
					return e
				}
				return errors.New("receipt query limit reached; the outcome stays unknown and is never resent")
			}
			return communicationAtomic(workNativePendingPath(root, id), p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if settled {
		return map[string]any{"status": "settled", "result": workReceiptResult(receipt)}, nil
	}
	wire := receipt.Wire
	if p.Dispatched {
		wire.Operation = "receipt"
		return workNativeEnvelopeResult(root, node, link, "receipt", workNativeSend{Wire: wire})
	}
	// Attest the source as the HTTPS observe callback would: the caller is
	// still admitted and the local Work endpoint is the linked one.
	if err := communicationFanoutLocked(root, func() error { return workSourceCallerAvailable(root, wire.Caller) }); err != nil {
		return nil, err
	}
	source, err := workObserveEndpoint(ctx, link.Local)
	if err != nil || !communicationEndpointEqual(source, link.Local) {
		return nil, errors.New("source conversation changed; message not dispatched")
	}
	attested := workNativeNow()
	operation := "send"
	err = communicationFanoutLocked(root, func() error {
		current, currentReceipt, _, e := workNativeOutbound(ctx, root, node, id)
		if e != nil {
			return e
		}
		if current.Dispatched || currentReceipt.Wire.Fingerprint != wire.Fingerprint {
			// Another carrier dispatched it first.
			operation = "receipt"
			return nil
		}
		p = current
		text := p.Text
		p.Dispatched, p.Text = true, ""
		if e := communicationAtomic(workNativePendingPath(root, id), p); e != nil {
			return e
		}
		wire.Text = text
		return nil
	})
	if err != nil {
		return nil, err
	}
	if operation == "receipt" {
		wire.Operation, wire.Text = "receipt", ""
		return workNativeEnvelopeResult(root, node, link, operation, workNativeSend{Wire: wire})
	}
	return workNativeEnvelopeResult(root, node, link, operation, workNativeSend{Wire: wire, SourceCurrentAt: attested})
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
	if m.Source.NodeID != env.Node || (m.Operation != "send" && m.Operation != "receipt") {
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
			return os.Remove(workNativePendingPath(root, id))
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
		return os.Remove(workNativePendingPath(root, id))
	})
	if err != nil {
		return nil, err
	}
	return workNativeReceiptResult(receipt), nil
}
