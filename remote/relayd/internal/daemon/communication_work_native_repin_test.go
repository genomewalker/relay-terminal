package daemon

import (
	"context"
	"testing"
	"time"
)

func workNativeRepinRecord(t *testing.T, root, linkID string) workNativeRepin {
	t.Helper()
	var r workNativeRepin
	if err := communicationRead(workNativeRepinPath(root, linkID), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

// A Work restart on a host-channel route: the re-pin is queued, carried by the
// app like a message, applied by the peer, and two-way delivery works again.
func TestWorkNativeRepinRestoresTwoWayDeliveryOverHostChannel(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workNativeFixture(t)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	restart("owner-after-restart", "77:456", workTestThread, nil)
	result, err := repinWorkLink(ctx, a, "node-a", al.ID)
	if err != nil || result["local_changed"] != true || result["peer_status"] != "queued" {
		t.Fatal("re-pin must queue on a host-channel route", result, err)
	}
	if nb := readWorkLinkFile(t, b, bl.ID); nb.Peer.Work.Owner == "owner-after-restart" {
		t.Fatal("peer changed before the carrier delivered")
	}
	first := workNativeRepinRecord(t, a, al.ID)
	// Asking again before the carrier runs keeps the same queued re-pin.
	if result, err = repinWorkLink(ctx, a, "node-a", al.ID); err != nil || result["peer_status"] != "queued" || workNativeRepinRecord(t, a, al.ID).MessageID != first.MessageID {
		t.Fatal("second re-pin must reuse the queued one", result, err)
	}

	settled := workNativeCarry(t, a, "node-a", b, "node-b")
	if len(settled) != 1 || settled[0]["operation"] != "repin" || settled[0]["peer_status"] != "repinned" {
		t.Fatal("carrier did not settle the re-pin", settled)
	}
	na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID)
	if nb.Peer.Work.Owner != "owner-after-restart" || nb.Peer.Work.Incarnation != "77:456" || nb.PinGeneration != na.PinGeneration ||
		nb.Revision != bl.Revision || nb.RouteID != bl.RouteID || nb.PeerCertificateSHA256 != bl.PeerCertificateSHA256 {
		t.Fatal("peer re-pin changed more than the pin", nb)
	}
	if status, err := workNativeRepinStatus(ctx, a, "node-a", al.ID); err != nil || status["peer_status"] != "current" {
		t.Fatal("settled re-pin must read current", status, err)
	}
	if pending, _ := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_pending"}); len(pending["items"].([]map[string]any)) != 0 {
		t.Fatal("settled re-pin still listed", pending)
	}

	newWork := workRequestOrigin{thread: workTestThread, applicationPID: 77, revalidate: func() error { return nil }}
	if got, err := executeWorkRequest(ctx, a, "node-a", WorkRequest{Operation: "send", LinkID: al.ID, MessageID: "11111111-1111-4111-8111-111111111111", Text: "hello pane", ClientToken: workTestToken}, newWork); err != nil || got["carrier"] != "relay_host_channel" {
		t.Fatal("Work send after re-pin", got, err)
	}
	workNativeCarry(t, a, "node-a", b, "node-b")
	if paneCalls.Load() != 1 {
		t.Fatal("Work to pane after re-pin not delivered", paneCalls.Load())
	}
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if got, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: workNativeSecondID, Text: "hello Work", ClientToken: workTestToken}, pane); err != nil || got["carrier"] != "relay_host_channel" {
		t.Fatal("pane send after re-pin", got, err)
	}
	workNativeCarry(t, b, "node-b", a, "node-a")
	if workCalls.Load() != 1 {
		t.Fatal("pane to Work after re-pin not delivered", workCalls.Load())
	}
}

func TestWorkNativeRepinRefusesStaleTamperedAndUnpinned(t *testing.T) {
	a, b, al, bl, _, _ := workNativeFixture(t)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	restart("owner-1", "77:1", workTestThread, nil)
	if result, err := repinWorkLink(ctx, a, "node-a", al.ID); err != nil || result["peer_status"] != "queued" {
		t.Fatal(result, err)
	}
	old := workNativeRepinRecord(t, a, al.ID)
	_, oldEnvelope := workNativeClaimEnvelope(t, a, "node-a", old.MessageID)

	deliver := func(envelope string) error {
		_, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
		return err
	}
	unchanged := func(name string) {
		t.Helper()
		if nb := readWorkLinkFile(t, b, bl.ID); !communicationEndpointEqual(nb.Peer, bl.Peer) || nb.PinGeneration != bl.PinGeneration {
			t.Fatal(name, "changed the peer link", nb.Peer.Work, nb.PinGeneration)
		}
	}

	// Signed by a different host key that claims to be node-a.
	impostor, _ := peerFixture(t, "node-a")
	if err := deliver(workNativeResign(t, oldEnvelope, impostor, "node-a", func(*workNativeSend) {})); err == nil {
		t.Fatal("re-pin signed by an unpinned key accepted")
	}
	unchanged("wrong key")
	// Well signed but altered: another thread.
	if err := deliver(workNativeResign(t, oldEnvelope, a, "node-a", func(s *workNativeSend) { s.Wire.Source.Work.Thread = "019ed12d-0000-7000-8000-000000000000" })); err == nil {
		t.Fatal("altered re-pin accepted")
	}
	unchanged("tampered")
	// A delayed frame.
	if err := deliver(workNativeResign(t, oldEnvelope, a, "node-a", func(s *workNativeSend) { s.SourceCurrentAt = time.Now().UTC().Add(-10 * time.Minute) })); err == nil {
		t.Fatal("delayed re-pin accepted")
	}
	unchanged("delayed")
	// Not a re-pin frame carrying text.
	if err := deliver(workNativeResign(t, oldEnvelope, a, "node-a", func(s *workNativeSend) { s.Wire.Text = "hello" })); err == nil {
		t.Fatal("re-pin with text accepted")
	}
	unchanged("text")

	// A second restart supersedes the first re-pin before it was carried.
	restart("owner-2", "77:2", workTestThread, nil)
	if result, err := repinWorkLink(ctx, a, "node-a", al.ID); err != nil || result["peer_status"] != "queued" {
		t.Fatal(result, err)
	}
	if workNativeRepinRecord(t, a, al.ID).MessageID == old.MessageID {
		t.Fatal("newer generation reused the superseded re-pin")
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: old.MessageID}); err == nil {
		t.Fatal("superseded re-pin claimed")
	}
	workNativeCarry(t, a, "node-a", b, "node-b")
	if nb := readWorkLinkFile(t, b, bl.ID); nb.Peer.Work.Owner != "owner-2" {
		t.Fatal("newest re-pin not applied", nb.Peer.Work)
	}
	// The old, once-valid frame is refused now: its generation is stale.
	if err := deliver(oldEnvelope); err == nil {
		t.Fatal("stale re-pin accepted after a newer one")
	}
	if nb := readWorkLinkFile(t, b, bl.ID); nb.Peer.Work.Owner != "owner-2" {
		t.Fatal("stale re-pin rolled the peer back", nb.Peer.Work)
	}
}

// A re-pin is settled only by the peer's signed reply for that exact frame.
func TestWorkNativeRepinSettleNeedsTheMatchingSignedReply(t *testing.T) {
	a, b, al, _, _, _ := workNativeFixture(t)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	restart("owner-1", "77:1", workTestThread, nil)
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err != nil {
		t.Fatal(err)
	}
	r := workNativeRepinRecord(t, a, al.ID)
	_, envelope := workNativeClaimEnvelope(t, a, "node-a", r.MessageID)
	delivered, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
	if err != nil {
		t.Fatal(err)
	}
	reply := delivered["work_reply"].(string)
	// A reply signed by this host itself, not the pinned peer.
	forged, err := workNativeSign(a, "node-b", "reply", []byte(`{}`))
	if err == nil {
		if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: r.MessageID, WorkReply: forged}); err == nil {
			t.Fatal("unpinned reply settled the re-pin")
		}
	}
	if got := workNativeRepinRecord(t, a, al.ID); got.Settled {
		t.Fatal("re-pin settled without the peer's reply")
	}
	if got, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: r.MessageID, WorkReply: reply}); err != nil || got["peer_status"] != "repinned" {
		t.Fatal("matching reply did not settle", got, err)
	}
	if got := workNativeRepinRecord(t, a, al.ID); !got.Settled || got.SettledGeneration != readWorkLinkFile(t, a, al.ID).PinGeneration {
		t.Fatal("settled generation not recorded", got)
	}
}
