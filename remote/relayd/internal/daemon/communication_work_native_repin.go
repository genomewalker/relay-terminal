package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A re-pin on a route carried by the Relay host channel cannot be posted to
// the peer: the app carries it like a Work message. The Work host keeps one
// private record per link naming the pin generation the peer must learn. The
// carrier lists it beside pending messages, claims a freshly signed re-pin
// frame built from the current link, delivers it to the peer's relayd (which
// applies the same checks as the HTTPS receiver: pinned signer, same thread on
// the same node, unchanged revisions, monotonic generation) and settles the
// signed reply. The watcher reports the peer current only once a reply for the
// link's current generation has settled.

type workNativeRepin struct {
	Version           int       `json:"version"`
	LinkID            string    `json:"link_id"`
	PeerNodeID        string    `json:"peer_node_id"`
	MessageID         string    `json:"message_id"`
	PinGeneration     uint64    `json:"pin_generation"`
	Fingerprint       string    `json:"fingerprint,omitempty"`
	SettledGeneration uint64    `json:"settled_generation"`
	Settled           bool      `json:"settled"`
	Created           time.Time `json:"created"`
}

func workNativeRepinPath(root, linkID string) string {
	return filepath.Join(root, "work-native-repin-"+linkID+".json")
}

func newWorkNativeMessageID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32], nil
}

// workNativeRepinQueue is the host-channel half of workRepinPeer. It returns
// "current" when the peer has confirmed the link's current generation, and
// otherwise (re)queues the re-pin for the carrier and returns "queued".
func workNativeRepinQueue(root string, link communicationTypedRemoteLink) (string, error) {
	status := "queued"
	err := communicationFanoutLocked(root, func() error {
		var r workNativeRepin
		e := communicationRead(workNativeRepinPath(root, link.ID), &r)
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return e
		}
		if e == nil && r.Version == 1 && r.LinkID == link.ID {
			if r.Settled && r.SettledGeneration == link.PinGeneration {
				status = "current"
				return nil
			}
			if !r.Settled && r.PinGeneration == link.PinGeneration {
				return nil
			}
		}
		id, e := newWorkNativeMessageID()
		if e != nil {
			return e
		}
		return communicationAtomic(workNativeRepinPath(root, link.ID), workNativeRepin{Version: 1, LinkID: link.ID, PeerNodeID: link.Peer.NodeID,
			MessageID: id, PinGeneration: link.PinGeneration, Created: workNativeNow()})
	})
	return status, err
}

// workNativeRepinPending lists unsettled re-pins. Called under the lock.
func workNativeRepinPending(root string) ([]workNativeRepin, error) {
	paths, err := filepath.Glob(filepath.Join(root, "work-native-repin-*.json"))
	if err != nil {
		return nil, err
	}
	out := []workNativeRepin{}
	for _, path := range paths {
		var r workNativeRepin
		if communicationRead(path, &r) != nil || r.Version != 1 || r.Settled || workNativeRepinPath(root, r.LinkID) != path || !validSessionID.MatchString(r.MessageID) {
			continue
		}
		out = append(out, r)
	}
	return out, nil
}

// workNativeRepinByMessage finds the unsettled re-pin carrying id. Under the lock.
func workNativeRepinByMessage(root, id string) (workNativeRepin, bool, error) {
	pending, err := workNativeRepinPending(root)
	if err != nil {
		return workNativeRepin{}, false, err
	}
	for _, r := range pending {
		if r.MessageID == id {
			return r, true, nil
		}
	}
	return workNativeRepin{}, false, nil
}

// workNativeRepinWire builds the signed frame from the link as it is now; a
// record for an older generation is superseded rather than carried.
func workNativeRepinWire(ctx context.Context, root, node string, r workNativeRepin) (workWire, communicationTypedRemoteLink, error) {
	link, err := communicationReadTypedActiveLink(ctx, root, node, r.LinkID)
	if err != nil {
		return workWire{}, link, err
	}
	if link.Local.Kind != "work" || link.Local.Work == nil || link.Peer.NodeID != r.PeerNodeID {
		return workWire{}, link, errors.New("Work relationship changed")
	}
	if link.PinGeneration != r.PinGeneration {
		return workWire{}, link, errors.New("re-pin superseded by a newer pin generation")
	}
	if err := workNativeRouteBinding(root, node, link); err != nil {
		return workWire{}, link, err
	}
	m := workWire{Version: 3, Operation: "repin", LinkID: link.ID, Source: link.Local, Target: link.Peer, SourceRevision: link.Revision, TargetRevision: link.PeerRevision,
		PinGeneration: link.PinGeneration, Caller: workRepinCaller, MessageID: r.MessageID, TextSHA256: communicationTextDigest("")}
	m.Fingerprint = workFingerprint(m)
	if m.Fingerprint == "" {
		return workWire{}, link, errors.New("invalid re-pin request")
	}
	return m, link, nil
}

func workNativeRepinClaim(ctx context.Context, root, node string, r workNativeRepin) (map[string]any, error) {
	var m workWire
	var link communicationTypedRemoteLink
	err := communicationFanoutLocked(root, func() error {
		var e error
		if m, link, e = workNativeRepinWire(ctx, root, node, r); e != nil {
			return e
		}
		current, ok, e := workNativeRepinByMessage(root, r.MessageID)
		if e != nil || !ok {
			return errors.New("re-pin no longer pending")
		}
		current.Fingerprint = m.Fingerprint
		return communicationAtomic(workNativeRepinPath(root, r.LinkID), current)
	})
	if err != nil {
		return nil, err
	}
	// The re-pinned endpoint must still be the live conversation.
	if observed, e := workObserveEndpoint(ctx, link.Local); e != nil || !communicationEndpointEqual(observed, link.Local) {
		return nil, errors.New("Work conversation changed; re-pin not dispatched")
	}
	return workNativeEnvelopeResult(root, node, link, "repin", workNativeSend{Wire: m, SourceCurrentAt: workNativeNow()})
}

func workNativeRepinSettle(ctx context.Context, root, node string, r workNativeRepin, text string) (map[string]any, error) {
	status := ""
	err := communicationFanoutLocked(root, func() error {
		current, ok, e := workNativeRepinByMessage(root, r.MessageID)
		if e != nil || !ok {
			return errors.New("re-pin no longer pending")
		}
		link, e := communicationReadTypedActiveLink(ctx, root, node, current.LinkID)
		if e != nil {
			return e
		}
		payload, _, e := workNativeVerify(text, "reply", link.Peer.NodeID, link.PeerCertificateSHA256)
		if e != nil {
			return e
		}
		var reply workNativeReply
		if e := communicationStrictWorkJSONLimit(payload, &reply, workNativeWireLimit); e != nil {
			return errors.New("invalid Work reply")
		}
		if current.Fingerprint == "" || reply.MessageID != current.MessageID || reply.LinkID != current.LinkID || reply.Fingerprint != current.Fingerprint || reply.Result == nil {
			return errors.New("Work reply does not match this re-pin")
		}
		status, _ = reply.Result["status"].(string)
		if status != "repinned" && status != "current" {
			return errors.New("peer refused re-pin")
		}
		current.Settled, current.SettledGeneration = true, current.PinGeneration
		return communicationAtomic(workNativeRepinPath(root, current.LinkID), current)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "settled", "operation": "repin", "peer_status": status, "message_id": r.MessageID, "link_id": r.LinkID, "authority": "relayd"}, nil
}

// workNativeRepinDeliverable reports whether a verified frame is a re-pin the
// host channel may carry.
func workNativeRepinDeliverable(m workWire) bool {
	return m.Operation == "repin" && m.Caller == workRepinCaller && strings.TrimSpace(m.Text) == ""
}

// workNativeRepinStatus reports whether the queued re-pin for the link's
// current generation has settled, re-queuing it if the record went missing.
func workNativeRepinStatus(ctx context.Context, root, node, linkID string) (map[string]any, error) {
	link, err := communicationReadTypedActiveLink(ctx, root, node, linkID)
	if err != nil {
		return nil, err
	}
	status, err := workNativeRepinQueue(root, link)
	if err != nil {
		return nil, err
	}
	return map[string]any{"link_id": linkID, "local_changed": false, "peer_status": status, "authority": "relayd"}, nil
}

// workNativeRepinFor reports the unsettled re-pin carrying id, when id is not
// a pending message. Takes the lock.
func workNativeRepinFor(root, id string) (workNativeRepin, bool) {
	id = strings.ToLower(id)
	if !validSessionID.MatchString(id) {
		return workNativeRepin{}, false
	}
	if _, err := os.Lstat(workNativePendingPath(root, id)); err == nil {
		return workNativeRepin{}, false
	}
	var r workNativeRepin
	var ok bool
	_ = communicationFanoutLocked(root, func() error {
		var e error
		r, ok, e = workNativeRepinByMessage(root, id)
		return e
	})
	return r, ok
}
