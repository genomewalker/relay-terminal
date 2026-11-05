package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

// A Work application restart gives the same conversation a new native owner
// and incarnation. Re-pinning is an owner operation on the Work host: it
// refreshes the exact native reference, re-observes the same thread through the
// native socket proof, updates only that endpoint's pins under the same link ID,
// and asks the reciprocal peer over the pinned mutual-TLS route to update its
// copy. Thread, nodes, route, certificate, callers and revisions never change.

const workRepinCaller = "work-owner-repin"

var workPrepareReference = desktoproute.PrepareSelectedWork

type workRepinAudit struct {
	Time   time.Time             `json:"time"`
	LinkID string                `json:"link_id"`
	Side   string                `json:"side"`
	Old    communicationEndpoint `json:"old"`
	New    communicationEndpoint `json:"new"`
	Peer   string                `json:"peer_certificate_sha256,omitempty"`
}

func appendWorkRepinAudit(root string, a workRepinAudit) error {
	data, err := json.Marshal(a)
	if err != nil {
		return err
	}
	f, err := OpenPrivateFile(filepath.Join(root, "work-repin-"+a.LinkID+".jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err = f.Write(append(data, '\n')); err == nil {
		err = f.Sync()
	}
	return err
}

func sameWorkSelection(a, b communicationEndpoint) bool {
	return a.Kind == "work" && b.Kind == "work" && a.Work != nil && b.Work != nil && a.NodeID == b.NodeID && a.Work.Thread == b.Work.Thread && b.Work.Valid()
}

// RunWorkRepin re-pins one link once, or with watch keeps it current.
func RunWorkRepin(linkID string, watch bool, out io.Writer) error {
	root, node := communicationRoot(), currentCommunicationNodeID()
	if !watch {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		result, err := repinWorkLink(ctx, root, node, linkID)
		if err != nil {
			return err
		}
		return json.NewEncoder(out).Encode(result)
	}
	encoder := json.NewEncoder(out)
	peerCurrent := false
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		stale, err := workLinkStale(ctx, root, node, linkID)
		if err == nil && (stale || !peerCurrent) {
			var result map[string]any
			result, err = repinWorkLink(ctx, root, node, linkID)
			if err == nil {
				peerCurrent = result["peer_status"] == "repinned" || result["peer_status"] == "current"
				if result["local_changed"] == true || result["peer_status"] == "repinned" {
					_ = encoder.Encode(result)
				}
			}
		}
		cancel()
		if err != nil {
			peerCurrent = false
			_ = encoder.Encode(map[string]any{"link_id": linkID, "time": time.Now().UTC(), "waiting": err.Error()})
		}
		time.Sleep(15 * time.Second)
	}
}

// workLinkStale observes the live conversation without changing anything.
func workLinkStale(ctx context.Context, root, node, linkID string) (bool, error) {
	link, err := communicationReadTypedActiveLink(ctx, root, node, linkID)
	if err != nil {
		return false, err
	}
	if link.Local.Kind != "work" || link.Local.Work == nil {
		return false, errors.New("re-pin runs on the Work host")
	}
	current, err := workObserveEndpoint(ctx, link.Local)
	if err != nil {
		return false, err
	}
	return !communicationEndpointEqual(current, link.Local), nil
}

func repinWorkLink(ctx context.Context, root, node, linkID string) (map[string]any, error) {
	if !remoteDigest(linkID) {
		return nil, errors.New("exact Work relationship required")
	}
	if err := communicationFanoutLocked(root, func() error {
		_, e := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"})
		return e
	}); err != nil {
		return nil, err
	}
	link, err := communicationReadTypedActiveLink(ctx, root, node, linkID)
	if err != nil {
		return nil, err
	}
	if link.Local.Kind != "work" || link.Local.Work == nil {
		return nil, errors.New("re-pin runs on the Work host")
	}
	if err = workPrepareReference(ctx, link.Local.Work.Thread); err != nil {
		return nil, errors.New("Work conversation unavailable; no changes made")
	}
	observed, err := workObserveEndpoint(ctx, link.Local)
	if err != nil || !sameWorkSelection(link.Local, observed) {
		return nil, errors.New("Work conversation identity not proven; no changes made")
	}
	old := link.Local
	changed := false
	err = communicationFanoutLocked(root, func() error {
		if _, e := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"}); e != nil {
			return e
		}
		current, e := communicationReadTypedActiveLink(ctx, root, node, linkID)
		if e != nil {
			return e
		}
		if !communicationEndpointEqual(current.Local, old) || !communicationEndpointEqual(current.Peer, link.Peer) || current.RouteID != link.RouteID || current.RouteRevision != link.RouteRevision || current.PeerCertificateSHA256 != link.PeerCertificateSHA256 || current.Revision != link.Revision || current.PeerRevision != link.PeerRevision {
			return errors.New("relationship changed during re-pin; no changes made")
		}
		if communicationEndpointEqual(current.Local, observed) {
			link = current
			return nil
		}
		current.Local = observed
		current.UpdatedAt = time.Now().UTC()
		if !validTypedRemoteLink(current, node) || current.ID != linkID {
			return errors.New("invalid re-pinned relationship")
		}
		if e = communicationAtomic(remoteLinkPath(root, linkID), current); e != nil {
			return e
		}
		link, changed = current, true
		return appendWorkRepinAudit(root, workRepinAudit{Time: current.UpdatedAt, LinkID: linkID, Side: "work_host", Old: old, New: observed})
	})
	if err != nil {
		return nil, err
	}
	result := map[string]any{"link_id": linkID, "local_changed": changed, "local_old": old.Work, "local_new": link.Local.Work, "authority": "relayd"}
	status, err := workRepinPeer(ctx, root, node, link)
	if err != nil {
		result["peer_status"] = "unconfirmed"
		result["peer_error"] = err.Error()
	} else {
		result["peer_status"] = status
	}
	return result, nil
}

func workRepinPeer(ctx context.Context, root, node string, link communicationTypedRemoteLink) (string, error) {
	var binding CommunicationPeerBinding
	if err := communicationFanoutLocked(root, func() error {
		var e error
		binding, e = workPeerBinding(ctx, root, node, link)
		return e
	}); err != nil {
		return "", err
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	m := workWire{Version: 3, Operation: "repin", LinkID: link.ID, Source: link.Local, Target: link.Peer, SourceRevision: link.Revision, TargetRevision: link.PeerRevision, Caller: workRepinCaller, MessageID: hex.EncodeToString(id[:]), TextSHA256: communicationTextDigest("")}
	m.Fingerprint = workFingerprint(m)
	if m.Fingerprint == "" {
		return "", errors.New("invalid re-pin request")
	}
	body, _ := json.Marshal(m)
	data, err := remotePeerPost(ctx, root, node, binding, body)
	if err != nil {
		return "", err
	}
	var reply map[string]any
	if json.Unmarshal(data, &reply) != nil || reply["message_id"] != m.MessageID || reply["link_id"] != m.LinkID || reply["fingerprint"] != m.Fingerprint {
		return "", errors.New("peer re-pin result unavailable")
	}
	status, _ := reply["status"].(string)
	if status != "repinned" && status != "current" {
		return "", errors.New("peer refused re-pin")
	}
	return status, nil
}

// workReceiveRepin accepts a new pin for the peer's own Work endpoint only from
// the pinned peer node, only for the same thread on the same node, and only
// when everything else about the relationship is unchanged.
func workReceiveRepin(ctx context.Context, root, node, peerCert string, m workWire) (map[string]any, error) {
	if m.Target.NodeID != node || m.Source.Kind != "work" || m.Source.Work == nil || !m.Source.Work.Valid() || m.Caller != workRepinCaller || m.Text != "" || m.FileSHA256 != "" || m.FileContent != "" || m.PaneSignature != "" {
		return nil, errors.New("invalid Work re-pin")
	}
	status := "current"
	err := communicationFanoutLocked(root, func() error {
		link, e := communicationReadTypedActiveLink(ctx, root, node, m.LinkID)
		if e != nil {
			return e
		}
		if link.PeerCertificateSHA256 != peerCert {
			return errors.New("unreviewed Work peer")
		}
		if !sameWorkSelection(link.Peer, m.Source) || !communicationEndpointEqual(link.Local, m.Target) || link.Revision != m.TargetRevision || link.PeerRevision != m.SourceRevision {
			return errors.New("Work re-pin does not match this relationship")
		}
		if communicationEndpointEqual(link.Peer, m.Source) {
			return nil
		}
		old := link.Peer
		link.Peer = m.Source
		link.UpdatedAt = time.Now().UTC()
		if !validTypedRemoteLink(link, node) || link.ID != m.LinkID {
			return errors.New("invalid re-pinned relationship")
		}
		if e = communicationAtomic(remoteLinkPath(root, link.ID), link); e != nil {
			return e
		}
		status = "repinned"
		return appendWorkRepinAudit(root, workRepinAudit{Time: link.UpdatedAt, LinkID: link.ID, Side: "peer", Old: old, New: m.Source, Peer: peerCert})
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": status, "message_id": m.MessageID, "link_id": m.LinkID, "fingerprint": m.Fingerprint, "replay_permitted": false, "authority": "relayd"}, nil
}
