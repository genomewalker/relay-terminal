package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func TestTypedRemoteEndpointIdentityAndBinding(t *testing.T) {
	pane := communicationEndpoint{NodeID: "source-node", Kind: "pane", PaneID: sourceFixturePane, Provider: "codex", SessionID: sourceFixture("codex_app_server_message").SessionID}
	work := communicationEndpoint{NodeID: "destination-node", Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: sourceFixturePane, Owner: "owner", Incarnation: "42:123"}}
	id := communicationEndpointPairID(pane, work)
	if id == "" || id != communicationEndpointPairID(work, pane) || pane.logicalKey() == work.logicalKey() {
		t.Fatal("typed pair identity invalid")
	}
	link := communicationTypedRemoteLink{Version: 2, ID: id, Local: work, Peer: pane, RouteID: "route-1", RouteRevision: 1, PeerCertificateSHA256: strings.Repeat("a", 64), AllowedPeerCallers: []string{"caller"}, PeerRevision: 1, Revision: 1, CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
	if !validTypedRemoteLink(link, work.NodeID) {
		t.Fatal("valid typed link rejected")
	}
	replacement := *work.Work
	replacement.Incarnation = "43:124"
	changed := work
	changed.Work = &replacement
	if communicationEndpointPairID(pane, changed) != id || changed.Work.Incarnation == work.Work.Incarnation {
		t.Fatal("logical pair or pinned incarnation was lost")
	}
	bad := link
	bad.Local.PaneID = sourceFixturePane
	if validTypedRemoteLink(bad, work.NodeID) {
		t.Fatal("mixed Work/pane endpoint accepted")
	}
	bad = link
	bad.AllowedPeerCallers = []string{"caller", "caller"}
	if validTypedRemoteLink(bad, work.NodeID) {
		t.Fatal("duplicate caller accepted")
	}
	bad = link
	bad.PeerCertificateSHA256 = ""
	if validTypedRemoteLink(bad, work.NodeID) {
		t.Fatal("unpinned peer accepted")
	}
}

func TestTypedWorkMessageBindsLinkCertificateSourceAndTarget(t *testing.T) {
	h := newSigningHost(t, signerNode)
	request := signRequest("payload")
	target := nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}
	pane := communicationEndpoint{NodeID: h.node, Kind: "pane", PaneID: request.SourcePaneID, Provider: h.member.Provider, SessionID: h.member.SessionID}
	work := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &target}
	link := communicationTypedRemoteLink{Version: 2, ID: communicationEndpointPairID(pane, work), Local: work, Peer: pane, RouteID: "route-1", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(h.keys.cert), AllowedPeerCallers: []string{request.ClientID}, PeerRevision: 3, Revision: 4, CreatedAt: h.clock, UpdatedAt: h.clock}
	proof, err := communicationSignWork(h.root, h.node, request, receiverNode, link.ID, 3, 4, target, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	msg := communicationTypedWorkMessage{Version: 2, LinkID: link.ID, Source: pane, Target: work, SourceLinkRevision: 3, TargetLinkRevision: 4, CallerID: request.ClientID, MessageID: request.MessageID, Text: request.Text, SourceSignature: proof}
	msg.Fingerprint = communicationTypedWorkFingerprint(msg)
	if err := communicationVerifyTypedWorkDelivery(link, receiverNode, link.PeerCertificateSHA256, msg, h.clock); err != nil {
		t.Fatal(err)
	}
	if err := communicationVerifyTypedWorkDelivery(link, receiverNode, strings.Repeat("b", 64), msg, h.clock); err == nil {
		t.Fatal("different peer certificate accepted")
	}
	tests := map[string]func(*communicationTypedWorkMessage){
		"message":         func(m *communicationTypedWorkMessage) { m.MessageID = targetFixturePane },
		"caller":          func(m *communicationTypedWorkMessage) { m.CallerID = "another" },
		"content":         func(m *communicationTypedWorkMessage) { m.Text = "changed" },
		"target revision": func(m *communicationTypedWorkMessage) { m.TargetLinkRevision++ },
		"source session":  func(m *communicationTypedWorkMessage) { m.Source.SessionID = targetFixturePane },
		"target owner":    func(m *communicationTypedWorkMessage) { x := *m.Target.Work; x.Owner = "other"; m.Target.Work = &x },
		"target incarnation": func(m *communicationTypedWorkMessage) {
			x := *m.Target.Work
			x.Incarnation = "43:124"
			m.Target.Work = &x
		},
	}
	for name, change := range tests {
		t.Run(name, func(t *testing.T) {
			bad := msg
			change(&bad)
			bad.Fingerprint = communicationTypedWorkFingerprint(bad)
			if err := communicationVerifyTypedWorkDelivery(link, receiverNode, link.PeerCertificateSHA256, bad, h.clock); err == nil {
				t.Fatal("substitution accepted")
			}
		})
	}
	// Even if an attacker rewrites both reviewed link and message metadata,
	// the original signed proof cannot move to the new link revision.
	revised := link
	revised.Revision++
	replay := msg
	replay.TargetLinkRevision++
	replay.Fingerprint = communicationTypedWorkFingerprint(replay)
	if err := communicationVerifyTypedWorkDelivery(revised, receiverNode, revised.PeerCertificateSHA256, replay, h.clock); err == nil {
		t.Fatal("old signature accepted under new link revision")
	}
	link.Retired = true
	if err := communicationVerifyTypedWorkDelivery(link, receiverNode, link.PeerCertificateSHA256, msg, h.clock); err == nil {
		t.Fatal("retired link accepted")
	}
}

func TestTypedWorkAuthorizedLinkRechecksRouteAndPolicy(t *testing.T) {
	root, _ := peerFixture(t, receiverNode)
	source := newSigningHost(t, signerNode)
	enrollPeer(t, root, receiverNode, source.node, "127.0.0.1:1", source.pem)
	pane := communicationEndpoint{NodeID: source.node, Kind: "pane", PaneID: sourceFixturePane, Provider: source.member.Provider, SessionID: source.member.SessionID}
	target := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}}
	link := communicationTypedRemoteLink{Version: 2, ID: communicationEndpointPairID(pane, target), Local: target, Peer: pane, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(source.keys.cert), AllowedPeerCallers: []string{"caller"}, PeerRevision: 1, Revision: 1, CreatedAt: source.clock, UpdatedAt: source.clock}
	if err := communicationAtomic(remoteLinkPath(root, link.ID), link); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationReadTypedAuthorizedLink(context.Background(), root, receiverNode, link.ID); err != nil {
		t.Fatal(err)
	}
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{LegacyPaused: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationReadTypedAuthorizedLink(context.Background(), root, receiverNode, link.ID); err == nil {
		t.Fatal("paused receive accepted")
	}
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationRouteOperation(root, receiverNode, CommunicationRequest{Operation: "route_retire", RouteID: "route", ExpectedRouteRevision: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationReadTypedAuthorizedLink(context.Background(), root, receiverNode, link.ID); err == nil {
		t.Fatal("retired route accepted")
	}
}
