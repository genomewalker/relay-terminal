package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// crossHostFixture runs two real relayd nodes over pinned mutual TLS. The
// desktop session is registered on node-a, and a pane lives on node-b. Node-a
// holds the reviewed pane pair the owner's approval discovers from, and the
// desktop session is approved for node-b's pane through the owner's approval.
func crossHostFixture(t *testing.T) (a, b string, calls *claudeSessionCalls, paneCalls *atomic.Int32, approved CommunicationRemoteLink) {
	t.Helper()
	live := &atomic.Bool{}
	live.Store(true)
	_, account, calls := claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	ac, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	bc, err := peerCertificate(bcert, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	registerDesktop(t, a, account)
	localA := communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}
	localB := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	paneCalls = &atomic.Int32{}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localB.Provider, SessionID: localB.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		paneCalls.Add(1)
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
	ahooks := communicationGroupNative{observe: func(pane string) communicationMember {
		if strings.EqualFold(pane, testGroupA) {
			return communicationMember{PaneID: pane, Provider: localA.Provider, SessionID: localA.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
		}
		return communicationObserve(pane)
	}, send: communicationNative}
	serve := func(root, node string, hooks communicationGroupNative) *httptest.Server {
		server := httptest.NewUnstartedServer(peerHandler(root, node, hooks))
		server.TLS, err = peerServerTLS(root, node)
		if err != nil {
			t.Fatal(err)
		}
		server.Config.ErrorLog = log.New(io.Discard, "", 0)
		server.StartTLS()
		t.Cleanup(server.Close)
		return server
	}
	serverA := serve(a, "node-a", ahooks)
	serverB := serve(b, "node-b", bhooks)
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(serverB.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", strings.TrimPrefix(serverA.URL, "https://"), acert)
	sender := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(a), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Desktop", TokenHash: hex.EncodeToString(sender[:])}}}); err != nil {
		t.Fatal(err)
	}
	reply := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(b), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(reply[:])}}}); err != nil {
		t.Fatal(err)
	}
	// The reviewed pane pair on node-a that the approval discovers the pane's route and pin from.
	pair := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: testGroupA, PeerPaneID: testGroupB, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(bc), LocalConversation: localA, PeerConversation: localB, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	if _, err := communicationRemoteLinkSet(a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &pair}, ahooks); err != nil {
		t.Fatal("pane pair", err)
	}
	// The owner approves the desktop session's request for node-b's pane.
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB,
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(a, request, time.Now().UTC()); err != nil {
		t.Fatal("request", err)
	}
	result, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve",
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: testGroupB,
		AllowedCallers: []string{"receiver"}}, ahooks)
	if err != nil {
		t.Fatal("approve", err)
	}
	approved = result["link"].(CommunicationRemoteLink)
	// Node-b pins the reciprocal pair: its pane and the desktop session.
	reciprocal := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: desktopAlias, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(ac), LocalConversation: localB, PeerConversation: approved.LocalConversation,
		PeerRevision: approved.Revision, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(b, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &reciprocal}, bhooks); err != nil {
		t.Fatal("reciprocal", err)
	}
	return a, b, calls, paneCalls, approved
}

// Desktop session -> remote pane, then the pane's reply -> desktop session,
// each over the pinned mutual-TLS wire between the two nodes.
func TestDesktopSessionAndRemotePaneExchangeOverTheWire(t *testing.T) {
	a, b, calls, paneCalls, approved := crossHostFixture(t)
	before := paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1", ExpectedRemoteLinkRevision: approved.Revision, Text: "hello from the desktop",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if got, err := communicationSendRemote(a, "node-a", send, communicationGroupNative{observe: communicationObserve, send: communicationNative}); err != nil || got["status"] != "accepted" || paneCalls.Load() != before+1 {
		t.Fatal("desktop message did not reach the remote pane", got, err)
	}
	sends := sendsTo(calls)
	reply := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: "b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2",
		Text: "reply from the pane", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	got, linked, err := communicationSendToDesktop(b, "node-b", reply, paneHooks())
	if !linked || err != nil || (got["status"] != "accepted" && got["status"] != "written_to_socket") {
		t.Fatalf("pane reply not sent over the wire: status=%v error=%v linked=%v err=%v", got["status"], got["error"], linked, err)
	}
	if sendsTo(calls) != sends+1 {
		t.Fatal("desktop session did not receive the reply")
	}
	inbox, err := communicationDesktopInboxRead(a, CommunicationRequest{Operation: "desktop_inbox_read", SourcePaneID: desktopAlias, ActorPaneID: desktopAlias, actorVerified: true})
	if err != nil || len(inbox["messages"].([]desktopInboxEntry)) != 1 || inbox["messages"].([]desktopInboxEntry)[0].MessageID != reply.MessageID {
		t.Fatal("reply not readable back by the desktop session", inbox, err)
	}
	delivered := calls.packets[len(calls.packets)-1]
	if delivered["operation"] != "send" || delivered["text"] != "reply from the pane" || calls.targets[len(calls.targets)-1].Claude.SessionID != desktopAlias {
		t.Fatal("reply delivered to the wrong place", delivered)
	}
}
