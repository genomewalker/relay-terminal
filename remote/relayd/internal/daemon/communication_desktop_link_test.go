package daemon

import (
	"path/filepath"
	"sync/atomic"
	"testing"
)

// desktopLinkFixture links the registered desktop session to the remote pane
// the way TestClaudeSessionEndpointRemoteLinkBothDirections does, and returns
// the two hosts, the desktop link and the pane send counter.
func desktopLinkFixture(t *testing.T) (a, b string, desktopLink CommunicationRemoteLink, paneCalls *atomic.Int32, live *atomic.Bool) {
	t.Helper()
	live = &atomic.Bool{}
	live.Store(true)
	_, account, _ := claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	fixtureA, fixtureB, fixtureRequest, _, calls := remoteSendFixture(t, false)
	fixtureR := fixtureRequest.LinkID
	desktopHooks := communicationGroupNative{observe: communicationObserve, send: communicationNative}
	peer := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	link, err := readRemoteLink(fixtureA, "node-a", fixtureR)
	if err != nil {
		t.Fatal(err)
	}
	proposed := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: desktopAlias, PeerPaneID: testGroupB, RouteID: link.RouteID, RouteRevision: link.RouteRevision,
		PeerCertificateSHA256: link.PeerCertificateSHA256, LocalConversation: communicationPinnedConversation{Provider: "claude", SessionID: desktopAlias},
		PeerConversation: peer, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	result, err := communicationRemoteLinkSet(fixtureA, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &proposed}, desktopHooks)
	if err != nil {
		t.Fatal("link the desktop session to the remote pane", err)
	}
	desktopLink = result["link"].(CommunicationRemoteLink)
	peerFiles, _ := filepath.Glob(filepath.Join(fixtureB, "remote-link-*.json"))
	var existingB CommunicationRemoteLink
	if len(peerFiles) != 1 || communicationRead(peerFiles[0], &existingB) != nil {
		t.Fatal("peer fixture link", peerFiles)
	}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: peer.Provider, SessionID: peer.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}}
	reciprocal := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: desktopAlias, RouteID: existingB.RouteID, RouteRevision: existingB.RouteRevision,
		PeerCertificateSHA256: existingB.PeerCertificateSHA256, LocalConversation: peer, PeerConversation: desktopLink.LocalConversation,
		PeerRevision: desktopLink.Revision, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(fixtureB, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &reciprocal}, bhooks); err != nil {
		t.Fatal("reciprocal link", err)
	}
	return fixtureA, fixtureB, desktopLink, calls, live
}

// A verified desktop session sends to its linked pane by naming the pane,
// without a link ID. The daemon resolves the one saved link for that pair.
func TestDesktopSessionSendResolvesItsSavedLink(t *testing.T) {
	a, _, desktopLink, paneCalls, _ := desktopLinkFixture(t)
	desktopHooks := communicationGroupNative{observe: communicationObserve, send: communicationNative}
	before := paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "44444444-4444-4444-8444-444444444444", ExpectedRemoteLinkRevision: desktopLink.Revision, Text: "by pane name",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	got, err := communicationSendRemote(a, "node-a", send, desktopHooks)
	if err != nil || got["status"] != "accepted" || paneCalls.Load() != before+1 {
		t.Fatal("desktop session send by pane name not delivered", got, err)
	}
}

// Without a verified actor, a link is never resolved from a claimed sender.
// A pane with no saved link to the session is refused, and nothing is sent.
func TestDesktopSessionSendRefusesClaimedOrUnlinkedSender(t *testing.T) {
	a, _, desktopLink, paneCalls, _ := desktopLinkFixture(t)
	desktopHooks := communicationGroupNative{observe: communicationObserve, send: communicationNative}
	before := paneCalls.Load()
	base := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "55555555-5555-4555-8555-555555555555", ExpectedRemoteLinkRevision: desktopLink.Revision, Text: "claimed",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias}
	if _, err := communicationSendRemote(a, "node-a", base, desktopHooks); err == nil || paneCalls.Load() != before {
		t.Fatal("unverified sender resolved a desktop link", err)
	}
	unlinked := base
	unlinked.MessageID, unlinked.PaneID, unlinked.actorVerified = "66666666-6666-4666-8666-666666666666", "767dc718-6476-4d81-8f96-5875f4bd8ed7", true
	if _, err := communicationSendRemote(a, "node-a", unlinked, desktopHooks); err == nil || paneCalls.Load() != before {
		t.Fatal("pane with no saved link to the session was reached", err)
	}
}
