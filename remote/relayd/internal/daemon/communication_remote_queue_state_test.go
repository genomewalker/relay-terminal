package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

// queueSignedPaneReply queues a signed pane reply from node-b to the desktop
// session on node-a and returns the sender's send result.
func queueSignedPaneReply(t *testing.T, f scopedNodes, id string) map[string]any {
	t.Helper()
	token := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(f.b), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(token[:])}}}); err != nil {
		t.Fatal(err)
	}
	reply := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: id,
		Text: "queued reply", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	hooks := f.hooksB
	hooks.observe = func(pane string) communicationMember {
		m := f.hooksB.observe(pane)
		m.PID, m.Start = 4242, "fixture"
		return m
	}
	got, linked, err := communicationSendToDesktop(f.b, "node-b", reply, hooks)
	if !linked || err != nil {
		t.Fatal("queue reply", got, err)
	}
	return got
}

// paneReceipt is the sending pane's own receipt query on node-b.
func paneReceipt(t *testing.T, f scopedNodes, id string, withToken bool) map[string]any {
	t.Helper()
	query := CommunicationRequest{Operation: "receipt", MessageID: id, ActorPaneID: testGroupB, actorVerified: true}
	if withToken {
		query.ClientToken = replyToken
	}
	got, handled, err := communicationRemoteReceiptLookup(f.b, "node-b", query, f.hooksB)
	if !handled || err != nil {
		t.Fatalf("the sending host did not answer its own outbound ID (token=%v): handled=%v err=%v got=%v", withToken, handled, err, got)
	}
	return got
}

func assertQueued(t *testing.T, label string, got map[string]any) {
	t.Helper()
	// The old status stays as it was, for older readers.
	if got["status"] != "outcome_unknown" || got["carrier"] != "relay_host_channel" || got["carrier_state"] != "queued" {
		t.Fatal(label, "is not reported as queued", got)
	}
	queuedAt, ok := got["queued_at"].(time.Time)
	deadline, ok2 := got["carry_deadline"].(time.Time)
	if !ok || !ok2 || queuedAt.IsZero() || deadline.Sub(queuedAt) != remoteNativeSignedWindow {
		t.Fatal(label, "has no queued_at and carry deadline of queued_at plus the signed window", got)
	}
}

// A message waiting for the Relay app's carrier is reported as queued, with
// when it was queued and when it must be carried; once carried, the receipt
// reports the peer's final status and no longer says queued.
func TestHostChannelQueuedThenWrittenToSocket(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1"
	assertQueued(t, "send result", queueSignedPaneReply(t, f, id))
	assertQueued(t, "receipt with token", paneReceipt(t, f, id, true))
	assertQueued(t, "receipt of the proven pane", paneReceipt(t, f, id, false))
	settled := hostChannelCarry(t, f.b, "node-b", f.hooksB, f.a, "node-a", f.hooksA)
	if len(settled) != 1 || settled[0]["status"] != "written_to_socket" || settled[0]["carrier_state"] != "carried" {
		t.Fatal("settle result", settled)
	}
	for _, withToken := range []bool{true, false} {
		got := paneReceipt(t, f, id, withToken)
		if got["status"] != "written_to_socket" || got["carrier_state"] != "carried" || got["queued_at"] != nil || got["carry_deadline"] != nil {
			t.Fatal("carried receipt", got)
		}
	}
}

// A queued signed message the carrier takes too late is reported as too late,
// and is no longer reported as queued.
func TestHostChannelQueuedThenTooLate(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2"
	assertQueued(t, "send result", queueSignedPaneReply(t, f, id))
	nativeClock(t, communicationStatementTTL)
	if _, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_claim", MessageID: id}); err == nil || !strings.Contains(err.Error(), "carried too late") {
		t.Fatal("a late signed message was claimed", err)
	}
	got := paneReceipt(t, f, id, false)
	if got["status"] != "not_sent" || got["carrier_state"] != "too_late" || got["queued_at"] != nil ||
		!strings.Contains(got["error"].(string), "carried too late") {
		t.Fatal("too-late receipt", got)
	}
}

// A message that reaches the peer after its statement expired in transit is
// refused there by name; the sender's receipt reports it as too late.
func TestHostChannelQueuedThenRefusedInTransitIsTooLate(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3"
	queueSignedPaneReply(t, f, id)
	claim, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	nativeClock(t, communicationStatementTTL+time.Minute)
	delivered, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: delivered["work_reply"].(string)}); err != nil {
		t.Fatal(err)
	}
	if got := paneReceipt(t, f, id, false); got["status"] != "not_delivered" || got["carrier_state"] != "too_late" {
		t.Fatal("refused-in-transit receipt", got)
	}
}
