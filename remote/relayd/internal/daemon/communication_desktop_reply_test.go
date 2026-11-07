package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

const replyToken = "reply-fixture-credential"

// replyFixture approves the desktop session's request for the remote pane, then
// pins the reciprocal pair on the peer. It returns both hosts, the account, the
// approved link and the desktop session's delivery counter.
func replyFixture(t *testing.T) (a, b, account string, approved CommunicationRemoteLink, calls *claudeSessionCalls, hooks communicationGroupNative) {
	t.Helper()
	live := &atomic.Bool{}
	live.Store(true)
	_, account, calls = claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	fixtureA, fixtureB, _, _, _ := remoteSendFixture(t, false)
	registerDesktop(t, fixtureA, account)
	hooks = communicationGroupNative{observe: communicationObserve, send: communicationNative}
	// The pane's node accepts the reply sender credential as caller "receiver".
	digest := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(fixtureB), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Reply", TokenHash: hex.EncodeToString(digest[:])}}}); err != nil {
		t.Fatal(err)
	}
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB,
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(fixtureA, request, desktopLinkNow()); err != nil {
		t.Fatal("request", err)
	}
	result, err := communicationDesktopLinkApprove(fixtureA, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve",
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: testGroupB}, hooks)
	if err != nil {
		t.Fatal("approve", err)
	}
	approved = result["link"].(CommunicationRemoteLink)
	peerFiles, _ := filepath.Glob(filepath.Join(fixtureB, "remote-link-*.json"))
	var existingB CommunicationRemoteLink
	if len(peerFiles) != 1 || communicationRead(peerFiles[0], &existingB) != nil {
		t.Fatal("peer fixture link", peerFiles)
	}
	reciprocal := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: desktopAlias, RouteID: existingB.RouteID, RouteRevision: existingB.RouteRevision,
		PeerCertificateSHA256: existingB.PeerCertificateSHA256, LocalConversation: communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"},
		PeerConversation: approved.LocalConversation, PeerRevision: approved.Revision, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(fixtureB, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &reciprocal}, paneHooks()); err != nil {
		t.Fatal("reciprocal link", err)
	}
	return fixtureA, fixtureB, account, approved, calls, hooks
}

// paneHooks observes the peer pane and its conversation as the peer node does.
func paneHooks() communicationGroupNative {
	return communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "claude", SessionID: "target-conversation", Endpoint: map[string]any{"transport": "fixture"}}
	}}
}

// paneMessage is the reply a pane sends its desktop session over the approved
// pair, as the receiving node reads it: the pinned pair and the pane's text.
func paneMessage(approved CommunicationRemoteLink, id string) communicationRemoteMessage {
	message := communicationRemoteMessage{Version: 1, Operation: "send", LinkID: approved.ID, SourceLinkRevision: approved.PeerRevision,
		TargetLinkRevision: approved.Revision, SourceNodeID: "node-b", TargetNodeID: "node-a", SourcePaneID: testGroupB, TargetPaneID: desktopAlias,
		CallerID: "receiver", SourceConversation: communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"},
		TargetConversation: approved.LocalConversation, MessageID: id, Text: "reply from the pane"}
	message.Fingerprint = remoteMessageFingerprint(message)
	return message
}

// A pane's reply reaches exactly the desktop session it is linked to, and the
// pane's own pinned pair is the one the node selects for it.
func TestPaneReplyDeliveredToTheLinkedDesktopSession(t *testing.T) {
	a, b, _, approved, calls, _ := replyFixture(t)
	before := sendsTo(calls)
	got, err := communicationReceiveRemote(t.Context(), a, "node-a", approved.PeerCertificateSHA256, paneMessage(approved, "93939393-9393-4939-8939-939393939393"), communicationGroupNative{observe: communicationObserve, send: communicationNative})
	if err != nil || sendsTo(calls) != before+1 || calls.targets[len(calls.targets)-1].Claude.SessionID != desktopAlias {
		t.Fatal("reply not delivered to the linked session", got, err)
	}
	// The pane-side selection finds the same pair on the peer node.
	request := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: "94949494-9494-4949-8949-949494949494",
		Text: "reply", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	if _, linked, _ := communicationSendToDesktop(b, "node-b", request, paneHooks()); !linked {
		t.Fatal("the pane's pinned pair was not selected")
	}
}

// Without a pinned pair to the target session, the reply is not routed, and
// nothing reaches any desktop session.
func TestPaneReplyRefusedWithoutPinnedPair(t *testing.T) {
	_, b, _, _, calls, _ := replyFixture(t)
	before := sendsTo(calls)
	request := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: "00000000-0000-4000-8000-00000000f00d",
		MessageID: "95959595-9595-4959-8959-959595959595", Text: "reply", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	if _, linked, _ := communicationSendToDesktop(b, "node-b", request, paneHooks()); linked || sendsTo(calls) != before {
		t.Fatal("reply routed without a pinned pair")
	}
	request.PaneID, request.actorVerified = desktopAlias, false
	if _, linked, _ := communicationSendToDesktop(b, "node-b", request, paneHooks()); linked || sendsTo(calls) != before {
		t.Fatal("unverified pane reply routed")
	}
}

// A desktop session that re-registered in another account receives nothing
// from the reply approved for its old registration.
func TestPaneReplyRefusedForReRegisteredSession(t *testing.T) {
	a, _, _, approved, calls, hooks := replyFixture(t)
	if _, err := communicationClaudeSessionOperation(a, CommunicationRequest{Operation: "route_claude_session_retire", TargetSessionID: desktopAlias}, time.Now); err != nil {
		t.Fatal("retire", err)
	}
	registerDesktop(t, a, t.TempDir())
	before := sendsTo(calls)
	got, err := communicationReceiveRemote(t.Context(), a, "node-a", approved.PeerCertificateSHA256, paneMessage(approved, "96969696-9696-4969-8969-969696969696"), hooks)
	if err == nil || sendsTo(calls) != before {
		t.Fatal("re-registered session received a reply", got, err)
	}
}

// A request expires after its TTL: it is not listed, and it cannot be approved.
func TestDesktopLinkRequestExpires(t *testing.T) {
	a, _, _, _, _, hooks := replyFixture(t)
	start := time.Now().UTC()
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB,
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, request, start); err != nil {
		t.Fatal(err)
	}
	listing, err := communicationDesktopLinkList(a, start.Add(time.Minute))
	if err != nil || len(listing["requests"].([]communicationDesktopLinkRequest)) != 1 {
		t.Fatal("pending request not listed", listing, err)
	}
	late := start.Add(desktopLinkRequestTTL + time.Second)
	original := desktopLinkNow
	desktopLinkNow = func() time.Time { return late }
	defer func() { desktopLinkNow = original }()
	listing, err = communicationDesktopLinkList(a, late)
	if err != nil || len(listing["requests"].([]communicationDesktopLinkRequest)) != 0 {
		t.Fatal("expired request listed", listing, err)
	}
	if _, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve",
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: testGroupB}, hooks); err == nil {
		t.Fatal("an expired request was approved")
	}
}

// sendsTo counts the message deliveries the desktop session received; its
// discovery probes are not deliveries.
func sendsTo(calls *claudeSessionCalls) int {
	count := 0
	for _, packet := range calls.packets {
		if packet["operation"] == "send" {
			count++
		}
	}
	return count
}
