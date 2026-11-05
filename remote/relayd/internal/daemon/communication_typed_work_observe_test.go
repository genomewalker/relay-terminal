package daemon

import (
	"context"
	"strings"
	"testing"
)

func typedWorkObservationFixture(t *testing.T) (string, communicationTypedRemoteLink, communicationTypedRemoteLink, communicationTypedWorkMessage, communicationSigningDeps) {
	t.Helper()
	root, sourceLink, request, d := typedWorkSendFixture(t)
	msg, _, claimed, err := communicationClaimTypedWork(context.Background(), root, signerNode, sourceLink.ID, sourceLink.Revision, request, d)
	if err != nil || !claimed {
		t.Fatal("source claim unavailable", err)
	}
	_, sourceCert, err := d.keys.HostKey()
	if err != nil {
		t.Fatal(err)
	}
	targetLink := communicationTypedRemoteLink{Version: 2, ID: sourceLink.ID, Local: sourceLink.Peer, Peer: sourceLink.Local, RouteID: "route-target", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(sourceCert), AllowedPeerCallers: []string{msg.CallerID}, PeerRevision: sourceLink.Revision, Revision: sourceLink.PeerRevision, CreatedAt: d.now(), UpdatedAt: d.now()}
	return root, sourceLink, targetLink, msg, d
}

func TestTypedWorkSourceObservationBindsNonceClaimAndIncarnation(t *testing.T) {
	root, sourceLink, targetLink, msg, d := typedWorkObservationFixture(t)
	nonce := strings.Repeat("b", 64)
	observation, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d)
	if err != nil {
		t.Fatal(err)
	}
	if err := communicationVerifyTypedWorkObservation(observation, nonce, targetLink, msg, d.now()); err != nil {
		t.Fatal(err)
	}
	if err := communicationVerifyTypedWorkObservation(observation, strings.Repeat("c", 64), targetLink, msg, d.now()); err == nil {
		t.Fatal("wrong nonce accepted")
	}
	if err := communicationVerifyTypedWorkObservation(observation, nonce, targetLink, msg, d.now().Add(communicationWorkObservationTTL)); err == nil {
		t.Fatal("expired observation accepted")
	}
	altered := msg
	altered.Text = "different"
	altered.Fingerprint = communicationTypedWorkFingerprint(altered)
	if err := communicationVerifyTypedWorkObservation(observation, nonce, targetLink, altered, d.now()); err == nil {
		t.Fatal("changed payload accepted")
	}
	original := d.observe
	observations := 0
	d.observe = func(pane string) communicationMember { observations++; return original(pane) }
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, strings.Repeat("0", 64), nonce, msg, d); err == nil || observations != 0 {
		t.Fatal("different peer reached source observation", err, observations)
	}
	d.observe = original
	calls := 0
	d.observe = func(pane string) communicationMember {
		calls++
		v := original(pane)
		if calls > 1 {
			v.Start = "changed"
		}
		return v
	}
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d); err == nil {
		t.Fatal("changed source after observation accepted")
	}

	calls = 0
	d.observe = func(pane string) communicationMember {
		calls++
		v := original(pane)
		if calls > 1 {
			v.Endpoint = map[string]any{"transport": "different"}
		}
		return v
	}
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d); err == nil {
		t.Fatal("changed native endpoint accepted")
	}
}

func TestTypedWorkSourceObservationRequiresClaimAndActiveCaller(t *testing.T) {
	root, sourceLink, _, msg, d := typedWorkObservationFixture(t)
	nonce := strings.Repeat("b", 64)
	var policy communicationPolicy
	if err := communicationRead(communicationPolicyPath(root), &policy); err != nil {
		t.Fatal(err)
	}
	policy.Callers[0].Paused = true
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d); err == nil {
		t.Fatal("paused caller accepted")
	}
	policy.Callers[0].Paused = false
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	policy.Callers[0].ID = strings.ToUpper(policy.Callers[0].ID)
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d); err != nil {
		t.Fatal("canonical caller ID mismatch", err)
	}
	changed := msg
	changed.MessageID = targetFixturePane
	changed.Fingerprint = communicationTypedWorkFingerprint(changed)
	if _, err := communicationSignTypedWorkObservation(context.Background(), root, signerNode, sourceLink.PeerCertificateSHA256, nonce, changed, d); err == nil {
		t.Fatal("unclaimed message accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := communicationSignTypedWorkObservation(ctx, root, signerNode, sourceLink.PeerCertificateSHA256, nonce, msg, d); err == nil {
		t.Fatal("cancelled request accepted")
	}
}
