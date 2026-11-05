package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/desktoproute"
	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// The Work channel uses the existing pinned mutual-TLS peer transport. A peer
// may speak only for the exact local endpoint in its reciprocal saved link.
// Native Work sources additionally require protected metadata authenticated
// against the provider-owned pipe chain at the local CLI boundary.
type workWire struct {
	Version        int                   `json:"version"`
	Operation      string                `json:"operation"`
	LinkID         string                `json:"link_id"`
	Source         communicationEndpoint `json:"source"`
	Target         communicationEndpoint `json:"target"`
	SourceRevision uint64                `json:"source_revision"`
	TargetRevision uint64                `json:"target_revision"`
	// PinGeneration is set only on a re-pin: the new generation of the Work
	// endpoint pin. It is covered by the fingerprint.
	PinGeneration uint64 `json:"pin_generation,omitempty"`
	Caller        string `json:"caller"`
	MessageID     string `json:"message_id"`
	Text          string `json:"text,omitempty"`
	TextSHA256    string `json:"text_sha256"`
	Fingerprint   string `json:"fingerprint"`
	PaneSignature string `json:"pane_signature,omitempty"`
	// Optional file: name, size and digest are fingerprinted; the base64
	// content travels only on the wire and is never stored in a receipt.
	FileName    string `json:"file_name,omitempty"`
	FileSize    int64  `json:"file_size,omitempty"`
	FileSHA256  string `json:"file_sha256,omitempty"`
	FileContent string `json:"file_content,omitempty"`
}

type workTransportReceipt struct {
	Version               int            `json:"version"`
	Node                  string         `json:"node"`
	RouteID               string         `json:"route_id"`
	RouteRevision         uint64         `json:"route_revision"`
	PeerCertificateSHA256 string         `json:"peer_certificate_sha256"`
	Wire                  workWire       `json:"wire"`
	Created               time.Time      `json:"created"`
	Result                map[string]any `json:"result"`
}

func workFingerprint(m workWire) string {
	if m.Version != 3 || !m.Source.valid() || !m.Target.valid() || m.Source.Kind == m.Target.Kind || m.Source.NodeID == m.Target.NodeID || !remoteDigest(m.LinkID) || m.LinkID != communicationEndpointPairID(m.Source, m.Target) || m.SourceRevision == 0 || m.TargetRevision == 0 || !canonicalRouteToken(m.Caller) || !validSessionID.MatchString(m.MessageID) || !remoteDigest(m.TextSHA256) || !workWireFileValid(m) {
		return ""
	}
	m.Operation = ""
	m.Text = ""
	m.FileContent = ""
	m.Fingerprint = ""
	m.PaneSignature = ""
	b, e := json.Marshal(m)
	if e != nil {
		return ""
	}
	h := sha256.Sum256(append([]byte("relay-work-transport-v3\x00"), b...))
	return hex.EncodeToString(h[:])
}
func workOutboundPath(root, id string) string {
	return filepath.Join(root, "work-outbound-"+id+".json")
}
func workInboundPath(root, node, id string) string {
	return filepath.Join(root, "work-inbound-"+node+"-"+id+".json")
}
func validWorkTransportReceipt(r workTransportReceipt) bool {
	return r.Version == 3 && r.Node != "" && r.Wire.Text == "" && r.Wire.FileContent == "" && r.Wire.Fingerprint != "" && r.Wire.Fingerprint == workFingerprint(r.Wire) && r.RouteRevision > 0 && remoteDigest(r.PeerCertificateSHA256) && !r.Created.IsZero() && r.Result != nil
}
func workReceiptResult(r workTransportReceipt) map[string]any {
	result := map[string]any{}
	for k, v := range r.Result {
		result[k] = v
	}
	result["message_id"] = r.Wire.MessageID
	result["link_id"] = r.Wire.LinkID
	result["fingerprint"] = r.Wire.Fingerprint
	result["replay_permitted"] = false
	result["authority"] = "relayd"
	return result
}
func workLinkMatchesWire(link communicationTypedRemoteLink, m workWire, inbound bool) bool {
	if link.Retired || !validTypedRemoteLink(link, link.Local.NodeID) || link.ID != m.LinkID {
		return false
	}
	if inbound {
		return communicationEndpointEqual(link.Local, m.Target) && communicationEndpointEqual(link.Peer, m.Source) && link.Revision == m.TargetRevision && link.PeerRevision == m.SourceRevision && containsCommunicationPane(link.AllowedPeerCallers, m.Caller)
	}
	return communicationEndpointEqual(link.Local, m.Source) && communicationEndpointEqual(link.Peer, m.Target) && link.Revision == m.SourceRevision && link.PeerRevision == m.TargetRevision
}
func workPeerBinding(ctx context.Context, root, node string, link communicationTypedRemoteLink) (CommunicationPeerBinding, error) {
	current, e := communicationReadTypedActiveLink(ctx, root, node, link.ID)
	if e != nil {
		return CommunicationPeerBinding{}, e
	}
	if current.Revision != link.Revision || current.PeerRevision != link.PeerRevision || current.RouteID != link.RouteID || current.RouteRevision != link.RouteRevision || current.PeerCertificateSHA256 != link.PeerCertificateSHA256 || !communicationEndpointEqual(current.Local, link.Local) || !communicationEndpointEqual(current.Peer, link.Peer) {
		return CommunicationPeerBinding{}, errors.New("Work relationship changed")
	}
	_, b, _, e := activePeerRoute(root, node, current.RouteID)
	return b, e
}

func workSendOrReceipt(ctx context.Context, root, node, caller string, r WorkRequest, origin workRequestOrigin, link communicationTypedRemoteLink) (map[string]any, error) {
	path := workOutboundPath(root, r.MessageID)
	var receipt workTransportReceipt
	var binding CommunicationPeerBinding
	claimed, existing := false, false
	err := communicationFanoutLocked(root, func() error {
		var e error
		if _, e = communicationAuthorize(root, CommunicationRequest{Operation: map[bool]string{true: "remote_send", false: "remote_receipt"}[r.Operation == "send"], ClientToken: r.ClientToken, ActorPaneID: origin.pane, SourcePaneID: origin.pane}); e != nil {
			return e
		}
		binding, e = workPeerBinding(ctx, root, node, link)
		if e != nil {
			return e
		}
		if e = communicationRead(path, &receipt); e == nil {
			if !validWorkTransportReceipt(receipt) || receipt.Node != node || receipt.Wire.Caller != caller || !workLinkMatchesWire(link, receipt.Wire, false) {
				return errors.New("message identity conflicts with saved receipt")
			}
			if r.Operation == "send" && communicationTextDigest(r.Text) != receipt.Wire.TextSHA256 {
				return errors.New("message identity conflicts with prior text")
			}
			if r.Operation == "send" && (r.file == nil) != (receipt.Wire.FileSHA256 == "") || r.file != nil && r.file.sha256 != receipt.Wire.FileSHA256 {
				return errors.New("message identity conflicts with prior file")
			}
			existing = true
			return nil
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if existing && (r.Operation == "send" || !workOutcomeUnknown(receipt.Result)) {
		return workReceiptResult(receipt), nil
	}
	if r.Operation == "receipt" && !existing {
		return map[string]any{"status": "unknown", "message_id": r.MessageID, "replay_permitted": false}, nil
	}
	if !existing {
		if len(r.Text) == 0 || len(r.Text) > 16384 || !utf8.ValidString(r.Text) || strings.TrimSpace(r.Text) == "" {
			return nil, errors.New("message requires 1-16384 text bytes")
		}
		current, e := workObserveEndpoint(ctx, link.Local)
		if e != nil || !communicationEndpointEqual(current, link.Local) {
			return nil, errors.New("source conversation changed")
		}
		if e = origin.revalidate(); e != nil {
			return nil, e
		}
		m := workWire{Version: 3, Operation: "send", LinkID: link.ID, Source: link.Local, Target: link.Peer, SourceRevision: link.Revision, TargetRevision: link.PeerRevision, Caller: caller, MessageID: r.MessageID, TextSHA256: communicationTextDigest(r.Text)}
		if r.file != nil {
			m.FileName, m.FileSize, m.FileSHA256 = r.file.name, int64(len(r.file.content)), r.file.sha256
		}
		m.Fingerprint = workFingerprint(m)
		// Refuse before claiming an outbound receipt if the complete encoded
		// request cannot fit the peer transport; a claimed ID would be burned.
		if r.file != nil {
			sized := m
			sized.Text = r.Text
			sized.FileContent = base64.StdEncoding.EncodeToString(r.file.content)
			sized.PaneSignature = strings.Repeat("x", 4096)
			if body, e := json.Marshal(sized); e != nil || len(body) > 128<<10 {
				return nil, errors.New("file and note exceed the 128 KiB Work transfer limit; shorten the note or send a smaller file; no request submitted")
			}
		}
		if link.Local.Kind == "pane" {
			m.PaneSignature, e = workSignPane(root, node, caller, r, origin, link)
			if e != nil {
				return nil, e
			}
		}
		receipt = workTransportReceipt{Version: 3, Node: node, RouteID: link.RouteID, RouteRevision: link.RouteRevision, PeerCertificateSHA256: link.PeerCertificateSHA256, Wire: m, Created: time.Now().UTC(), Result: map[string]any{"status": "outcome_unknown"}}
		err = communicationFanoutLocked(root, func() error {
			var e error
			if e = origin.revalidate(); e != nil {
				return e
			}
			binding, e = workPeerBinding(ctx, root, node, link)
			if e != nil {
				return e
			}
			var prior workTransportReceipt
			if e = communicationRead(path, &prior); e == nil {
				if !validWorkTransportReceipt(prior) || prior.Wire.Fingerprint != m.Fingerprint || prior.Wire.Caller != caller {
					return errors.New("message identity conflict")
				}
				receipt = prior
				return nil
			} else if !errors.Is(e, os.ErrNotExist) {
				return e
			}
			if e = communicationAtomic(path, receipt); e != nil {
				return e
			}
			claimed = true
			return nil
		})
		if err != nil {
			return nil, err
		}
		if !claimed {
			return workReceiptResult(receipt), nil
		}
	}
	wire := receipt.Wire
	if r.Operation == "send" {
		wire.Text = r.Text
		if r.file != nil {
			wire.FileContent = base64.StdEncoding.EncodeToString(r.file.content)
		}
	} else {
		wire.Operation = "receipt"
	}
	body, _ := json.Marshal(wire)
	data, postErr := remotePeerPost(ctx, root, node, binding, body)
	var reply map[string]any
	result := map[string]any{"status": "outcome_unknown"}
	if postErr == nil && json.Unmarshal(data, &reply) == nil && reply["message_id"] == wire.MessageID && reply["link_id"] == wire.LinkID && reply["fingerprint"] == wire.Fingerprint {
		result = communicationNativeOutcome(reply, nil)
		result["peer_authentication"] = "mutual_tls_pinned_node"
	} else {
		result["error"] = "peer result unavailable; query original receipt without resending"
	}
	err = communicationFanoutLocked(root, func() error {
		var current workTransportReceipt
		if e := communicationRead(path, &current); e != nil {
			return e
		}
		if !validWorkTransportReceipt(current) || current.Wire.Fingerprint != wire.Fingerprint {
			return errors.New("outbound receipt changed")
		}
		if !workOutcomeUnknown(current.Result) {
			receipt = current
			return nil
		}
		current.Result = result
		if e := communicationAtomic(path, current); e != nil {
			return e
		}
		receipt = current
		return nil
	})
	return workReceiptResult(receipt), err
}

func workReceive(ctx context.Context, root, node, peerCert string, m workWire) (map[string]any, error) {
	if m.Fingerprint == "" || m.Fingerprint != workFingerprint(m) || !remoteDigest(peerCert) || (m.Operation != "send" && m.Operation != "receipt" && m.Operation != "observe" && m.Operation != "repin") {
		return nil, errors.New("invalid Work peer request")
	}
	if m.Operation == "repin" {
		return workReceiveRepin(ctx, root, node, peerCert, m)
	}
	if m.Operation == "observe" {
		return workObserveOutbound(ctx, root, node, peerCert, m)
	}
	if m.Target.NodeID != node {
		return nil, errors.New("incorrect Work target node")
	}
	var link communicationTypedRemoteLink
	check := func() error {
		var e error
		link, e = communicationReadTypedAuthorizedLink(ctx, root, node, m.LinkID)
		if e != nil {
			return e
		}
		if link.PeerCertificateSHA256 != peerCert {
			return errors.New("unreviewed Work peer")
		}
		if !workLinkMatchesWire(link, m, true) {
			return errors.New("Work relationship or caller changed")
		}
		return nil
	}
	if err := communicationFanoutLocked(root, check); err != nil {
		return nil, err
	}
	path := workInboundPath(root, m.Source.NodeID, m.MessageID)
	var receipt workTransportReceipt
	existing := false
	err := communicationFanoutLocked(root, func() error {
		if e := check(); e != nil {
			return e
		}
		if e := communicationRead(path, &receipt); e == nil {
			if !validWorkTransportReceipt(receipt) || receipt.Wire.Fingerprint != m.Fingerprint {
				return errors.New("message identity conflict")
			}
			existing = true
			return nil
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if existing {
		return workReceiptResult(receipt), nil
	}
	if m.Operation == "receipt" {
		return map[string]any{"status": "unknown", "message_id": m.MessageID, "link_id": m.LinkID, "fingerprint": m.Fingerprint, "replay_permitted": false}, nil
	}
	if len(m.Text) == 0 || len(m.Text) > 16384 || !utf8.ValidString(m.Text) || strings.TrimSpace(m.Text) == "" || communicationTextDigest(m.Text) != m.TextSHA256 {
		return nil, errors.New("invalid Work text")
	}
	var fileContent []byte
	if m.FileSHA256 != "" {
		if fileContent, err = decodeWorkWireFile(m); err != nil {
			return nil, err
		}
	} else if m.FileContent != "" {
		return nil, errors.New("invalid Work file")
	}
	if m.Source.Kind == "pane" {
		typed := communicationTypedWorkMessage{Version: 2, LinkID: m.LinkID, Source: m.Source, Target: m.Target, SourceLinkRevision: m.SourceRevision, TargetLinkRevision: m.TargetRevision, CallerID: m.Caller, MessageID: m.MessageID, Text: m.Text, SourceSignature: m.PaneSignature}
		typed.Fingerprint = communicationTypedWorkFingerprint(typed)
		if err := communicationVerifyTypedWorkDelivery(link, node, peerCert, typed, time.Now().UTC()); err != nil {
			return nil, err
		}
	} else if m.PaneSignature != "" {
		return nil, errors.New("Work source cannot claim a pane signature")
	}
	sourceFresh := func(c context.Context) error { return workCheckPeerSource(c, root, node, link, m) }
	if err = sourceFresh(ctx); err != nil {
		return nil, err
	}
	target, err := workObserveEndpoint(ctx, link.Local)
	if err != nil || !communicationEndpointEqual(target, link.Local) {
		return nil, errors.New("target conversation changed")
	}
	claimed := false
	err = communicationFanoutLocked(root, func() error {
		if e := check(); e != nil {
			return e
		}
		if e := communicationRead(path, &receipt); e == nil {
			if !validWorkTransportReceipt(receipt) || receipt.Wire.Fingerprint != m.Fingerprint {
				return errors.New("message identity conflict")
			}
			return nil
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		saved := m
		saved.Text = ""
		saved.FileContent = ""
		receipt = workTransportReceipt{Version: 3, Node: node, RouteID: link.RouteID, RouteRevision: link.RouteRevision, PeerCertificateSHA256: peerCert, Wire: saved, Created: time.Now().UTC(), Result: map[string]any{"status": "outcome_unknown"}}
		if e := communicationAtomic(path, receipt); e != nil {
			return e
		}
		claimed = true
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !claimed {
		return workReceiptResult(receipt), nil
	}
	guard := func(c context.Context) error {
		if e := sourceFresh(c); e != nil {
			return e
		}
		return communicationFanoutLocked(root, check)
	}
	var result map[string]any
	var deliverErr error
	text := m.Text
	var fileResult map[string]any
	if fileContent != nil {
		saved, saveErr := saveWorkFile(m.Source.NodeID, m.MessageID, m.FileName, fileContent)
		if saveErr != nil {
			receipt.Result = map[string]any{"status": "not_sent", "error": "Work file could not be saved; not delivered", "peer_authentication": "mutual_tls_pinned_node"}
			err = communicationFanoutLocked(root, func() error { return communicationAtomic(path, receipt) })
			return workReceiptResult(receipt), err
		}
		text += workFileNotice(m, saved)
		fileResult = map[string]any{"name": m.FileName, "size": m.FileSize, "sha256": m.FileSHA256, "saved_path": saved, "verified": true}
	}
	if target.Kind == "work" {
		result, deliverErr = workRunNativeTarget(ctx, nativemsg.Host{}, nativemsg.Target{Kind: "work", Work: target.Work}, nil, &nativemsg.WorkMessage{Envelope: desktoproute.Envelope{ID: m.MessageID, Sender: "Relay pane " + m.Source.NodeID + "/" + m.Source.PaneID + " (session " + m.Source.SessionID + ")", Content: text}, Authorize: guard})
	} else {
		observed := workPaneObserve(target.PaneID)
		if observed.Endpoint == nil || observed.Provider != target.Provider || observed.SessionID != target.SessionID {
			deliverErr = errors.New("target conversation changed")
		} else if deliverErr = guard(ctx); deliverErr == nil {
			result, deliverErr = workPaneSend(target.PaneID, map[string]any{"operation": "send", "expected": observed.Endpoint, "messageID": m.MessageID, "targetPaneID": target.PaneID, "text": text, "submittingClientID": m.Caller, "source": map[string]any{"authentication": "source_work_host_attested", "hostID": m.Source.NodeID, "workThread": m.Source.Work.Thread, "linkID": m.LinkID, "nodeCertificateSHA256": peerCert}})
		}
	}
	receipt.Result = communicationNativeOutcome(result, deliverErr)
	receipt.Result["peer_authentication"] = "mutual_tls_pinned_node"
	if fileResult != nil {
		receipt.Result["file"] = fileResult
	}
	err = communicationFanoutLocked(root, func() error { return communicationAtomic(path, receipt) })
	return workReceiptResult(receipt), err
}

func workObserveOutbound(ctx context.Context, root, node, peerCert string, m workWire) (map[string]any, error) {
	// A challenge can only attest a durably claimed outgoing message. Reversing
	// this request must not let a peer invent a local sender or request a send.
	var link communicationTypedRemoteLink
	err := communicationFanoutLocked(root, func() error {
		var e error
		link, e = communicationReadTypedActiveLink(ctx, root, node, m.LinkID)
		if e != nil {
			return e
		}
		if m.Source.NodeID != node || link.PeerCertificateSHA256 != peerCert || !workLinkMatchesWire(link, m, false) {
			return errors.New("source relationship changed")
		}
		var receipt workTransportReceipt
		if e = communicationRead(workOutboundPath(root, m.MessageID), &receipt); e != nil {
			return e
		}
		if !validWorkTransportReceipt(receipt) || receipt.Wire.Fingerprint != m.Fingerprint {
			return errors.New("source message unavailable")
		}
		var policy communicationPolicy
		if e = communicationRead(communicationPolicyPath(root), &policy); e != nil {
			return e
		}
		if e = communicationValidatePolicy(policy); e != nil {
			return e
		}
		if m.Caller == "legacy-unattributed" {
			if policy.LegacyPaused {
				return errors.New("source caller paused")
			}
		} else {
			found := false
			for _, c := range policy.Callers {
				if c.ID == m.Caller && !c.Paused {
					found = true
				}
			}
			if !found {
				return errors.New("source caller unavailable")
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	source, err := workObserveEndpoint(ctx, link.Local)
	if err != nil || !communicationEndpointEqual(source, link.Local) {
		return nil, errors.New("source conversation changed")
	}
	return map[string]any{"message_id": m.MessageID, "link_id": m.LinkID, "fingerprint": m.Fingerprint, "source_current": true}, nil
}
func workCheckPeerSource(ctx context.Context, root, node string, link communicationTypedRemoteLink, m workWire) error {
	var binding CommunicationPeerBinding
	err := communicationFanoutLocked(root, func() error { var e error; binding, e = workPeerBinding(ctx, root, node, link); return e })
	if err != nil {
		return err
	}
	m.Operation = "observe"
	m.Text = ""
	m.FileContent = ""
	body, _ := json.Marshal(m)
	data, err := remotePeerPost(ctx, root, node, binding, body)
	if err != nil {
		return err
	}
	var reply map[string]any
	if json.Unmarshal(data, &reply) != nil || reply["message_id"] != m.MessageID || reply["link_id"] != m.LinkID || reply["fingerprint"] != m.Fingerprint || reply["source_current"] != true {
		return errors.New("source freshness unavailable")
	}
	return communicationFanoutLocked(root, func() error { _, e := workPeerBinding(ctx, root, node, link); return e })
}

func handleWorkWire(w http.ResponseWriter, r *http.Request, root, node, peerCert string, data []byte) {
	var m workWire
	if communicationStrictWorkJSONLimit(data, &m, 128<<10) != nil {
		http.Error(w, "invalid Work request", http.StatusBadRequest)
		return
	}
	result, err := workReceive(r.Context(), root, node, peerCert, m)
	if err != nil {
		http.Error(w, "Work request rejected; reconcile original receipt", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

// Keep the transport body small and reject duplicate keys through the same
// strict parser as local Work requests. The legacy v1 path is unchanged.
func workWireVersion(data []byte) bool {
	var header struct {
		Version int `json:"version"`
	}
	return json.Unmarshal(data, &header) == nil && header.Version == 3 && bytes.Contains(data, []byte(`"version"`))
}

var workObserveEndpoint = observeWorkEndpoint
var workPaneObserve = communicationObserve
var workPaneSend = communicationNative
var workRunNativeTarget = nativemsg.RunTarget
var workSignPane = func(root, node, caller string, r WorkRequest, origin workRequestOrigin, link communicationTypedRemoteLink) (string, error) {
	request, e := workReconcilePaneActor(CommunicationRequest{Operation: "remote_send", SourcePaneID: origin.pane, ActorPaneID: origin.pane, MessageID: r.MessageID, Text: r.Text, ClientID: caller, ClientToken: r.ClientToken}, os.Getppid())
	if e != nil {
		return "", e
	}
	var signature string
	e = communicationFanoutLocked(root, func() error {
		var signErr error
		signature, signErr = communicationSignWork(root, node, request, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, defaultCommunicationSigningDeps(root, node))
		return signErr
	})
	return signature, e
}

func workOutcomeUnknown(result map[string]any) bool {
	s := fmtRemoteStatus(result)
	return s == "outcome_unknown" || s == "unknown"
}

var workReconcilePaneActor = ReconcileCommunicationActor
