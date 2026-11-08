package daemon

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

type communicationRemoteOutbound struct {
	Version               int                        `json:"version"`
	NodeID                string                     `json:"node_id"`
	RouteID               string                     `json:"route_id"`
	RouteRevision         uint64                     `json:"route_revision"`
	PeerCertificateSHA256 string                     `json:"peer_certificate_sha256"`
	Wire                  communicationRemoteMessage `json:"wire"`
	// SubmittingCaller is the caller label the request was authorized as. The wire
	// caller may be a directional name, so retries are matched on this label.
	SubmittingCaller string         `json:"submitting_caller,omitempty"`
	CreatedAt        time.Time      `json:"created_at"`
	PeerConfirmed    bool           `json:"peer_confirmed"`
	RequestFinished  bool           `json:"request_finished"`
	Result           map[string]any `json:"result"`
}

func remoteOutboundPath(root, id string) string {
	return filepath.Join(root, "remote-outbound-"+id+".json")
}
func validRemoteOutbound(receipt communicationRemoteOutbound, node string) bool {
	return receipt.Version == 1 && receipt.NodeID == node && receipt.Wire.SourceNodeID == node && receipt.Wire.Operation == "send" && receipt.Wire.Text == "" &&
		validRemoteMessage(receipt.Wire, receipt.Wire.TargetNodeID) && canonicalRouteToken(receipt.RouteID) && receipt.RouteRevision != 0 &&
		remoteDigest(receipt.PeerCertificateSHA256) && !receipt.CreatedAt.IsZero() && receipt.Result != nil
}
func remoteOutboundResult(receipt communicationRemoteOutbound) map[string]any {
	result := communicationNativeOutcome(receipt.Result, nil)
	result["message_id"], result["source_node_id"], result["source_pane_id"] = receipt.Wire.MessageID, receipt.NodeID, receipt.Wire.SourcePaneID
	result["target_node_id"], result["pane_id"], result["submitting_client_id"] = receipt.Wire.TargetNodeID, receipt.Wire.TargetPaneID, receipt.Wire.CallerID
	result["fingerprint"], result["link_id"], result["authority"] = receipt.Wire.Fingerprint, receipt.Wire.LinkID, "relayd"
	result["source_authentication"], result["desktop_required"], result["replay_permitted"] = "claimed_pane_label", false, false
	if receipt.Result["source_authentication"] == "source_signed" {
		result["source_authentication"] = "source_signed"
	}
	result["peer_authentication"] = "not_confirmed"
	if receipt.PeerConfirmed {
		result["peer_authentication"] = "mutual_tls_pinned_node"
		if receipt.Result["peer_authentication"] == workNativeAuth {
			result["peer_authentication"] = workNativeAuth
		}
	}
	result["request_finished"] = receipt.RequestFinished
	if state := remoteNativeFinalState(receipt); state != "" {
		result["carrier_state"] = state
	}
	return result
}
func remoteOutboundRequestMatches(receipt communicationRemoteOutbound, node, caller string, r CommunicationRequest) bool {
	ownerRead := r.Operation == "remote_receipt" && r.ClientToken == "" && r.ActorPaneID == ""
	// The kernel-proven sending pane reads its own message's receipt, whichever
	// caller label (token or pane) it sent under. It never resends.
	paneRead := r.Operation == "remote_receipt" && r.actorVerified && r.ActorPaneID != "" && strings.EqualFold(r.ActorPaneID, receipt.Wire.SourcePaneID)
	if !validRemoteOutbound(receipt, node) || receipt.Wire.MessageID != r.MessageID || (receiptCaller(receipt) != caller && !ownerRead && !paneRead) ||
		(r.ActorPaneID != "" && !strings.EqualFold(r.ActorPaneID, receipt.Wire.SourcePaneID)) ||
		(r.SourcePaneID != "" && r.SourcePaneID != receipt.Wire.SourcePaneID) || (r.PaneID != "" && r.PaneID != receipt.Wire.TargetPaneID) ||
		(r.LinkID != "" && r.LinkID != receipt.Wire.LinkID) || (r.PeerNodeID != "" && r.PeerNodeID != receipt.Wire.TargetNodeID) {
		return false
	}
	if r.Operation == "remote_receipt" {
		return true
	}
	wire := receipt.Wire
	wire.Text = r.Text
	return r.ExpectedRemoteLinkRevision == wire.SourceLinkRevision && remoteMessageFingerprint(wire) == receipt.Wire.Fingerprint
}
func remoteOutboundRoute(root, node string, receipt communicationRemoteOutbound) (CommunicationPeerBinding, error) {
	route, binding, cert, err := activePeerRoute(root, node, receipt.RouteID)
	if err != nil {
		return binding, err
	}
	if route.Revision != receipt.RouteRevision || route.PeerNodeID != receipt.Wire.TargetNodeID || peerFingerprint(cert) != receipt.PeerCertificateSHA256 {
		return binding, errors.New("reviewed outbound peer route changed")
	}
	return binding, nil
}

// Source-side durable claim precedes the only send request. A retry reads that
// claim; recovery transmits only a receipt query without the original text.
func communicationSendRemote(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	r.SourcePaneID, r.PaneID, r.MessageID = strings.ToLower(r.SourcePaneID), strings.ToLower(r.PaneID), strings.ToLower(r.MessageID)
	r.LinkID, r.PeerNodeID = strings.ToLower(r.LinkID), strings.ToLower(r.PeerNodeID)
	if !canonicalRouteToken(node) || !canonicalRouteToken(r.MessageID) || (r.Operation != "remote_send" && r.Operation != "remote_receipt") {
		return nil, errors.New("valid outbound message identity required")
	}
	if r.Operation == "remote_send" && (!canonicalRouteToken(r.SourcePaneID) || !canonicalRouteToken(r.PaneID) || (r.LinkID != "" && !remoteDigest(r.LinkID)) ||
		!utf8.ValidString(r.Text) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "") {
		return nil, errors.New("valid reviewed remote pair and 1-16384 text bytes required")
	}
	if r.Operation == "remote_receipt" && r.Text != "" {
		return nil, errors.New("receipt query cannot include original text")
	}
	path := remoteOutboundPath(root, r.MessageID)
	var receipt communicationRemoteOutbound
	var link CommunicationRemoteLink
	var caller string
	var establish *establishPlan
	existing := false
	err := communicationFanoutLocked(root, func() error {
		var err error
		caller, err = communicationAuthorize(root, r)
		if err != nil {
			return err
		}
		if r.Operation == "remote_send" && r.LinkID == "" {
			// A verified desktop session names its pane, not a link: resolve the one
			// saved route link that pairs them, before any receipt is read.
			linkID, revision, err := communicationDesktopRemoteLink(root, node, r)
			if err != nil {
				return err
			}
			// Resolved under the lock now, so the pinned revision is the current one.
			r.LinkID, r.ExpectedRemoteLinkRevision = linkID, revision
		}
		if err := communicationRead(path, &receipt); err == nil {
			if !remoteOutboundRequestMatches(receipt, node, caller, r) {
				return errors.New("outbound message identity or caller conflict")
			}
			existing = true
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if r.Operation == "remote_receipt" {
			return nil
		}
		link, err = readRemoteLink(root, node, r.LinkID)
		if errors.Is(err, os.ErrNotExist) {
			// Only an exact pair in the owner-signed scope on this host may be
			// established; every other missing link keeps the original error.
			if plan, ok := communicationEstablishPrepare(root, node, r, caller); ok {
				establish = plan
				return nil
			}
		}
		if err != nil {
			return err
		}
		if link.Retired || link.Revision != r.ExpectedRemoteLinkRevision || link.LocalPaneID != r.SourcePaneID || link.PeerPaneID != r.PaneID || (r.PeerNodeID != "" && link.PeerNodeID != r.PeerNodeID) {
			return errors.New("reviewed outbound remote pair changed")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if establish != nil {
		// The peer re-checks its own scope copy; any refusal leaves nothing
		// written here and no message claim exists, so no send is attempted.
		established, err := communicationEstablishRun(root, node, r, establish, hooks)
		if err != nil {
			return nil, err
		}
		link, r.ExpectedRemoteLinkRevision = established, established.Revision
	}
	if r.Operation == "remote_receipt" && !existing {
		return map[string]any{"status": "unknown", "replay_permitted": false, "authority": "relayd"}, nil
	}
	if existing && (r.Operation == "remote_send" || (fmtRemoteStatus(receipt.Result) != "outcome_unknown" && fmtRemoteStatus(receipt.Result) != "unknown")) {
		if remoteNativePendingFor(root, receipt.Wire.MessageID) {
			return remoteNativeQueuedResult(root, receipt), nil
		}
		return remoteOutboundResult(receipt), nil
	}
	var binding CommunicationPeerBinding
	wire := receipt.Wire
	if !existing {
		source := hooks.observe(r.SourcePaneID)
		// A kernel-verified sender signs this exact message on this node, so the
		// recipient can deliver its observed identity and permission class.
		signature := communicationRemoteSourceSignature(root, node, r, link.PeerPaneID, hooks.observe)
		claimed := false
		err = communicationFanoutLocked(root, func() error {
			identity, err := communicationAuthorize(root, r)
			if err != nil {
				return err
			}
			if identity != caller {
				return errors.New("submitting caller identity changed")
			}
			if err := communicationRead(path, &receipt); err == nil {
				if !remoteOutboundRequestMatches(receipt, node, caller, r) {
					return errors.New("outbound message identity conflict")
				}
				return nil
			} else if !errors.Is(err, os.ErrNotExist) {
				return err
			}
			current, err := readRemoteLink(root, node, link.ID)
			if err != nil {
				return err
			}
			if current.Retired || current.Revision != link.Revision || !communicationPinMatches(current.LocalConversation, source) {
				return errors.New("reviewed source conversation or pair changed")
			}
			if err := communicationGroupDispatchGuard(root, node, r, current.PeerNodeID, current.PeerPaneID); err != nil {
				return err
			}
			wire = communicationRemoteMessage{Version: 1, Operation: "send", LinkID: current.ID, SourceLinkRevision: current.Revision, TargetLinkRevision: current.PeerRevision,
				SourceNodeID: node, TargetNodeID: current.PeerNodeID, SourcePaneID: current.LocalPaneID, TargetPaneID: current.PeerPaneID,
				CallerID:           wireCallerIf(r, current, caller),
				SourceConversation: current.LocalConversation, TargetConversation: current.PeerConversation, MessageID: r.MessageID, Text: r.Text,
				SourceSignature: signature}
			wire.Fingerprint = remoteMessageFingerprint(wire)
			receipt = communicationRemoteOutbound{Version: 1, NodeID: node, SubmittingCaller: caller, RouteID: current.RouteID, RouteRevision: current.RouteRevision,
				PeerCertificateSHA256: current.PeerCertificateSHA256, Wire: wire, CreatedAt: time.Now().UTC(), Result: map[string]any{"status": "outcome_unknown"}}
			receipt.Wire.Text = ""
			binding, err = remoteOutboundRoute(root, node, receipt)
			if err != nil {
				return err
			}
			if binding.Endpoint == workNativeEndpoint {
				// The app's carrier takes it from here; the text waits in a private
				// pending record until the peer confirms.
				if err := remoteNativeQueue(root, wire, r.Text); err != nil {
					return err
				}
				receipt.Result = remoteNativeCarried(receipt.Result)
			}
			if err := communicationAtomic(path, receipt); err != nil {
				return err
			}
			if err := communicationEvent(root, node, "remote_outbound_claimed", []map[string]string{{"message_id": r.MessageID, "link_id": current.ID, "peer_node_id": current.PeerNodeID}}); err != nil {
				return err
			}
			claimed = true
			return nil
		})
		if err != nil {
			if receipt.Result != nil {
				return remoteOutboundResult(receipt), err
			}
			return nil, err
		}
		if !claimed {
			return remoteOutboundResult(receipt), nil
		}
		if binding.Endpoint == workNativeEndpoint {
			return remoteNativeQueuedResult(root, receipt), nil
		}
	} else {
		wire.Operation = "receipt"
		wire.Text = ""
		err = communicationFanoutLocked(root, func() error {
			if _, err := communicationAuthorize(root, r); err != nil {
				return err
			}
			var err error
			binding, err = remoteOutboundRoute(root, node, receipt)
			return err
		})
		if err != nil {
			return remoteOutboundResult(receipt), err
		}
		if binding.Endpoint == workNativeEndpoint {
			// The carrier settles this receipt; no peer request is made from here.
			return remoteNativeUnsettled(root, receipt), nil
		}
	}
	body, _ := json.Marshal(wire)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	data, postErr := remotePeerPost(ctx, root, node, binding, body)
	var reply map[string]any
	confirmed := false
	outcome := map[string]any{"status": "outcome_unknown"}
	if postErr == nil && json.Unmarshal(data, &reply) == nil && reply["message_id"] == wire.MessageID && reply["source_node_id"] == node &&
		reply["source_pane_id"] == wire.SourcePaneID && reply["target_node_id"] == wire.TargetNodeID && reply["pane_id"] == wire.TargetPaneID &&
		reply["submitting_client_id"] == wire.CallerID && reply["fingerprint"] == wire.Fingerprint {
		confirmed = true
		outcome = communicationNativeOutcome(reply, nil)
		if reply["source_authentication"] == "source_signed" {
			outcome["source_authentication"] = "source_signed"
		}
	} else {
		outcome["error"] = "peer outcome unavailable; query the durable receipt without resending"
	}
	err = communicationFanoutLocked(root, func() error {
		var current communicationRemoteOutbound
		if err := communicationRead(path, &current); err != nil {
			return err
		}
		if !validRemoteOutbound(current, node) || current.Wire.Fingerprint != wire.Fingerprint || current.Wire.CallerID != wire.CallerID {
			return errors.New("outbound receipt changed during peer request")
		}
		// A failed/stale recovery query must not downgrade an outcome committed
		// by another receipt reader while this request was in flight.
		if (existing || fmtRemoteStatus(outcome) == "outcome_unknown" || fmtRemoteStatus(outcome) == "unknown") && (fmtRemoteStatus(current.Result) != "outcome_unknown" && fmtRemoteStatus(current.Result) != "unknown") {
			receipt = current
			return nil
		}
		current.Result, current.PeerConfirmed, current.RequestFinished = outcome, confirmed, true
		if err := communicationAtomic(path, current); err != nil {
			return err
		}
		receipt = current
		return communicationEvent(root, node, "remote_outbound_outcome", []map[string]string{{"message_id": wire.MessageID, "status": fmtRemoteStatus(outcome)}})
	})
	return remoteOutboundResult(receipt), err
}

// communicationRemoteSourceSignature signs a remote message for its exact
// target pane with this node's session certificate. A sender that is not
// kernel-verified, or a node without a signing identity, sends unsigned.
func communicationRemoteSourceSignature(root, node string, r CommunicationRequest, target string, observe func(string) communicationMember) string {
	if !communicationSourceVerified(r) {
		return ""
	}
	deps := defaultCommunicationSigningDeps(root, node)
	deps.observe = observe
	result, err := communicationSign(root, node, CommunicationRequest{Operation: "sign", SourcePaneID: r.SourcePaneID,
		ActorPaneID: r.ActorPaneID, PaneID: target, MessageID: r.MessageID, Text: r.Text, ClientID: r.ClientID, actorVerified: true}, deps)
	if err != nil {
		return ""
	}
	signature, _ := result["source_signature"].(string)
	return signature
}

func remotePeerPost(ctx context.Context, root, node string, binding CommunicationPeerBinding, body []byte) ([]byte, error) {
	if binding.Endpoint == workNativeEndpoint {
		return nil, errNativePeerRoute
	}
	if len(body) > 128<<10 {
		return nil, errors.New("remote request exceeds limit")
	}
	cert, err := validPeerBinding(binding, node)
	if err != nil {
		return nil, err
	}
	_, pair, err := peerIdentity(root, node)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, ServerName: binding.PeerNodeID + ".relay.invalid", RootCAs: pool, Certificates: []tls.Certificate{pair},
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !state.PeerCertificates[0].Equal(cert) {
				return errors.New("peer certificate pin mismatch")
			}
			return nil
		}},
		DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext, TLSHandshakeTimeout: 3 * time.Second, ResponseHeaderTimeout: 35 * time.Second,
		MaxResponseHeaderBytes: 8192, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("peer redirect rejected") }}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+binding.Endpoint+"/relay-peer/message", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return nil, errors.New("remote peer request unavailable or authentication failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errors.New("remote peer request rejected; receipt recovery required")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 128<<10+1))
	if err != nil || len(data) > 128<<10 {
		return nil, errors.New("invalid remote peer response")
	}
	return data, nil
}

// receiptCaller is the label a stored outbound request was authorized as; older
// receipts have no label of their own and carry it on the wire.
func receiptCaller(receipt communicationRemoteOutbound) string {
	if receipt.SubmittingCaller != "" {
		return receipt.SubmittingCaller
	}
	return receipt.Wire.CallerID
}

// wireCallerIf names the wire caller only for a kernel-verified local sender.
func wireCallerIf(r CommunicationRequest, link CommunicationRemoteLink, label string) string {
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, link.LocalPaneID) {
		return label
	}
	return wireCallerFor(link, link.LocalPaneID, label)
}
