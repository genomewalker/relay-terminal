package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// hostChannelCarry is the app's Work carrier between two relayds: pending,
// claim, deliver, settle, exactly the packets RelayWorkCarrier sends. It
// returns the settle results.
func hostChannelCarry(t *testing.T, from, fromNode string, fromHooks communicationGroupNative, to, toNode string, toHooks communicationGroupNative) []map[string]any {
	t.Helper()
	op := func(root, node string, hooks communicationGroupNative, r CommunicationRequest) (map[string]any, error) {
		return communicationWorkNativeWith(context.Background(), root, node, r, hooks)
	}
	pending, err := op(from, fromNode, fromHooks, CommunicationRequest{Operation: "work_native_pending"})
	if err != nil {
		t.Fatal("pending", err)
	}
	var settled []map[string]any
	for _, item := range pending["items"].([]map[string]any) {
		if item["peer_node_id"] != toNode {
			continue
		}
		id := item["message_id"].(string)
		claim, err := op(from, fromNode, fromHooks, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
		if err != nil {
			t.Fatal("claim", err)
		}
		envelope, _ := claim["work_envelope"].(string)
		delivered, err := op(to, toNode, toHooks, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
		if err != nil {
			t.Fatal("deliver", err)
		}
		result, err := op(from, fromNode, fromHooks, CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: delivered["work_reply"].(string)})
		if err != nil {
			t.Fatal("settle", err)
		}
		settled = append(settled, result)
	}
	return settled
}

// The whole desktop <-> remote pane conversation over a route carried by the
// Relay host channel, as the live session ran it: request, owner approval,
// a repeated request, the list, one message delivered once, the pane's reply
// in the desktop inbox, and the sender's receipt with the peer's outcome.
// This is the acceptance test for host-channel desktop links.
func TestDesktopConversationOverHostChannel(t *testing.T) {
	f, dispatch := nativeApproval(t)
	delivered, err := nativeDeliver(f, dispatch["establish_envelope"].(string))
	if err != nil {
		t.Fatal("establish deliver", err)
	}
	established, err := nativeSettle(f, dispatch["message_id"].(string), delivered["establish_reply"].(string))
	if err != nil || established["status"] != "established" {
		t.Fatal("step 2 approve: establish settle", established, err)
	}
	link := established["link"].(CommunicationRemoteLink)

	// Step 3: the same link call again is answered linked, with no new request.
	again, err := communicationDesktopLinkRequestOp(f.a, "node-a", CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias,
		PaneID: testGroupB, PeerNodeID: "node-b", ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}, desktopLinkNow())
	if err != nil || again["status"] != "linked" || again["link_id"] != link.ID {
		t.Fatal("step 3 repeated link: not linked", again, err)
	}

	// Step 4: the session's list shows the link.
	own, ok := desktopSessionOwnLinks(f.a, "node-a", CommunicationRequest{Operation: "list", ActorPaneID: desktopAlias, actorVerified: true})
	if !ok || len(own) != 1 || own[0].LinkID != link.ID {
		t.Fatal("step 4 list: link missing", own)
	}

	// Step 5: one message, queued for the carrier, delivered once on node-b.
	before := f.paneCalls.Load()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: "e3e6a39d-bdc1-475a-9cf8-0aab709c4241", Text: "hello over the host channel",
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	sent, err := communicationSendRemote(f.a, "node-a", send, f.hooksA)
	if err != nil || sent["status"] != "outcome_unknown" || sent["carrier"] != "relay_host_channel" || sent["error"] != nil {
		t.Fatal("step 5 send: not queued for the host-channel carrier", sent, err)
	}
	if f.paneCalls.Load() != before {
		t.Fatal("step 5 send: delivered before the carrier ran")
	}
	settled := hostChannelCarry(t, f.a, "node-a", f.hooksA, f.b, "node-b", f.hooksB)
	if len(settled) != 1 || settled[0]["status"] != "accepted" || f.paneCalls.Load() != before+1 {
		t.Fatal("step 5 send: carrier did not deliver once", settled, f.paneCalls.Load()-before)
	}
	// A repeat of the same ID is answered from the receipt, never delivered again.
	if repeat, err := communicationSendRemote(f.a, "node-a", send, f.hooksA); err != nil || repeat["status"] != "accepted" {
		t.Fatal("step 5 send: repeat of the same ID", repeat, err)
	}
	if more := hostChannelCarry(t, f.a, "node-a", f.hooksA, f.b, "node-b", f.hooksB); len(more) != 0 || f.paneCalls.Load() != before+1 {
		t.Fatal("step 5 send: delivered twice", more)
	}

	// Step 6: the pane replies; the carrier takes it from node-b to node-a.
	reply := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(f.b), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(reply[:])}}}); err != nil {
		t.Fatal(err)
	}
	sends := sendsTo(f.calls)
	answer := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: "b6b6b6b6-b6b6-4b6b-8b6b-b6b6b6b6b6b6",
		Text: "reply from the pane", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	queued, linked, err := communicationSendToDesktop(f.b, "node-b", answer, f.hooksB)
	if !linked || err != nil || queued["carrier"] != "relay_host_channel" {
		t.Fatal("step 6 reply: not queued for the carrier", queued, linked, err)
	}
	back := hostChannelCarry(t, f.b, "node-b", f.hooksB, f.a, "node-a", f.hooksA)
	if len(back) != 1 || sendsTo(f.calls) != sends+1 {
		t.Fatal("step 6 reply: not delivered to the desktop session", back)
	}

	// Step 7: the desktop inbox holds the reply.
	inbox, err := communicationDesktopInboxRead(f.a, CommunicationRequest{Operation: "desktop_inbox_read", SourcePaneID: desktopAlias, ActorPaneID: desktopAlias, actorVerified: true})
	if err != nil || len(inbox["messages"].([]desktopInboxEntry)) != 1 || inbox["messages"].([]desktopInboxEntry)[0].MessageID != answer.MessageID {
		t.Fatal("step 7 inbox: reply missing", inbox, err)
	}

	// Step 8: the plain receipt query reports the peer's outcome, to the sender only.
	receipt, handled, err := communicationRemoteReceiptLookup(f.a, "node-a", CommunicationRequest{Operation: "receipt", MessageID: send.MessageID,
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}, f.hooksA)
	if !handled || err != nil || receipt["status"] != "accepted" || receipt["peer_authentication"] != workNativeAuth {
		t.Fatal("step 8 receipt: peer outcome not reported", receipt, handled, err)
	}
	if other, handled, err := communicationRemoteReceiptLookup(f.a, "node-a", CommunicationRequest{Operation: "receipt", MessageID: send.MessageID,
		ClientToken: remoteSenderToken, ActorPaneID: testGroupA, actorVerified: true}, f.hooksA); handled && err == nil {
		t.Fatal("step 8 receipt: another sender read it", other)
	}
}
