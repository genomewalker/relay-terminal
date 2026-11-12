package daemon

import (
	"context"
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
