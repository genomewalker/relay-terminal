package daemon

import (
	"context"
	"strings"
	"testing"
)

// 46cea338 (2026-11-12): the pane read its receipt 5 s after sending, while
// the message still waited for the carrier, and saw only "outcome_unknown".
// The receipt now says how far the message has got, without changing status.
func TestWorkNativeUnsettledReceiptNamesItsCarrierStage(t *testing.T) {
	a, b, al, _, _, _ := workNativeFixture(t)
	receipt := func() map[string]any {
		t.Helper()
		got, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "receipt", LinkID: al.ID, MessageID: signedMessage, ClientToken: workTestToken}, workNativeWorkOrigin())
		if err != nil {
			t.Fatal("receipt", err)
		}
		return got
	}
	sent := workNativeQueueSend(t, a, al, signedMessage, "private Work message")
	if sent["carrier_state"] != "queued" || sent["queued_at"] == nil {
		t.Fatal("send result must say it is queued", sent)
	}
	if got := receipt(); got["status"] != "outcome_unknown" || got["carrier_state"] != "queued" || got["replay_permitted"] != false {
		t.Fatal("queued receipt", got)
	}
	_, envelope := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	if got := receipt(); got["status"] != "outcome_unknown" || got["carrier_state"] != "dispatched" {
		t.Fatal("dispatched receipt", got)
	}
	delivered, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
	if err != nil {
		t.Fatal("deliver", err)
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: delivered["work_reply"].(string)}); err != nil {
		t.Fatal("settle", err)
	}
	got := receipt()
	if got["status"] != "accepted_by_provider" || got["carrier_state"] != nil || got["carrier"] != nil || got["queued_at"] != nil {
		t.Fatal("settled receipt must carry only the final outcome", got)
	}
}

// eede66c6 (2026-11-12): the Mac's relayd refused every delivery because the
// Codex app had restarted, but the carrier dropped the refusal, so the sender
// saw only "outcome_unknown". The app now reports the peer's refusal; it is
// shown with the receipt as unverified and never settles or unqueues it.
func TestWorkNativeCarrierRefusalIsShownButNeverSettles(t *testing.T) {
	a, _, al, _, _, _ := workNativeFixture(t)
	receipt := func() map[string]any {
		t.Helper()
		got, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "receipt", LinkID: al.ID, MessageID: signedMessage, ClientToken: workTestToken}, workNativeWorkOrigin())
		if err != nil {
			t.Fatal("receipt", err)
		}
		return got
	}
	workNativeQueueSend(t, a, al, signedMessage, "private Work message")
	// A refusal for a message the carrier has not dispatched is not recorded.
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, CarrierError: "Work target changed"}); err == nil {
		t.Fatal("refusal before dispatch must be rejected")
	}
	workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, CarrierError: ""}); err == nil {
		t.Fatal("an empty reason must be rejected")
	}
	long := "Work target\nincarnation changed\x00 " + strings.Repeat("x", 400)
	got, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, CarrierError: long})
	if err != nil || got["status"] != "recorded" {
		t.Fatal("refusal", got, err)
	}
	r := receipt()
	reason, _ := r["carrier_error"].(string)
	if r["status"] != "outcome_unknown" || r["replay_permitted"] != false || r["carrier_state"] != "dispatched" ||
		r["carrier_error_source"] != "relay_app_unverified" || r["carrier_error_at"] == "" ||
		!strings.HasPrefix(reason, "peer refused: Work target incarnation changed x") || len(reason) > len("peer refused: ")+300 ||
		strings.ContainsAny(reason, "\n\x00") {
		t.Fatal("refused receipt", r)
	}
	// The message stays queued, so a later claim still dispatches it.
	if again, _ := workNativeClaimEnvelope(t, a, "node-a", signedMessage); again == nil {
		t.Fatal("refused message must stay claimable")
	}
}
