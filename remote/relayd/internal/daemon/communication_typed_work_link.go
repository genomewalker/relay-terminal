package daemon

import (
	"context"
	"errors"
	"math"
	"os"
	"path/filepath"
	"time"
)

// communicationCreateTypedWorkLink saves an owner-selected relationship using
// the common remote-link registry. It is not registered as an RPC until local
// selection and peer-side reciprocal approval are wired. Replacing any pin
// requires a separate verified transition; this function never silently does so.
func communicationCreateTypedWorkLink(ctx context.Context, root, node string, actor CommunicationRequest, desired communicationTypedRemoteLink, acquireLocalFence func(context.Context, communicationEndpoint) (func() error, func(), error), now func() time.Time) (communicationTypedRemoteLink, error) {
	var empty communicationTypedRemoteLink
	if acquireLocalFence == nil || now == nil || actor.ClientToken != "" || actor.ActorPaneID != "" || desired.Local.NodeID != node || desired.ID != communicationEndpointPairID(desired.Local, desired.Peer) || desired.ID == "" || desired.Retired || desired.Revision != 1 || desired.PeerRevision == 0 {
		return empty, errors.New("owner-selected typed relationship required")
	}
	authorize := func() error {
		_, err := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"})
		return err
	}
	if err := communicationFanoutLocked(root, authorize); err != nil {
		return empty, err
	}
	checkLocal, releaseLocal, err := acquireLocalFence(ctx, desired.Local)
	if err != nil {
		return empty, err
	}
	if checkLocal == nil || releaseLocal == nil {
		if releaseLocal != nil {
			releaseLocal()
		}
		return empty, errors.New("local endpoint fence unavailable")
	}
	defer releaseLocal()
	if err := checkLocal(); err != nil {
		return empty, err
	}
	var saved communicationTypedRemoteLink
	err = communicationFanoutLocked(root, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := authorize(); err != nil {
			return err
		}
		if err := checkLocal(); err != nil {
			return err
		}
		route, _, cert, err := activePeerRoute(root, node, desired.RouteID)
		if err != nil || cert == nil || route.PeerNodeID != desired.Peer.NodeID || route.Revision != desired.RouteRevision || peerFingerprint(cert) != desired.PeerCertificateSHA256 {
			return errors.New("reviewed peer route changed")
		}
		path := remoteLinkPath(root, desired.ID)
		if existing, err := readTypedRemoteLink(root, node, desired.ID); err == nil {
			saved = existing
			if !validTypedRemoteLink(saved, node) || saved.Retired || saved.PeerRevision != desired.PeerRevision || saved.RouteID != desired.RouteID || saved.RouteRevision != desired.RouteRevision || saved.PeerCertificateSHA256 != desired.PeerCertificateSHA256 || !communicationEndpointEqual(saved.Local, desired.Local) || !communicationEndpointEqual(saved.Peer, desired.Peer) || !equalStrings(saved.AllowedPeerCallers, desired.AllowedPeerCallers) {
				return errors.New("relationship changed; verified transition required")
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		files, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
		if err != nil {
			return err
		}
		if len(files) >= 256 {
			return errors.New("remote pair limit reached")
		}
		stamp := now().UTC()
		if stamp.IsZero() {
			return errors.New("invalid relationship time")
		}
		saved = desired
		saved.CreatedAt = stamp
		saved.UpdatedAt = stamp
		if !validTypedRemoteLink(saved, node) {
			return errors.New("invalid typed relationship")
		}
		if err := communicationAtomic(path, saved); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "communication_remote_pair_saved", []map[string]string{{"link_id": saved.ID, "peer_node_id": saved.Peer.NodeID}}); err != nil {
			return errors.New("relationship outcome unknown; read current link")
		}
		return nil
	})
	if err != nil {
		return empty, err
	}
	if err := checkLocal(); err != nil {
		// A violated fence makes the committed outcome ambiguous. Best-effort
		// retirement prevents later use; failure still returns unknown and must
		// be reconciled. Never overwrite a concurrently changed revision.
		_ = communicationFanoutLocked(root, func() error {
			current, readErr := readTypedRemoteLink(root, node, saved.ID)
			if readErr != nil {
				return readErr
			}
			if current.Revision != saved.Revision || current.Revision == math.MaxUint64 {
				return errors.New("relationship revision changed")
			}
			current.Revision++
			current.Retired = true
			stamp := now().UTC()
			if stamp.Before(current.UpdatedAt) {
				stamp = current.UpdatedAt
			}
			current.UpdatedAt = stamp
			if err := communicationAtomic(remoteLinkPath(root, current.ID), current); err != nil {
				return err
			}
			return communicationEvent(root, node, "communication_remote_pair_retired", []map[string]string{{"link_id": current.ID, "peer_node_id": current.Peer.NodeID}})
		})
		return empty, errors.New("relationship outcome unknown; local identity changed")
	}
	return saved, nil
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
