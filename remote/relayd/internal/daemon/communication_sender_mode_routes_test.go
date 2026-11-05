package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// One test per route a cross-host Claude message can take. Each must deliver
// the sender's permission class as observed on the sending host, read from
// the process that runs the conversation, never from the request.

func parkedSender(member communicationMember) communicationMember {
	member.Endpoint = map[string]any{"bindingSource": "native_parked_job_kernel_owner", "socketPID": float64(5150),
		"transport": "native_peer_socket", "socketPath": "/tmp/sender.sock"}
	return member
}

func requireJobProcess(t *testing.T, calls *[]int) {
	t.Helper()
	if len(*calls) == 0 {
		t.Fatal("permission class was never observed")
	}
	for _, pid := range *calls {
		if pid != 5150 {
			t.Fatalf("permission class read from pid %d, not the conversation's process", pid)
		}
	}
}

// Same host: relayd delivers a kernel-verified sender directly.
func TestSenderModeRouteLocalRelayd(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	packet := communicationSourcePacket(verifiedSendFixture(), "node-1", parkedSender(sourceFixture("native_peer_socket")))
	if packet["authentication"] != "kernel_verified" || packet["permissionClass"] != "bypass" {
		t.Fatalf("packet = %v", packet)
	}
	requireJobProcess(t, calls)
}

// dandy -> Mac through the desktop: the sender host attests, the desktop
// forwards relayd's source dict verbatim to the recipient's adapter.
func TestSenderModeRouteDesktopAttested(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	f.member = parkedSender(f.member)
	result, err := communicationAttestConsume(f.root, consumeRequest(f.mint(t)), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	source := result["source"].(map[string]any)
	if source["authentication"] != "source_host_attested" || source["permissionClass"] != "bypass" {
		t.Fatalf("source = %v", source)
	}
	requireJobProcess(t, calls)
}

// Mac -> dandy through the desktop: the sender host signs, the recipient's
// relayd verifies and delivers.
func TestSenderModeRouteDesktopSigned(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	signer.member = parkedSender(signer.member)
	envelope := signer.sign(t, signRequest("hello"))
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps()); err != nil {
		t.Fatal(err)
	}
	if len(receiver.sent) != 1 || receiver.sent[0]["source"].(map[string]any)["permissionClass"] != "bypass" {
		t.Fatalf("delivered = %v", receiver.sent)
	}
	requireJobProcess(t, calls)
}

type peerRouteFixture struct {
	a, b    string
	request CommunicationRequest
	hooks   communicationGroupNative
	aHash   string
	mu      sync.Mutex
	sent    []map[string]any
}

// peerRouteFixture is the relayd-to-relayd route (relay_message_pane with
// authority relayd across hosts): two nodes, pinned mutual TLS, reviewed pair.
func newPeerRouteFixture(t *testing.T) *peerRouteFixture {
	t.Helper()
	f := &peerRouteFixture{}
	var acert, bcert string
	f.a, acert = peerFixture(t, "node-a")
	f.b, bcert = peerFixture(t, "node-b")
	ac, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	bc, err := peerCertificate(bcert, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	f.aHash = peerFingerprint(ac)
	localA := communicationPinnedConversation{Provider: "claude", SessionID: "source-conversation"}
	localB := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localB.Provider, SessionID: localB.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(_ string, packet map[string]any) (map[string]any, error) {
		f.mu.Lock()
		f.sent = append(f.sent, packet)
		f.mu.Unlock()
		return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied"}, nil
	}}
	server := httptest.NewUnstartedServer(peerHandler(f.b, "node-b", bhooks))
	if server.TLS, err = peerServerTLS(f.b, "node-b"); err != nil {
		t.Fatal(err)
	}
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	enrollPeer(t, f.a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	enrollPeer(t, f.b, "node-b", "node-a", "127.0.0.1:1", acert)
	digest := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(f.a), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Fixture", TokenHash: hex.EncodeToString(digest[:])}}}); err != nil {
		t.Fatal(err)
	}
	blink := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: targetFixturePane, PeerPaneID: sourceFixturePane, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(ac), LocalConversation: localB, PeerConversation: localA, PeerRevision: 1, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(f.b, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &blink}, bhooks); err != nil {
		t.Fatal(err)
	}
	f.hooks = communicationGroupNative{observe: func(pane string) communicationMember {
		return parkedSender(communicationMember{PaneID: pane, PID: 4242, Start: "fixture", Provider: localA.Provider, SessionID: localA.SessionID})
	}}
	alink := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: sourceFixturePane, PeerPaneID: targetFixturePane, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(bc), LocalConversation: localA, PeerConversation: localB, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	result, err := communicationRemoteLinkSet(f.a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &alink}, f.hooks)
	if err != nil {
		t.Fatal(err)
	}
	alink = result["link"].(CommunicationRemoteLink)
	f.request = CommunicationRequest{Operation: "remote_send", LinkID: alink.ID, SourcePaneID: sourceFixturePane, PaneID: targetFixturePane,
		PeerNodeID: "node-b", MessageID: signedMessage, ExpectedRemoteLinkRevision: 1, Text: "route fixture", ClientToken: remoteSenderToken,
		ActorPaneID: sourceFixturePane, actorVerified: true}
	return f
}

// relayd -> relayd: the sending node signs with its pinned peer identity and
// the recipient node verifies it against that same route before delivering.
func TestSenderModeRouteRelaydPeer(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	f := newPeerRouteFixture(t)
	result, err := communicationSendRemote(f.a, "node-a", f.request, f.hooks)
	if err != nil || result["status"] != "written_to_socket" || result["source_authentication"] != "source_signed" {
		t.Fatalf("result = %v (%v)", result, err)
	}
	if len(f.sent) != 1 {
		t.Fatalf("%d deliveries", len(f.sent))
	}
	source := f.sent[0]["source"].(map[string]any)
	if source["authentication"] != "source_signed" || source["permissionClass"] != "bypass" || source["hostID"] != "node-a" ||
		source["paneID"] != sourceFixturePane || source["sessionID"] != "source-conversation" {
		t.Fatalf("source = %v", source)
	}
	requireJobProcess(t, calls)
}

// An unverified sender, an older sender without a signature, or a signature
// for different content stays a claimed label with no permission class.
func TestSenderModeRouteRelaydPeerWithoutAValidSignatureStaysClaimed(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newPeerRouteFixture(t)
	f.request.actorVerified = false
	result, err := communicationSendRemote(f.a, "node-a", f.request, f.hooks)
	if err != nil || result["source_authentication"] != "claimed_pane_label" || len(f.sent) != 1 {
		t.Fatalf("result = %v (%v)", result, err)
	}
	if _, ok := f.sent[0]["source"].(map[string]any)["permissionClass"]; ok {
		t.Fatal("an unsigned peer message asserted a permission class")
	}
	message := communicationRemoteMessage{Operation: "send", SourceNodeID: "node-a", SourcePaneID: sourceFixturePane,
		TargetPaneID: targetFixturePane, MessageID: signedMessage, Text: "tampered",
		SourceConversation: communicationPinnedConversation{Provider: "claude", SessionID: "source-conversation"},
		SourceSignature: communicationRemoteSourceSignature(f.a, "node-a", CommunicationRequest{SourcePaneID: sourceFixturePane,
			ActorPaneID: sourceFixturePane, MessageID: signedMessage, Text: "route fixture", actorVerified: true}, targetFixturePane, f.hooks.observe)}
	if message.SourceSignature == "" {
		t.Fatal("fixture could not sign")
	}
	_, authentication, failure := communicationRemoteSourcePacket(message, strings.Repeat("0", 64), time.Now().UTC())
	if authentication != "claimed_pane_label" || failure == "" {
		t.Fatal("a signature from another node was accepted", authentication)
	}
	_, authentication, failure = communicationRemoteSourcePacket(message, f.aHash, time.Now().UTC())
	if authentication != "claimed_pane_label" || failure != "signed statement does not match this message" {
		t.Fatal("a signature for other text was accepted", authentication, failure)
	}
	message.Text = "route fixture"
	if packet, authentication, failure := communicationRemoteSourcePacket(message, f.aHash, time.Now().UTC()); authentication != "source_signed" ||
		failure != "" || packet["permissionClass"] != "bypass" {
		t.Fatal("the matching signature was not accepted", packet, authentication, failure)
	}
	before := remoteMessageFingerprint(message)
	message.SourceSignature = ""
	if remoteMessageFingerprint(message) != before {
		t.Fatal("the signature changed the message fingerprint; older peers would reject it")
	}
}
