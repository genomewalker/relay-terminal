package daemon

import (
	"context"
	"strings"
	"testing"
)

// 2026-11-12: ChatGPT restarted and every reply from dandy-07 panes to the
// Codex chat was refused until the owner re-pinned by hand; the queued reply
// was lost. The Work host now re-pins (same rules as --watch) when a carried
// send fails on a stale pin, and the sender re-addresses the queued message.
func TestWorkNativeRestartAutoRepinsAndDeliversTheQueuedReplyOnce(t *testing.T) {
	a, b, al, bl, _, workCalls := workNativeFixture(t)
	restart := workRestartFixture(t)
	restart(al.Local.Work.Owner, al.Local.Work.Incarnation, workTestThread, nil)
	ctx := context.Background()
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	got, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: testGroupID, Text: "pane reply", ClientToken: workTestToken}, pane)
	if err != nil || got["status"] != "outcome_unknown" {
		t.Fatal("queue", got, err)
	}
	oldFingerprint := got["fingerprint"]

	// The Work application restarts after the reply was queued.
	restart("owner-after-restart", "77:456", workTestThread, nil)
	_, envelope := workNativeClaimEnvelope(t, b, "node-b", testGroupID)
	_, err = workNativeOp(a, "node-a", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
	if err == nil || !strings.HasPrefix(err.Error(), workTargetRepinned) || workCalls.Load() != 0 {
		t.Fatal("stale delivery must be refused with the re-pin note", err, workCalls.Load())
	}
	if na := readWorkLinkFile(t, a, al.ID); na.Local.Work.Incarnation != "77:456" || na.ID != al.ID || na.Revision != al.Revision {
		t.Fatal("Work host did not re-pin", na.Local.Work)
	}
	// The carrier reports the refusal; the sender's receipt says why.
	if _, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "work_native_refused", MessageID: testGroupID, WorkRefusal: err.Error()}); err != nil {
		t.Fatal(err)
	}
	r, _ := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "receipt", LinkID: bl.ID, MessageID: testGroupID, ClientToken: workTestToken}, pane)
	if !strings.Contains(r["delivery_refused"].(string), workTargetRepinned) {
		t.Fatal("receipt", r)
	}

	// The carrier carries the signed peer re-pin, then the queued reply.
	workNativeCarry(t, a, "node-a", b, "node-b")
	if nb := readWorkLinkFile(t, b, bl.ID); nb.Peer.Work.Incarnation != "77:456" {
		t.Fatal("peer re-pin not carried", nb.Peer.Work)
	}
	settled := workNativeCarry(t, b, "node-b", a, "node-a")
	if len(settled) != 1 || settled[0]["status"] != "admitted_not_processed" || workCalls.Load() != 1 || settled[0]["fingerprint"] == oldFingerprint {
		t.Fatal("re-addressed reply not delivered once", settled, workCalls.Load())
	}
	if again := workNativeCarry(t, b, "node-b", a, "node-a"); len(again) != 0 || workCalls.Load() != 1 {
		t.Fatal("delivered twice", again)
	}
}

// Only the owner and incarnation of the same thread may be re-addressed.
func TestWorkNativeRetargetRefusesAnyOtherChange(t *testing.T) {
	_, b, _, bl, _, _ := workNativeFixture(t)
	ctx := context.Background()
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if _, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: testGroupID, Text: "pane reply", ClientToken: workTestToken}, pane); err != nil {
		t.Fatal(err)
	}
	var before workTransportReceipt
	if err := communicationRead(workOutboundPath(b, testGroupID), &before); err != nil {
		t.Fatal(err)
	}
	for name, edit := range map[string]func(*communicationTypedRemoteLink){
		"other thread": func(l *communicationTypedRemoteLink) {
			w := *l.Peer.Work
			w.Thread = "00000000-0000-4000-8000-000000000009"
			l.Peer.Work = &w
		},
		"peer revision": func(l *communicationTypedRemoteLink) {
			l.PeerRevision++
			w := *l.Peer.Work
			w.Incarnation = "9:9"
			l.Peer.Work = &w
		},
		"same pins only": func(l *communicationTypedRemoteLink) {},
	} {
		link := readWorkLinkFile(t, b, bl.ID)
		edit(&link)
		if err := communicationAtomic(remoteLinkPath(b, bl.ID), link); err != nil {
			t.Fatal(err)
		}
		_ = communicationFanoutLocked(b, func() error { return workNativeRetargetLocked(ctx, b, "node-b", testGroupID) })
		var after workTransportReceipt
		if err := communicationRead(workOutboundPath(b, testGroupID), &after); err != nil || after.Wire.Fingerprint != before.Wire.Fingerprint {
			t.Fatal(name, "re-addressed", err)
		}
		if err := communicationAtomic(remoteLinkPath(b, bl.ID), bl); err != nil {
			t.Fatal(err)
		}
	}
}
