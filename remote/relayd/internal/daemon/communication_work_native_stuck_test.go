package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// Five dandy-07 messages from 2026-11-07 were still queued on 2026-11-12:
// their claims failed before the 24 h check, so they never expired, and the
// carrier's refusals were invisible to the sender. Expiry now needs only the
// queue record and receipt, and the reason a message is not delivered is
// recorded and shown on the receipt.

func workNativeReceiptNow(t *testing.T, root string, link communicationTypedRemoteLink, id string) map[string]any {
	t.Helper()
	got, err := executeWorkRequest(context.Background(), root, "node-a", WorkRequest{Operation: "receipt", LinkID: link.ID, MessageID: id, ClientToken: workTestToken}, workNativeWorkOrigin())
	if err != nil {
		t.Fatal("receipt", err)
	}
	return got
}

func TestWorkNativePeerRefusalIsShownOnTheReceiptAndInTheExpiry(t *testing.T) {
	a, _, al, _, _, _ := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "private Work message")
	workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	reason := "Work endpoint incarnation changed\n(stale pin)"
	got, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, WorkRefusal: reason})
	if err != nil || got["status"] != "recorded" {
		t.Fatal("refusal not recorded", got, err)
	}
	r := workNativeReceiptNow(t, a, al, signedMessage)
	refused, _ := r["delivery_refused"].(string)
	if r["status"] != "outcome_unknown" || r["carrier_state"] != "dispatched" || !strings.Contains(refused, "incarnation changed") || strings.ContainsAny(refused, "\n") || r["refusals"] != 1 {
		t.Fatal("receipt must say why delivery is refused", r)
	}
	if strings.Contains(fmt.Sprint(r), "private Work message") {
		t.Fatal("receipt leaked text", r)
	}
	// Refusal text is bounded.
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, WorkRefusal: strings.Repeat("x", 5000)}); err != nil {
		t.Fatal(err)
	}
	if r = workNativeReceiptNow(t, a, al, signedMessage); len(r["delivery_refused"].(string)) > workNativeRefusalLimit+40 || r["refusals"] != 2 {
		t.Fatal("unbounded refusal", len(r["delivery_refused"].(string)), r["refusals"])
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage}); err == nil {
		t.Fatal("empty refusal accepted")
	}
	if got, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: testGroupID, WorkRefusal: "x"}); err != nil || got["status"] != "not_pending" {
		t.Fatal("unknown message", got, err)
	}
	// Agents and registered clients cannot report refusals.
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_refused", MessageID: signedMessage, WorkRefusal: "x", ClientToken: "client"}); err == nil {
		t.Fatal("client reported a refusal")
	}
	base := workNativeNow
	workNativeNow = func() time.Time { return base().Add(workNativeQueryWindow + time.Minute) }
	defer func() { workNativeNow = base }()
	list, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_pending"})
	if err != nil || len(list["items"].([]map[string]any)) != 0 {
		t.Fatal("expired message still listed", list, err)
	}
	r = workNativeReceiptNow(t, a, al, signedMessage)
	msg := fmt.Sprint(r["error"])
	if r["status"] != "outcome_unknown" || !strings.Contains(msg, "24 h") || !strings.Contains(msg, "last reason") || r["delivery_refused"] == nil || r["carrier_state"] != nil {
		t.Fatal("expired receipt must be explicit", r)
	}
}

func TestWorkNativeMessageWhoseLinkNoLongerChecksOutStillExpires(t *testing.T) {
	a, _, al, _, _, _ := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "private Work message")
	// The link is retired after queueing, so claims fail in the link check.
	if _, err := communicationRetireTypedLink(a, "node-a", al, al.Revision, workNativeNow); err != nil {
		t.Fatal(err)
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage}); err == nil {
		t.Fatal("claim on a retired link")
	}
	var p workNativePending
	if err := communicationRead(workNativePendingPath(a, signedMessage), &p); err != nil || !strings.Contains(p.LastRefusal, "not dispatched by the sending host") || p.Refusals != 1 {
		t.Fatal("own failure not recorded", p, err)
	}
	base := workNativeNow
	workNativeNow = func() time.Time { return base().Add(workNativeQueryWindow + time.Minute) }
	defer func() { workNativeNow = base }()
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage}); err == nil || !strings.Contains(err.Error(), "24 h") {
		t.Fatal("expired claim", err)
	}
	if _, err := os.Stat(workNativePendingPath(a, signedMessage)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("stuck message kept", err)
	}
	var receipt workTransportReceipt
	if err := communicationRead(workOutboundPath(a, signedMessage), &receipt); err != nil || !strings.Contains(fmt.Sprint(receipt.Result["error"]), "not delivered") {
		t.Fatal("expired receipt", receipt.Result, err)
	}
}
