package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// The pane answers under its own directional caller; the reply is delivered to
// the desktop session over the approved pair.
func TestPaneReplyUnderItsOwnCallerIsDelivered(t *testing.T) {
	f := scopedFixture(t, true)
	writeReplyCaller(t, f.b)
	scopedRequest(t, f.a)
	if _, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA); err != nil {
		t.Fatal("approve", err)
	}
	before := sendsTo(f.calls)
	reply := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: "d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1",
		Text: "the pane answers", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	got, linked, err := communicationSendToDesktop(f.b, "node-b", reply, paneHooks())
	if !linked || err != nil || sendsTo(f.calls) != before+1 {
		t.Fatal("the pane's reply under its own caller was not delivered", got, linked, err)
	}
}

// A reply under any other caller is refused before anything reaches the desktop.
// That includes the desktop's own caller used in the reply direction, and a
// plain label that the pair never admitted.
func TestPaneReplyUnderAnotherCallerIsRefused(t *testing.T) {
	f := scopedFixture(t, true)
	scopedRequest(t, f.a)
	approved, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA)
	if err != nil {
		t.Fatal("approve", err)
	}
	link := approved["link"].(CommunicationRemoteLink)
	for _, caller := range []string{"receiver", directionalDesktopCaller(desktopAlias), "sender"} {
		before := sendsTo(f.calls)
		message := paneMessage(link, "e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1")
		message.CallerID = caller
		message.Fingerprint = remoteMessageFingerprint(message)
		if _, err := communicationReceiveRemote(t.Context(), f.a, "node-a", link.PeerCertificateSHA256, message, f.hooksA); err == nil {
			t.Fatal("a reply under another caller was accepted", caller)
		}
		if sendsTo(f.calls) != before {
			t.Fatal("a refused reply reached the desktop session", caller)
		}
	}
}

// writeReplyCaller gives the pane's node a caller credential for the pane's own
// replies, as the pane's relay would present it.
func writeReplyCaller(t *testing.T, root string) {
	t.Helper()
	digest := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(digest[:])}}}); err != nil {
		t.Fatal(err)
	}
}
