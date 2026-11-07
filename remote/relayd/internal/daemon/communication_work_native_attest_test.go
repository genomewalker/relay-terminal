package daemon

import (
	"context"
	"testing"
	"time"
)

// workNativeSignPaneAt makes the pane's send-time statement as if it had been
// signed at the given offset, e.g. a message that waited in the queue.
func workNativeSignPaneAt(t *testing.T, offset time.Duration) {
	t.Helper()
	old := workSignPane
	t.Cleanup(func() { workSignPane = old })
	workSignPane = func(root, node, caller string, r WorkRequest, origin workRequestOrigin, link communicationTypedRemoteLink) (string, error) {
		d := defaultCommunicationSigningDeps(root, node)
		d.observe = workPaneObserve
		request := CommunicationRequest{Operation: "remote_send", SourcePaneID: origin.pane, ActorPaneID: origin.pane, MessageID: r.MessageID, Text: r.Text, ClientID: caller, actorVerified: true}
		// Issue the session certificate now, as a real send would, then
		// backdate only the statement to model the time spent queued.
		if _, e := communicationSignWork(root, node, request, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, d); e != nil {
			return "", e
		}
		d.now = func() time.Time { return time.Now().Add(offset) }
		return communicationSignWork(root, node, request, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, d)
	}
}

// A pane message that waited in the host-channel queue longer than the
// statement lifetime is still delivered: the source host attests the same
// pane session again at dispatch.
func TestWorkNativeQueuedPaneMessageOutlivesItsSendTimeStatement(t *testing.T) {
	a, b, _, bl, _, workCalls := workNativeFixture(t)
	workNativeSignPaneAt(t, -(communicationStatementTTL + 5*time.Minute))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if got, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: workNativeSecondID, Text: "queued a while", ClientToken: workTestToken}, pane); err != nil || got["carrier"] != "relay_host_channel" {
		t.Fatal("pane send", got, err)
	}
	settled := workNativeCarry(t, b, "node-b", a, "node-a")
	if workCalls.Load() != 1 || len(settled) != 1 {
		t.Fatal("queued pane message not delivered after its statement expired", workCalls.Load(), settled)
	}
}

// The re-attestation never covers a different session: if the pane now runs
// another conversation, the queued message is not dispatched.
func TestWorkNativeQueuedPaneMessageRefusedAfterSessionChange(t *testing.T) {
	_, b, _, bl, _, workCalls := workNativeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if _, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: workNativeSecondID, Text: "before the switch", ClientToken: workTestToken}, pane); err != nil {
		t.Fatal(err)
	}
	oldObserve := workPaneObserve
	t.Cleanup(func() { workPaneObserve = oldObserve })
	workPaneObserve = func(id string) communicationMember {
		m := oldObserve(id)
		m.SessionID = "66666666-6666-4666-8666-666666666666"
		return m
	}
	claim, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "work_native_claim", MessageID: workNativeSecondID})
	if err == nil {
		t.Fatal("claim re-signed a pane whose session changed", claim)
	}
	if workCalls.Load() != 0 {
		t.Fatal("delivered after session change")
	}
}
