package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
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
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(fixtureA, "node-a", request, desktopLinkNow()); err != nil {
		t.Fatal("request", err)
	}
	result, err := communicationDesktopLinkApprove(fixtureA, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"},
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
	a, _, _, _, hooks := requestFixture(t)
	start := time.Now().UTC()
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, start); err != nil {
		t.Fatal(err)
	}
	listing, err := communicationDesktopLinkList(a, "node-a", start.Add(time.Minute))
	if err != nil || len(listing["requests"].([]desktopLinkListing)) != 1 {
		t.Fatal("pending request not listed", listing, err)
	}
	late := start.Add(desktopLinkRequestTTL + time.Second)
	original := desktopLinkNow
	desktopLinkNow = func() time.Time { return late }
	defer func() { desktopLinkNow = original }()
	listing, err = communicationDesktopLinkList(a, "node-a", late)
	if err != nil || len(listing["requests"].([]desktopLinkListing)) != 0 {
		t.Fatal("expired request listed", listing, err)
	}
	if _, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"},
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

// A rejected request is gone: it cannot be approved, and it is not listed.
func TestDesktopLinkRequestRejectedIsGone(t *testing.T) {
	a, _, _, _, hooks := requestFixture(t)
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	id := desktopLinkRequestID(desktopAlias, testGroupB)
	if _, err := communicationDesktopLinkReject(a, CommunicationRequest{Operation: "route_desktop_link_reject", RequestID: id}); err != nil {
		t.Fatal("reject", err)
	}
	if _, err := communicationDesktopLinkReject(a, CommunicationRequest{Operation: "route_desktop_link_reject", RequestID: id, ClientToken: remoteSenderToken}); err == nil {
		t.Fatal("a client rejected a request")
	}
	if _, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"}, RequestID: id,
		SourcePaneID: desktopAlias, PaneID: testGroupB}, hooks); err == nil {
		t.Fatal("a rejected request was approved")
	}
	listing, _ := communicationDesktopLinkList(a, "node-a", time.Now().UTC())
	if len(listing["requests"].([]desktopLinkListing)) != 0 {
		t.Fatal("rejected request still listed")
	}
}

// Peer discovery refuses by name when no reviewed link supplies the pane's pin.
func TestDesktopLinkApprovalRefusesWithoutPeerPin(t *testing.T) {
	a, _, _, _, _, hooks := replyFixture(t)
	const unlinked = "00000000-0000-4000-8000-00000000f00d"
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: unlinked, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	_, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: directionalPairCallers(desktopAlias, unlinked),
		RequestID: desktopLinkRequestID(desktopAlias, unlinked), SourcePaneID: desktopAlias, PaneID: unlinked}, hooks)
	if err == nil || !strings.Contains(err.Error(), "does not pin its own certificate") {
		t.Fatal("approval of an unpinned signer was not refused by name", err)
	}
}

// Expired requests are pruned when a new request is written, not only on read.
func TestDesktopLinkRequestPrunesExpiredAtWrite(t *testing.T) {
	a, _, _, _, _, _ := replyFixture(t)
	start := time.Now().UTC()
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, start); err != nil {
		t.Fatal(err)
	}
	stale := desktopLinkRequestPath(a, desktopLinkRequestID(desktopAlias, testGroupB))
	// A second, later request for another pane: the first has expired by then.
	later := start.Add(desktopLinkRequestTTL + time.Minute)
	const other = "00000000-0000-4000-8000-00000000f00d"
	request.PaneID = other
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, later); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("expired request file kept after a new write")
	}
}

// The callers a link admits are approved explicitly: an approval without them,
// or with a different set, is refused; the listing shows the set it would admit.
func TestDesktopLinkApprovalNeedsTheExactCallers(t *testing.T) {
	a, _, _, _, hooks := requestFixture(t)
	id := desktopLinkRequestID(desktopAlias, testGroupB)
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", request, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	listing, _ := communicationDesktopLinkList(a, "node-a", time.Now().UTC())
	item := listing["requests"].([]desktopLinkListing)[0]
	if len(item.ProposedCallers) != 1 || item.ProposedCallers[0] != "receiver" {
		t.Fatal("listing does not show the callers the pair would admit", item)
	}
	base := CommunicationRequest{Operation: "route_desktop_link_approve", RequestID: id, SourcePaneID: desktopAlias, PaneID: testGroupB}
	for _, callers := range [][]string{nil, {"sender"}, {"receiver", "other"}} {
		attempt := base
		attempt.AllowedCallers = callers
		if _, err := communicationDesktopLinkApprove(a, "node-a", attempt, hooks); err == nil || !strings.Contains(err.Error(), "approve the exact callers") {
			t.Fatal("approval with unreviewed callers not refused by name", callers, err)
		}
	}
}

// A delivered reply is readable back by the desktop session it was delivered to,
// and only under the registration it was delivered under.
func TestDesktopInboxReadsRepliesOnlyUnderTheDeliveredRegistration(t *testing.T) {
	a, _, account, approved, calls, hooks := replyFixture(t)
	got, err := communicationReceiveRemote(t.Context(), a, "node-a", approved.PeerCertificateSHA256, paneMessage(approved, "97979797-9797-4979-8979-979797979797"), hooks)
	if err != nil || sendsTo(calls) == 0 {
		t.Fatal("reply not delivered", got, err)
	}
	read := CommunicationRequest{Operation: "desktop_inbox_read", SourcePaneID: desktopAlias, ActorPaneID: desktopAlias, actorVerified: true}
	reply, err := communicationDesktopInboxRead(a, read)
	if err != nil || len(reply["messages"].([]desktopInboxEntry)) != 1 || reply["messages"].([]desktopInboxEntry)[0].Text != "reply from the pane" {
		t.Fatal("desktop session cannot read its reply", reply, err)
	}
	if _, err := communicationDesktopInboxRead(a, CommunicationRequest{Operation: "desktop_inbox_read", SourcePaneID: desktopAlias, ActorPaneID: desktopAlias}); err == nil {
		t.Fatal("an unverified session read its inbox")
	}
	// Re-registered under another account: the old reply does not come with it.
	if _, err := communicationClaudeSessionOperation(a, CommunicationRequest{Operation: "route_claude_session_retire", TargetSessionID: desktopAlias}, time.Now); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	registerDesktop(t, a, other)
	reply, err = communicationDesktopInboxRead(a, read)
	if err != nil || len(reply["messages"].([]desktopInboxEntry)) != 0 {
		t.Fatal("reply from the old registration leaked to the new one", reply, err)
	}
	_ = account
}

// The inbox keeps a bounded, de-duplicated list.
func TestDesktopInboxIsBoundedAndDeduplicated(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 60; i++ {
		id := strings.Repeat("0", 8) + string(rune('a'+i%26)) + strings.Repeat("0", 3) + string(rune('a'+i/26))
		if err := appendDesktopInbox(root, desktopAlias, desktopInboxEntry{MessageID: id, Text: "x", AccountRoot: "/a"}); err != nil {
			t.Fatal(err)
		}
	}
	duplicate := desktopInboxEntry{MessageID: strings.Repeat("0", 8) + "a" + strings.Repeat("0", 3) + "a", Text: "x", AccountRoot: "/a"}
	if err := appendDesktopInbox(root, desktopAlias, duplicate); err != nil {
		t.Fatal(err)
	}
	var inbox desktopInbox
	if err := communicationRead(desktopInboxPath(root, desktopAlias), &inbox); err != nil {
		t.Fatal(err)
	}
	if len(inbox.Entries) > desktopInboxLimit {
		t.Fatal("inbox exceeds its bound", len(inbox.Entries))
	}
	before := len(inbox.Entries)
	if err := appendDesktopInbox(root, desktopAlias, duplicate); err != nil {
		t.Fatal(err)
	}
	if err := communicationRead(desktopInboxPath(root, desktopAlias), &inbox); err != nil || len(inbox.Entries) != before {
		t.Fatal("duplicate message recorded twice", len(inbox.Entries), before)
	}
}
