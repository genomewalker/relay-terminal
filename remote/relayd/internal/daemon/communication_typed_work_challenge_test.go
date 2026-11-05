package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func TestTypedWorkChallengeUsesPinnedPeerTransport(t *testing.T) {
	sourceRoot, sourcePEM := peerFixture(t, signerNode)
	targetRoot, targetPEM := peerFixture(t, receiverNode)
	sourceCert, err := peerCertificate(sourcePEM, signerNode)
	if err != nil {
		t.Fatal(err)
	}
	targetCert, err := peerCertificate(targetPEM, receiverNode)
	if err != nil {
		t.Fatal(err)
	}
	observed := sourceFixture("codex_app_server_message")
	var changed atomic.Bool
	deps := defaultCommunicationSigningDeps(sourceRoot, signerNode)
	deps.observe = func(pane string) communicationMember {
		v := observed
		if pane != sourceFixturePane {
			return communicationMember{Unavailable: "wrong pane"}
		}
		if changed.Load() {
			v.Start = "changed"
		}
		return v
	}
	deps.now = time.Now
	server := httptest.NewUnstartedServer(communicationHandleTypedWorkChallenge(sourceRoot, signerNode, deps))
	server.TLS, err = peerServerTLS(sourceRoot, signerNode)
	if err != nil {
		t.Fatal(err)
	}
	server.StartTLS()
	defer server.Close()
	enrollPeer(t, sourceRoot, signerNode, receiverNode, "127.0.0.1:1", targetPEM)
	enrollPeer(t, targetRoot, receiverNode, signerNode, strings.TrimPrefix(server.URL, "https://"), sourcePEM)
	tokenHash := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(sourceRoot), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Fixture", TokenHash: hex.EncodeToString(tokenHash[:])}}}); err != nil {
		t.Fatal(err)
	}
	pane := communicationEndpoint{NodeID: signerNode, Kind: "pane", PaneID: sourceFixturePane, Provider: observed.Provider, SessionID: observed.SessionID}
	work := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}}
	id := communicationEndpointPairID(pane, work)
	now := time.Now().UTC()
	a := communicationTypedRemoteLink{Version: 2, ID: id, Local: pane, Peer: work, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(targetCert), AllowedPeerCallers: []string{"receiver"}, PeerRevision: 1, Revision: 1, CreatedAt: now, UpdatedAt: now}
	b := communicationTypedRemoteLink{Version: 2, ID: id, Local: work, Peer: pane, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(sourceCert), AllowedPeerCallers: []string{"sender"}, PeerRevision: 1, Revision: 1, CreatedAt: now, UpdatedAt: now}
	if err := communicationAtomic(remoteLinkPath(sourceRoot, id), a); err != nil {
		t.Fatal(err)
	}
	if err := communicationAtomic(remoteLinkPath(targetRoot, id), b); err != nil {
		t.Fatal(err)
	}
	request := CommunicationRequest{Operation: "remote_send", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane, MessageID: signedMessage, Text: "private fixture", ClientToken: remoteSenderToken, actorVerified: true}
	msg, _, claimed, err := communicationClaimTypedWork(context.Background(), sourceRoot, signerNode, id, 1, request, deps)
	if err != nil || !claimed {
		t.Fatal("source claim", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := communicationTypedWorkSourceFresh(ctx, targetRoot, receiverNode, msg); err != nil {
		t.Fatal("pinned challenge", err)
	}
	changed.Store(true)
	if err := communicationTypedWorkSourceFresh(ctx, targetRoot, receiverNode, msg); err == nil {
		t.Fatal("changed source accepted")
	}
}
