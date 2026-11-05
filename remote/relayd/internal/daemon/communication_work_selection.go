package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/nativemsg"
	"io"
	"os"
	"time"
)

// These are owner CLI operations, separate from provider-callable Work tools.
// Selection creates only the exact supplied reciprocal pair. Existing pins
// cannot be replaced or silently repaired through this operation.
func InspectWorkSelection(thread string, out io.Writer) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	endpoint, err := nativemsg.ObserveWork(ctx, thread)
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(communicationEndpoint{NodeID: currentCommunicationNodeID(), Kind: "work", Work: &endpoint})
}
func RunWorkLinkSelection(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(io.LimitReader(in, communicationEnvelopeLimit+1))
	if err != nil || len(data) > communicationEnvelopeLimit {
		return errors.New("invalid exact selection")
	}
	var desired communicationTypedRemoteLink
	if communicationStrictWorkJSON(data, &desired) != nil {
		return errors.New("invalid exact selection")
	}
	root, node := communicationRoot(), currentCommunicationNodeID()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	saved, err := selectWorkLink(ctx, root, node, desired)
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(saved)
}
func selectWorkLink(ctx context.Context, root, node string, desired communicationTypedRemoteLink) (communicationTypedRemoteLink, error) {
	var empty communicationTypedRemoteLink
	if desired.Local.NodeID != node || desired.Version != 2 || desired.Revision != 1 || desired.PeerRevision != 1 || desired.Retired || desired.ID != communicationEndpointPairID(desired.Local, desired.Peer) {
		return empty, errors.New("exact initial reciprocal selection required")
	}
	if err := communicationFanoutLocked(root, func() error {
		_, e := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"})
		return e
	}); err != nil {
		return empty, err
	}
	local, err := workObserveEndpoint(ctx, desired.Local)
	if err != nil || !communicationEndpointEqual(local, desired.Local) {
		return empty, errors.New("selected local conversation changed")
	}
	err = communicationFanoutLocked(root, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if _, e := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"}); e != nil {
			return e
		}
		route, _, cert, e := activePeerRoute(root, node, desired.RouteID)
		if e != nil || cert == nil || route.Revision != desired.RouteRevision || route.PeerNodeID != desired.Peer.NodeID || peerFingerprint(cert) != desired.PeerCertificateSHA256 {
			return errors.New("selected peer route changed")
		}
		stamp := time.Now().UTC()
		desired.CreatedAt = stamp
		desired.UpdatedAt = stamp
		if !validTypedRemoteLink(desired, node) {
			return errors.New("invalid typed selection")
		}
		current, e := readTypedRemoteLink(root, node, desired.ID)
		if e == nil {
			if !workLinkMatchesWire(current, workWire{LinkID: desired.ID, Source: desired.Local, Target: desired.Peer, SourceRevision: 1, TargetRevision: 1}, false) || current.RouteID != desired.RouteID || current.RouteRevision != desired.RouteRevision || current.PeerCertificateSHA256 != desired.PeerCertificateSHA256 || !equalStrings(current.AllowedPeerCallers, desired.AllowedPeerCallers) {
				return errors.New("existing relationship differs; no changes made")
			}
			desired = current
			return nil
		}
		if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		return communicationAtomic(remoteLinkPath(root, desired.ID), desired)
	})
	return desired, err
}
