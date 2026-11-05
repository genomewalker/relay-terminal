package daemon

// The typed Work sender uses the common peer route and outbound receipt
// namespace. This claim function is not registered with an MCP tool or network
// transport until source freshness, transition fencing and reconciliation are
// implemented. A claim alone never sends a message.
import (
	"context"
	"errors"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

type communicationTypedOutboundReceipt struct {
	Version               int            `json:"version"`
	NodeID                string         `json:"node_id"`
	LinkID                string         `json:"link_id"`
	RouteID               string         `json:"route_id"`
	RouteRevision         uint64         `json:"route_revision"`
	PeerCertificateSHA256 string         `json:"peer_certificate_sha256"`
	MessageID             string         `json:"message_id"`
	Fingerprint           string         `json:"fingerprint"`
	CreatedAt             time.Time      `json:"created_at"`
	Result                map[string]any `json:"result"`
}

// communicationClaimTypedWork is called only for a kernel-verified pane actor.
// The destination comes from an owner-reviewed link, never from caller text.
// It signs and persists one unknown claim before any transport is attempted.
func communicationClaimTypedWork(ctx context.Context, root, node, linkID string, expectedRevision uint64, r CommunicationRequest, d communicationSigningDeps) (communicationTypedWorkMessage, map[string]any, bool, error) {
	var empty communicationTypedWorkMessage
	if !communicationSourceVerified(r) || !canonicalRouteToken(node) || !remoteDigest(linkID) || expectedRevision == 0 ||
		!validSessionID.MatchString(r.SourcePaneID) || !validSessionID.MatchString(r.MessageID) || len(r.Text) == 0 || len(r.Text) > 16384 || !utf8.ValidString(r.Text) || strings.TrimSpace(r.Text) == "" || d.observe == nil || d.keys == nil || d.now == nil {
		return empty, nil, false, errors.New("verified source and exact typed relationship required")
	}
	r.Operation = "remote_send"
	var wire communicationTypedWorkMessage
	var receipt communicationTypedOutboundReceipt
	claimed := false
	err := communicationFanoutLocked(root, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		caller, err := communicationAuthorize(root, r)
		if err != nil {
			return err
		}
		link, err := communicationReadTypedActiveLink(ctx, root, node, linkID)
		if err != nil {
			return err
		}
		if link.Local.Kind != "pane" || link.Peer.Kind != "work" || link.Revision != expectedRevision || link.Local.PaneID != r.SourcePaneID {
			return errors.New("typed relationship changed")
		}
		observed := d.observe(r.SourcePaneID)
		if observed.Endpoint == nil || observed.Unavailable != "" || observed.Provider != link.Local.Provider || observed.SessionID != link.Local.SessionID || observed.PID <= 1 || observed.Start == "" {
			return errors.New("source conversation changed")
		}
		wire = communicationTypedWorkMessage{Version: 2, LinkID: link.ID, Source: link.Local, Target: link.Peer, SourceLinkRevision: link.Revision, TargetLinkRevision: link.PeerRevision, CallerID: caller, MessageID: r.MessageID, Text: r.Text}
		wire.Fingerprint = communicationTypedWorkFingerprint(wire)
		if wire.Fingerprint == "" {
			return errors.New("invalid typed message")
		}
		path := remoteOutboundPath(root, r.MessageID)
		if err := communicationRead(path, &receipt); err == nil {
			if receipt.Version != 2 || receipt.NodeID != node || receipt.LinkID != link.ID || receipt.MessageID != r.MessageID || receipt.Fingerprint != wire.Fingerprint || receipt.Result == nil {
				return errors.New("message identity conflicts with prior request")
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		r.ClientID = caller
		proof, err := communicationSignWork(root, node, r, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, d)
		if err != nil {
			return err
		}
		_, hostCert, err := d.keys.HostKey()
		if err != nil || hostCert == nil {
			return errors.New("source host identity unavailable")
		}
		checked, err := communicationVerifyWorkMessage(proof, []communicationTrustedNode{{NodeID: node, CertificateSHA256: peerFingerprint(hostCert)}}, d.now().UTC(),
			link.Local.NodeID, link.Local.PaneID, link.Local.Provider, link.Local.SessionID, link.Peer.NodeID, r.MessageID, link.ID, link.Revision, link.PeerRevision, []byte(r.Text), *link.Peer.Work)
		if err != nil || checked.Certificate.PID != observed.PID || checked.Certificate.Start != observed.Start {
			return errors.New("source changed during signing")
		}
		wire.SourceSignature = proof
		receipt = communicationTypedOutboundReceipt{Version: 2, NodeID: node, LinkID: link.ID, RouteID: link.RouteID, RouteRevision: link.RouteRevision, PeerCertificateSHA256: link.PeerCertificateSHA256, MessageID: r.MessageID, Fingerprint: wire.Fingerprint, CreatedAt: d.now().UTC(), Result: map[string]any{"status": "outcome_unknown", "message_id": r.MessageID, "authority": "relayd", "replay_permitted": false}}
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "remote_outbound_claimed", []map[string]string{{"message_id": r.MessageID, "link_id": link.ID, "peer_node_id": link.Peer.NodeID}}); err != nil {
			return err
		}
		claimed = true
		return nil
	})
	if err != nil {
		return empty, nil, false, err
	}
	if !claimed {
		return empty, receipt.Result, false, nil
	}
	return wire, receipt.Result, true, nil
}
