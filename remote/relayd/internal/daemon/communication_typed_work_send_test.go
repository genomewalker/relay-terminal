package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func typedWorkSendFixture(t *testing.T) (string, communicationTypedRemoteLink, CommunicationRequest, communicationSigningDeps) {
	t.Helper()
	root, _ := peerFixture(t, signerNode)
	_, targetCert := peerFixture(t, receiverNode)
	enrollPeer(t, root, signerNode, receiverNode, "127.0.0.1:1", targetCert)
	cert, err := peerCertificate(targetCert, receiverNode)
	if err != nil {
		t.Fatal(err)
	}
	source := sourceFixture("codex_app_server_message")
	pane := communicationEndpoint{NodeID: signerNode, Kind: "pane", PaneID: sourceFixturePane, Provider: source.Provider, SessionID: source.SessionID}
	work := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}}
	now := time.Now().UTC()
	link := communicationTypedRemoteLink{Version: 2, ID: communicationEndpointPairID(pane, work), Local: pane, Peer: work, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(cert), AllowedPeerCallers: []string{"receiver"}, PeerRevision: 1, Revision: 1, CreatedAt: now, UpdatedAt: now}
	if err := communicationAtomic(remoteLinkPath(root, link.ID), link); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Fixture", TokenHash: hex.EncodeToString(hash[:])}}}); err != nil {
		t.Fatal(err)
	}
	d := defaultCommunicationSigningDeps(root, signerNode)
	d.observe = func(pane string) communicationMember {
		if pane != sourceFixturePane {
			return communicationMember{Unavailable: "wrong pane"}
		}
		return source
	}
	d.now = func() time.Time { return now }
	request := CommunicationRequest{Operation: "remote_send", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane, MessageID: signedMessage, Text: "private source message", ClientToken: remoteSenderToken, actorVerified: true}
	return root, link, request, d
}

func TestTypedWorkOutboundClaimBindsSourceAndNeverReplays(t *testing.T) {
	root, link, request, d := typedWorkSendFixture(t)
	wire, receipt, claimed, err := communicationClaimTypedWork(context.Background(), root, signerNode, link.ID, link.Revision, request, d)
	if err != nil || !claimed || wire.SourceSignature == "" || receipt["status"] != "outcome_unknown" {
		t.Fatal(wire, receipt, claimed, err)
	}
	_, cert, err := d.keys.HostKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationVerifyWorkMessage(wire.SourceSignature, []communicationTrustedNode{{NodeID: signerNode, CertificateSHA256: peerFingerprint(cert)}}, d.now(), wire.Source.NodeID, wire.Source.PaneID, wire.Source.Provider, wire.Source.SessionID, wire.Target.NodeID, wire.MessageID, wire.LinkID, wire.SourceLinkRevision, wire.TargetLinkRevision, []byte(wire.Text), *wire.Target.Work); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(remoteOutboundPath(root, request.MessageID))
	if err != nil || strings.Contains(string(data), request.Text) || strings.Contains(string(data), remoteSenderToken) || strings.Contains(string(data), wire.SourceSignature) {
		t.Fatal("sensitive content persisted", err)
	}
	again, result, claimed, err := communicationClaimTypedWork(context.Background(), root, signerNode, link.ID, link.Revision, request, d)
	if err != nil || claimed || again.SourceSignature != "" || result["status"] != "outcome_unknown" {
		t.Fatal("claim replayed", again, result, claimed, err)
	}
	changed := request
	changed.Text = "different content"
	if _, _, _, err := communicationClaimTypedWork(context.Background(), root, signerNode, link.ID, link.Revision, changed, d); err == nil {
		t.Fatal("same ID changed payload accepted")
	}
}

func TestTypedWorkOutboundRejectsUnverifiedOrChangedSource(t *testing.T) {
	root, link, request, d := typedWorkSendFixture(t)
	bad := request
	bad.actorVerified = false
	if _, _, _, err := communicationClaimTypedWork(context.Background(), root, signerNode, link.ID, link.Revision, bad, d); err == nil {
		t.Fatal("unverified actor accepted")
	}
	old := d.observe
	d.observe = func(pane string) communicationMember { v := old(pane); v.SessionID = targetFixturePane; return v }
	if _, _, _, err := communicationClaimTypedWork(context.Background(), root, signerNode, link.ID, link.Revision, request, d); err == nil {
		t.Fatal("changed source accepted")
	}
	if _, err := os.Stat(remoteOutboundPath(root, request.MessageID)); !os.IsNotExist(err) {
		t.Fatal("refusal wrote a claim", err)
	}
}
