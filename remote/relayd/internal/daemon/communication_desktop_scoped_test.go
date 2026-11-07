package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// scopedFixture runs two real relayd nodes over pinned mutual TLS, with no pane
// pair reviewed yet. The desktop session is registered on node-a (the Mac). When
// pinB is true, node-b pins node-a's host certificate for scope signing.
// node-a always pins its own certificate, which the approval needs to sign.
type scopedNodes struct {
	a, b      string
	calls     *claudeSessionCalls
	paneCalls *atomic.Int32
	hooksA    communicationGroupNative
	hooksB    communicationGroupNative
	certA     string
	certB     string
	serverB   string
	account   string
}

func scopedFixture(t *testing.T, pinB bool) scopedNodes {
	t.Helper()
	live := &atomic.Bool{}
	live.Store(true)
	_, account, calls := claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	a, certA := peerFixture(t, "node-a")
	b, certB := peerFixture(t, "node-b")
	registerDesktop(t, a, account)
	localB := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	paneCalls := &atomic.Int32{}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localB.Provider, SessionID: localB.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		paneCalls.Add(1)
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
	ahooks := communicationGroupNative{observe: communicationObserve, send: communicationNative}
	serve := func(root, node string, hooks communicationGroupNative) *httptest.Server {
		server := httptest.NewUnstartedServer(peerHandler(root, node, hooks))
		var err error
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
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(serverB.URL, "https://"), certB)
	enrollPeer(t, b, "node-b", "node-a", strings.TrimPrefix(serverA.URL, "https://"), certA)
	pinScopeSigner(t, a, "node-a", certA)
	sender := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(a), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Desktop", TokenHash: hex.EncodeToString(sender[:])}}}); err != nil {
		t.Fatal(err)
	}
	if pinB {
		pinScopeSigner(t, b, "node-a", certA)
	}
	return scopedNodes{a: a, b: b, calls: calls, paneCalls: paneCalls, hooksA: ahooks, hooksB: bhooks, certA: certA, certB: certB,
		serverB: strings.TrimPrefix(serverB.URL, "https://"), account: account}
}

func scopedRequest(t *testing.T, root string) {
	t.Helper()
	request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if _, err := communicationDesktopLinkRequestOp(root, "node-a", request, desktopLinkNow()); err != nil {
		t.Fatal("request", err)
	}
}

func scopedApprove(root string, pane string, callers []string, hooks communicationGroupNative) (map[string]any, error) {
	return communicationDesktopLinkApprove(root, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve",
		RequestID: desktopLinkRequestID(desktopAlias, testGroupB), SourcePaneID: desktopAlias, PaneID: pane, AllowedCallers: callers}, hooks)
}

// One Approve click: a per-pair scope signed by node-a for both hosts, one
// capability, and the pair established over the wire. The desktop session can
// then send to the pane through the approved pair.
func TestApprovalEstablishesThePairUnderItsOwnSignedScope(t *testing.T) {
	f := scopedFixture(t, true)
	scopedRequest(t, f.a)
	result, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA)
	if err != nil {
		t.Fatal("approve", err)
	}
	link := result["link"].(CommunicationRemoteLink)
	if link.DesktopAccountRoot != f.account || link.LocalPaneID != desktopAlias || link.PeerPaneID != testGroupB {
		t.Fatal("approved link does not pin the desktop session and pane", link)
	}
	peerFiles, _ := filepath.Glob(filepath.Join(f.b, "remote-link-*.json"))
	if len(peerFiles) != 1 {
		t.Fatal("peer did not establish its half", peerFiles)
	}
	before := f.paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "a7a7a7a7-a7a7-4a7a-8a7a-a7a7a7a7a7a7", ExpectedRemoteLinkRevision: link.Revision, Text: "after approval",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if got, err := communicationSendRemote(f.a, "node-a", send, f.hooksA); err != nil || got["status"] != "accepted" || f.paneCalls.Load() != before+1 {
		t.Fatal("approved pair did not deliver", got, err)
	}
	// The pair's scope is stored per pair on both hosts, and holds exactly the pair.
	if _, found, err := communicationScopePairLoad(f.a, "node-a", communicationScopeMember{NodeID: "node-a", PaneID: desktopAlias},
		communicationScopeMember{NodeID: "node-b", PaneID: testGroupB}); err != nil || !found {
		t.Fatal("per-pair scope not stored on the approving host", err)
	}
}

// Refusals that happen before any capability is minted.
func TestApprovalRefusesWrongPairRegistrationMissingPinAndPeerMismatch(t *testing.T) {
	t.Run("different pane", func(t *testing.T) {
		f := scopedFixture(t, true)
		scopedRequest(t, f.a)
		if _, err := scopedApprove(f.a, "00000000-0000-4000-8000-00000000f00d", directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err == nil {
			t.Fatal("approval for another pane accepted")
		}
		if n, _ := filepath.Glob(filepath.Join(f.a, "desktop-capability-*.json")); len(n) != 0 {
			t.Fatal("a capability was minted for another pane")
		}
	})
	t.Run("re-registered session", func(t *testing.T) {
		f := scopedFixture(t, true)
		scopedRequest(t, f.a)
		if _, err := communicationClaudeSessionOperation(f.a, CommunicationRequest{Operation: "route_claude_session_retire", TargetSessionID: desktopAlias}, time.Now); err != nil {
			t.Fatal(err)
		}
		registerDesktop(t, f.a, t.TempDir())
		if _, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err == nil {
			t.Fatal("approval for a re-registered session accepted")
		}
	})
	t.Run("several callers", func(t *testing.T) {
		f := scopedFixture(t, true)
		scopedRequest(t, f.a)
		if _, err := scopedApprove(f.a, testGroupB, []string{"receiver", "sender"}, f.hooksA); err == nil {
			t.Fatal("two callers approved for a new pair")
		}
	})
	t.Run("unpinned owner on this host", func(t *testing.T) {
		f := scopedFixture(t, true)
		if err := communicationAtomic(communicationTrustPath(f.a), communicationTrustSet{Version: 1}); err != nil {
			t.Fatal(err)
		}
		scopedRequest(t, f.a)
		if _, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err == nil || !strings.Contains(err.Error(), "does not pin its own certificate") {
			t.Fatal("approval without this host's scope pin not refused by name", err)
		}
	})
	t.Run("peer node not routed", func(t *testing.T) {
		f := scopedFixture(t, true)
		request := CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-c",
			ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
		if _, err := communicationDesktopLinkRequestOp(f.a, "node-a", request, desktopLinkNow()); err != nil {
			t.Fatal(err)
		}
		if _, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err == nil || !strings.Contains(err.Error(), "no active route") {
			t.Fatal("a host with no route was approved", err)
		}
	})
}

// A peer that does not pin this host's certificate for scopes refuses the pair,
// and nothing is established on either side. The capability is spent regardless.
func TestApprovalRefusedWhenPeerDoesNotPinTheScopeSigner(t *testing.T) {
	f := scopedFixture(t, false)
	scopedRequest(t, f.a)
	if _, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err == nil {
		t.Fatal("a peer without the signer pin accepted the pair")
	}
	if links, _ := filepath.Glob(filepath.Join(f.a, "remote-link-*.json")); len(links) != 0 {
		t.Fatal("a link was saved without the peer's confirmation")
	}
	caps, _ := filepath.Glob(filepath.Join(f.a, "desktop-capability-*.json"))
	if len(caps) != 1 {
		t.Fatal("expected one minted capability", caps)
	}
}

// A new pair's listing proposes its two directional callers, so the owner can
// approve it without a reviewed pane link.
func TestListingProposesDirectionalCallersForANewPair(t *testing.T) {
	f := scopedFixture(t, true)
	scopedRequest(t, f.a)
	listing, err := communicationDesktopLinkList(f.a, "node-a", desktopLinkNow())
	if err != nil {
		t.Fatal(err)
	}
	item := listing["requests"].([]desktopLinkListing)[0]
	if item.Refusal != "" || !sameCallerSet(item.ProposedCallers, directionalPairCallers(desktopAlias, testGroupB)) {
		t.Fatal("a new pair is not approvable from its listing", item)
	}
}

// After the pair is unlinked, the owner can approve it again: the retired half is
// replaced, the peer's half is still current, and the pair delivers again.
func TestRelinkAfterUnlinkIsAccepted(t *testing.T) {
	f := scopedFixture(t, true)
	scopedRequest(t, f.a)
	approved, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA)
	if err != nil {
		t.Fatal("first approve", err)
	}
	link := approved["link"].(CommunicationRemoteLink)
	if _, err := communicationRemoteLinkSet(f.a, "node-a", CommunicationRequest{Operation: "route_link_retire", LinkID: link.ID, RemoteLink: &link,
		ExpectedRemoteLinkRevision: link.Revision}, f.hooksA); err != nil {
		t.Fatal("unlink", err)
	}
	scopedRequest(t, f.a)
	again, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA)
	if err != nil {
		t.Fatal("re-approve after unlink refused", err)
	}
	relinked := again["link"].(CommunicationRemoteLink)
	before := f.paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "b3b3b3b3-b3b3-4b3b-8b3b-b3b3b3b3b3b3", ExpectedRemoteLinkRevision: relinked.Revision, Text: "relinked",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if got, err := communicationSendRemote(f.a, "node-a", send, f.hooksA); err != nil || got["status"] != "accepted" || f.paneCalls.Load() != before+1 {
		t.Fatal("relinked pair did not deliver", got, err)
	}
}
