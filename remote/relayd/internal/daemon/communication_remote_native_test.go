package daemon

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// hostChannelLinked approves the desktop session's pair over the host channel.
func hostChannelLinked(t *testing.T) (scopedNodes, CommunicationRemoteLink) {
	t.Helper()
	f, dispatch := nativeApproval(t)
	delivered, err := nativeDeliver(f, dispatch["establish_envelope"].(string))
	if err != nil {
		t.Fatal(err)
	}
	established, err := nativeSettle(f, dispatch["message_id"].(string), delivered["establish_reply"].(string))
	if err != nil {
		t.Fatal(err)
	}
	return f, established["link"].(CommunicationRemoteLink)
}

func hostChannelSend(t *testing.T, f scopedNodes, id string) CommunicationRequest {
	t.Helper()
	send := CommunicationRequest{Operation: "remote_send", SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: id, Text: "carried", ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	if got, err := communicationSendRemote(f.a, "node-a", send, f.hooksA); err != nil || got["carrier"] != "relay_host_channel" {
		t.Fatal("queue", got, err)
	}
	return send
}

func hostChannelOp(root, node string, hooks communicationGroupNative, r CommunicationRequest) (map[string]any, error) {
	return communicationWorkNativeWith(context.Background(), root, node, r, hooks)
}

// A well-formed envelope signed by a key the receiver does not pin for the
// sending node is refused, and nothing is delivered.
func TestHostChannelRemoteMessageWrongSignerRefused(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1"
	hostChannelSend(t, f, id)
	claim, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	impostor, _ := peerFixture(t, "node-a")
	forged := nativeResign(t, claim["work_envelope"].(string), remoteNativeKind, "node-a", impostor, func(*remoteNativeSend) {})
	before := f.paneCalls.Load()
	if _, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: forged}); err == nil || f.paneCalls.Load() != before {
		t.Fatal("an envelope from an unpinned signer was delivered", err)
	}
	// A reply forged by an unpinned node-b key is refused at settle.
	delivered, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
	if err != nil {
		t.Fatal(err)
	}
	otherB, _ := peerFixture(t, "node-b")
	forgedReply := nativeResign(t, delivered["work_reply"].(string), remoteNativeReplyKind, "node-b", otherB, func(*remoteNativeReply) {})
	if _, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: forgedReply}); err == nil {
		t.Fatal("a reply from an unpinned signer settled the receipt")
	}
}

// A link revision change after queuing refuses the message on either side.
func TestHostChannelRemoteMessageLinkRevisionChangeRefused(t *testing.T) {
	f, link := hostChannelLinked(t)
	id := "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2"
	hostChannelSend(t, f, id)
	claim, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	// Receiver: its half moved to a new revision.
	peer, err := readRemoteLink(f.b, "node-b", link.ID)
	if err != nil {
		t.Fatal(err)
	}
	peer.Revision++
	if err := communicationAtomic(remoteLinkPath(f.b, link.ID), peer); err != nil {
		t.Fatal(err)
	}
	before := f.paneCalls.Load()
	if _, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)}); err == nil || f.paneCalls.Load() != before {
		t.Fatal("delivered against a changed peer link revision", err)
	}
	// Sender: its half moved to a new revision; the claim is refused.
	local, err := readRemoteLink(f.a, "node-a", link.ID)
	if err != nil {
		t.Fatal(err)
	}
	local.Revision++
	if err := communicationAtomic(remoteLinkPath(f.a, link.ID), local); err != nil {
		t.Fatal(err)
	}
	if _, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: id}); err == nil || !strings.Contains(err.Error(), "changed") {
		t.Fatal("claimed against a changed local link revision", err)
	}
}

// Without a carrier the message stays queued and the receipt says carried;
// after 24 h the receipt says the peer never confirmed. It is never dropped
// silently.
func TestHostChannelRemoteMessageWithoutCarrierStaysPending(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3"
	send := hostChannelSend(t, f, id)
	query := CommunicationRequest{Operation: "receipt", MessageID: id, ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}
	for i := 0; i < 2; i++ {
		got, handled, err := communicationRemoteReceiptLookup(f.a, "node-a", query, f.hooksA)
		if !handled || err != nil || got["status"] != "outcome_unknown" || got["carrier"] != "relay_host_channel" || got["request_finished"] == true && got["peer_authentication"] != "not_confirmed" {
			t.Fatal("receipt of an uncarried message", got, err)
		}
	}
	if repeat, err := communicationSendRemote(f.a, "node-a", send, f.hooksA); err != nil || repeat["carrier"] != "relay_host_channel" {
		t.Fatal("repeat send while queued", repeat, err)
	}
	if !remoteNativePendingFor(f.a, id) {
		t.Fatal("queued message dropped")
	}
	nativeClock(t, 25*time.Hour)
	if _, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: id}); err == nil {
		t.Fatal("claimed after the 24 h window")
	}
	got, _, _ := communicationRemoteReceiptLookup(f.a, "node-a", query, f.hooksA)
	if got["status"] != "outcome_unknown" || !strings.Contains(got["error"].(string), "24 h") {
		t.Fatal("expired message receipt does not say so", got)
	}
}

// A message sent before host-channel route links were carried has a receipt
// and no queue record. Its receipt says it was never queued, and no carrier
// picks it up.
func TestHostChannelLegacyOutboundIsNotCarried(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c4c4c4c4-c4c4-4c4c-8c4c-c4c4c4c4c4c4"
	hostChannelSend(t, f, id)
	if err := os.Remove(remoteNativePendingPath(f.a, id)); err != nil {
		t.Fatal(err)
	}
	// The receipt as relayd 0.5.22 left it for e3e6a39d.
	var receipt communicationRemoteOutbound
	if err := communicationRead(remoteOutboundPath(f.a, id), &receipt); err != nil {
		t.Fatal(err)
	}
	receipt.Result = map[string]any{"status": "outcome_unknown", "error": "peer outcome unavailable; query the durable receipt without resending"}
	receipt.RequestFinished = true
	if err := communicationAtomic(remoteOutboundPath(f.a, id), receipt); err != nil {
		t.Fatal(err)
	}
	pending, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_pending"})
	if err != nil || len(pending["items"].([]map[string]any)) != 0 {
		t.Fatal("a legacy outbound record was listed for the carrier", pending, err)
	}
	got, handled, err := communicationRemoteReceiptLookup(f.a, "node-a", CommunicationRequest{Operation: "receipt", MessageID: id,
		ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}, f.hooksA)
	if !handled || err != nil || got["status"] != "outcome_unknown" || !strings.Contains(got["error"].(string), "never queued") {
		t.Fatal("legacy receipt", got, err)
	}
}
