package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func typedLinkFixture(t *testing.T) (string, *signingHostFixture, communicationTypedRemoteLink) {
	t.Helper()
	root, _ := peerFixture(t, receiverNode)
	source := newSigningHost(t, signerNode)
	enrollPeer(t, root, receiverNode, source.node, "127.0.0.1:1", source.pem)
	pane := communicationEndpoint{NodeID: source.node, Kind: "pane", PaneID: sourceFixturePane, Provider: source.member.Provider, SessionID: source.member.SessionID}
	target := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}}
	link := communicationTypedRemoteLink{Version: 2, ID: communicationEndpointPairID(pane, target), Local: target, Peer: pane, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(source.keys.cert), AllowedPeerCallers: []string{"caller"}, PeerRevision: 1, Revision: 1}
	return root, source, link
}

func TestTypedWorkLinkRequiresOwnerFenceAndPreservesV1List(t *testing.T) {
	root, h, desired := typedLinkFixture(t)
	ctx := context.Background()
	var held bool
	fence := func(_ context.Context, e communicationEndpoint) (func() error, func(), error) {
		if e.Kind != "work" {
			t.Fatal("wrong endpoint kind")
		}
		held = true
		return func() error {
			if !held {
				return errors.New("fence released")
			}
			return nil
		}, func() { held = false }, nil
	}
	if _, err := communicationCreateTypedWorkLink(ctx, root, receiverNode, CommunicationRequest{}, desired, nil, time.Now); err == nil {
		t.Fatal("missing fence accepted")
	}
	if _, err := communicationCreateTypedWorkLink(ctx, root, receiverNode, CommunicationRequest{ActorPaneID: sourceFixturePane}, desired, fence, time.Now); err == nil {
		t.Fatal("pane claimed owner administration")
	}
	got, err := communicationCreateTypedWorkLink(ctx, root, receiverNode, CommunicationRequest{}, desired, fence, func() time.Time { return h.clock })
	if err != nil || got.ID != desired.ID || held {
		t.Fatal(got, err, held)
	}
	again, err := communicationCreateTypedWorkLink(ctx, root, receiverNode, CommunicationRequest{}, desired, fence, func() time.Time { return h.clock })
	if err != nil || again.Revision != got.Revision {
		t.Fatal("idempotent set changed revision", again, err)
	}
	localPin := communicationPinnedConversation{Provider: "claude", SessionID: "local-conversation"}
	peerPin := communicationPinnedConversation{Provider: "codex", SessionID: "peer-conversation"}
	hooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localPin.Provider, SessionID: localPin.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}}
	legacy := CommunicationRemoteLink{PeerNodeID: desired.Peer.NodeID, LocalPaneID: testGroupB, PeerPaneID: testGroupA, RouteID: desired.RouteID, RouteRevision: desired.RouteRevision, PeerCertificateSHA256: desired.PeerCertificateSHA256, LocalConversation: localPin, PeerConversation: peerPin, PeerRevision: 1, AllowedPeerCallers: []string{"caller"}}
	if _, err := communicationRemoteLinkSet(root, receiverNode, CommunicationRequest{Operation: "route_link_set", RemoteLink: &legacy}, hooks); err != nil {
		t.Fatal("create v1 relationship", err)
	}
	listed, err := communicationRemoteLinkOperation(root, receiverNode, CommunicationRequest{Operation: "route_link_list"})
	if err != nil || len(listed["links"].([]CommunicationRemoteLink)) != 1 || len(listed["typed_links"].([]communicationTypedRemoteLink)) != 1 {
		t.Fatal("typed link broke v1 listing", listed, err)
	}
	changed := desired
	endpoint := *desired.Local.Work
	endpoint.Incarnation = "43:124"
	changed.Local.Work = &endpoint
	if _, err := communicationCreateTypedWorkLink(ctx, root, receiverNode, CommunicationRequest{}, changed, fence, time.Now); err == nil {
		t.Fatal("changed incarnation silently rebound")
	}
}

func TestTypedWorkLinkRejectsExpiredFenceBeforeCommit(t *testing.T) {
	root, _, desired := typedLinkFixture(t)
	checks := 0
	fence := func(context.Context, communicationEndpoint) (func() error, func(), error) {
		return func() error {
			checks++
			if checks > 1 {
				return errors.New("changed")
			}
			return nil
		}, func() {}, nil
	}
	if _, err := communicationCreateTypedWorkLink(context.Background(), root, receiverNode, CommunicationRequest{}, desired, fence, time.Now); err == nil {
		t.Fatal("changed endpoint accepted")
	}
	if _, err := readTypedRemoteLink(root, receiverNode, desired.ID); err == nil {
		t.Fatal("relationship persisted after failed fence")
	}
}

func TestTypedWorkLinkRetiresOnPostCommitFenceFailure(t *testing.T) {
	root, _, desired := typedLinkFixture(t)
	checks := 0
	fence := func(context.Context, communicationEndpoint) (func() error, func(), error) {
		return func() error {
			checks++
			if checks >= 3 {
				return errors.New("lost fence")
			}
			return nil
		}, func() {}, nil
	}
	if _, err := communicationCreateTypedWorkLink(context.Background(), root, receiverNode, CommunicationRequest{}, desired, fence, time.Now); err == nil {
		t.Fatal("ambiguous link reported success")
	}
	stored, err := readTypedRemoteLink(root, receiverNode, desired.ID)
	if err != nil || !stored.Retired || stored.Revision != 2 {
		t.Fatal("failed fence did not retire saved link", stored, err)
	}
	if _, err := communicationReadTypedAuthorizedLink(context.Background(), root, receiverNode, desired.ID); err == nil {
		t.Fatal("retired link remained authorized")
	}
}
