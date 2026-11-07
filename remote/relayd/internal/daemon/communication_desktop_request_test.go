package daemon

import (
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// requestFixture registers the desktop session and the remote pair, but makes
// no link. It returns the reviewed desktop link the owner would approve.
func requestFixture(t *testing.T) (a, b string, proposed CommunicationRemoteLink, paneCalls *atomic.Int32, hooks communicationGroupNative) {
	t.Helper()
	live := &atomic.Bool{}
	live.Store(true)
	_, account, _ := claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	fixtureA, fixtureB, fixtureRequest, _, calls := remoteSendFixture(t, false)
	// The request and approval read the registration from the node root they run in.
	registerDesktop(t, fixtureA, account)
	link, err := readRemoteLink(fixtureA, "node-a", fixtureRequest.LinkID)
	if err != nil {
		t.Fatal(err)
	}
	proposed = CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: desktopAlias, PeerPaneID: testGroupB, RouteID: link.RouteID, RouteRevision: link.RouteRevision,
		PeerCertificateSHA256: link.PeerCertificateSHA256, LocalConversation: communicationPinnedConversation{Provider: "claude", SessionID: desktopAlias},
		PeerConversation: communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	hooks = communicationGroupNative{observe: communicationObserve, send: communicationNative}
	return fixtureA, fixtureB, proposed, calls, hooks
}

func desktopRequest(root string, session string) error {
	_, err := communicationDesktopLinkRequestOp(root, CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: session,
		PaneID: testGroupB, PeerNodeID: "node-b", ClientToken: remoteSenderToken, ActorPaneID: session, actorVerified: true}, time.Now().UTC())
	return err
}

// The request is recorded but creates no link; the owner's approval does.
func TestDesktopLinkRequestIsPendingUntilApproved(t *testing.T) {
	a, b, proposed, paneCalls, hooks := requestFixture(t)
	root := a
	if err := desktopRequest(root, desktopAlias); err != nil {
		t.Fatal("request", err)
	}
	links, _ := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	for _, path := range links {
		var link CommunicationRemoteLink
		if communicationRead(path, &link) == nil && link.LocalPaneID == desktopAlias {
			t.Fatal("a request created a link", path)
		}
	}
	before := paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "91919191-9191-4919-8919-919191919191", Text: "too early", ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationSendRemote(root, "node-a", send, hooks); err == nil || paneCalls.Load() != before {
		t.Fatal("a pending request delivered a message", err)
	}
	// The approval is the owner's, and it must name exactly the requested pair.
	other := proposed
	other.PeerPaneID = desktopAlias
	if _, err := communicationDesktopLinkApprove(root, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"}, RequestID: desktopLinkRequestID(desktopAlias, testGroupB), RemoteLink: &other}, hooks); err == nil {
		t.Fatal("an approval for another pair was accepted")
	}
	if desktopLinksIn(root) != 0 {
		t.Fatal("a refused approval left a desktop session link")
	}
	// An approval that names a different pane than the request is refused, even
	// though the request itself is pending.
	if _, err := communicationDesktopLinkApprove(root, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"},
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: "00000000-0000-4000-8000-00000000f00d"}, hooks); err == nil {
		t.Fatal("an approval naming another pane was accepted")
	}
	if _, err := communicationDesktopLinkApprove(root, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"}, ClientToken: remoteSenderToken,
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: testGroupB, RemoteLink: &proposed}, hooks); err == nil {
		t.Fatal("a client approved its own request")
	}
	result, err := communicationDesktopLinkApprove(root, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"},
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: testGroupB, RemoteLink: &proposed}, hooks)
	if err != nil {
		t.Fatal("owner approval", err)
	}
	if result["desktop_request_id"] == nil {
		t.Fatal("approval did not name the request", result)
	}
	if _, err := os.Stat(desktopLinkRequestPath(root, desktopLinkRequestID(desktopAlias, testGroupB))); !os.IsNotExist(err) {
		t.Fatal("approved request still pending")
	}
	// The approved link lets the send through once the peer pins the reciprocal pair.
	linked := result["link"].(CommunicationRemoteLink)
	peerFiles, _ := filepath.Glob(filepath.Join(b, "remote-link-*.json"))
	var existingB CommunicationRemoteLink
	if len(peerFiles) != 1 || communicationRead(peerFiles[0], &existingB) != nil {
		t.Fatal("peer fixture link", peerFiles)
	}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "claude", SessionID: "target-conversation", Endpoint: map[string]any{"transport": "fixture"}}
	}}
	reciprocal := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: desktopAlias, RouteID: existingB.RouteID, RouteRevision: existingB.RouteRevision,
		PeerCertificateSHA256: existingB.PeerCertificateSHA256, LocalConversation: communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}, PeerConversation: linked.LocalConversation,
		PeerRevision: linked.Revision, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(b, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &reciprocal}, bhooks); err != nil {
		t.Fatal("reciprocal link", err)
	}
	send.MessageID, send.ExpectedRemoteLinkRevision = "92929292-9292-4929-8929-929292929292", linked.Revision
	if got, err := communicationSendRemote(root, "node-a", send, hooks); err != nil || got["status"] != "accepted" || paneCalls.Load() != before+1 {
		t.Fatal("approved link did not deliver", got, err)
	}
}

// A request from a session that is not verified, or not registered, is refused.
func TestDesktopLinkRequestNeedsVerifiedRegisteredSession(t *testing.T) {
	a, _, _, _, _ := requestFixture(t)
	unverified := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias}
	if _, err := communicationDesktopLinkRequestOp(a, unverified, time.Now().UTC()); err == nil {
		t.Fatal("an unverified sender made a request")
	}
	unregistered := "00000000-0000-4000-8000-00000000d00d"
	if _, err := communicationDesktopLinkRequestOp(a, CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: unregistered,
		PaneID: testGroupB, ActorPaneID: unregistered, actorVerified: true, ClientToken: remoteSenderToken}, time.Now().UTC()); err == nil {
		t.Fatal("an unregistered session made a request")
	}
	if _, err := communicationDesktopLinkRequestOp(a, CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias,
		PaneID: desktopAlias, ActorPaneID: desktopAlias, actorVerified: true, ClientToken: remoteSenderToken}, time.Now().UTC()); err == nil {
		t.Fatal("a session requested a link to itself")
	}
}

// desktopLinksIn counts saved route links whose local side is the desktop session.
func desktopLinksIn(root string) int {
	paths, _ := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	count := 0
	for _, path := range paths {
		var link CommunicationRemoteLink
		if communicationRead(path, &link) == nil && link.LocalPaneID == desktopAlias {
			count++
		}
	}
	return count
}
