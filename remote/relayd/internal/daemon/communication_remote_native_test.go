package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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

// The same signed envelope delivered twice is answered from the receiver's
// record and reaches the pane once. A receipt query without a credential or a
// proven pane is not answered from the remote outbound receipt.
func TestHostChannelRemoteMessageReplayDeliveredOnce(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c5c5c5c5-c5c5-4c5c-8c5c-c5c5c5c5c5c5"
	hostChannelSend(t, f, id)
	claim, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	before := f.paneCalls.Load()
	for i := 0; i < 2; i++ {
		delivered, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
		if err != nil || delivered["work_reply"] == nil {
			t.Fatal("deliver", i, delivered, err)
		}
	}
	if f.paneCalls.Load() != before+1 {
		t.Fatal("a replayed envelope was delivered again", f.paneCalls.Load()-before)
	}
	if got, handled, _ := communicationRemoteReceiptLookup(f.a, "node-a", CommunicationRequest{Operation: "receipt", MessageID: id}, f.hooksA); handled {
		t.Fatal("an unauthenticated receipt query read the remote receipt", got)
	}
}

// hostChannelPaneReply queues a signed pane reply to the desktop session on node-b.
func hostChannelPaneReply(t *testing.T, f scopedNodes, id string) {
	t.Helper()
	token := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(f.b), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(token[:])}}}); err != nil {
		t.Fatal(err)
	}
	reply := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: id,
		Text: "late reply", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	// A pane with a process identity, so its host signs the reply.
	hooks := f.hooksB
	hooks.observe = func(pane string) communicationMember {
		m := f.hooksB.observe(pane)
		m.PID, m.Start = 4242, "fixture"
		return m
	}
	if got, linked, err := communicationSendToDesktop(f.b, "node-b", reply, hooks); !linked || err != nil || got["carrier"] != "relay_host_channel" {
		t.Fatal("queue reply", got, err)
	}
	var receipt communicationRemoteOutbound
	if err := communicationRead(remoteOutboundPath(f.b, id), &receipt); err != nil || receipt.Wire.SourceSignature == "" {
		t.Fatal("the pane reply is not signed, so this test proves nothing", err)
	}
}

// A signed reply the carrier could not take before its statement would expire
// is not sent, and its receipt names why.
func TestHostChannelSignedReplyTooLateIsNotSent(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c6c6c6c6-c6c6-4c6c-8c6c-c6c6c6c6c6c6"
	hostChannelPaneReply(t, f, id)
	nativeClock(t, communicationStatementTTL)
	if _, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_claim", MessageID: id}); err == nil || !strings.Contains(err.Error(), "carried too late") {
		t.Fatal("a late signed reply was claimed", err)
	}
	var receipt communicationRemoteOutbound
	if err := communicationRead(remoteOutboundPath(f.b, id), &receipt); err != nil || receipt.Result["status"] != "not_sent" ||
		!strings.Contains(receipt.Result["error"].(string), "carried too late") || remoteNativePendingFor(f.b, id) {
		t.Fatal("late reply receipt", receipt.Result, err)
	}
}

// A signed reply whose statement expired in transit is refused by the
// receiver with a signed, named answer the sender settles on; nothing reaches
// the desktop inbox.
func TestHostChannelSignedReplyExpiredInTransitIsRefusedByName(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c7c7c7c7-c7c7-4c7c-8c7c-c7c7c7c7c7c7"
	hostChannelPaneReply(t, f, id)
	claim, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	nativeClock(t, communicationStatementTTL+time.Minute)
	delivered, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
	if err != nil {
		t.Fatal("deliver", err)
	}
	settled, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: delivered["work_reply"].(string)})
	if err != nil || settled["status"] != "not_delivered" || !strings.Contains(settled["error"].(string), "carried too late") {
		t.Fatal("expired-in-transit reply", settled, err)
	}
	inbox, err := communicationDesktopInboxRead(f.a, CommunicationRequest{Operation: "desktop_inbox_read", SourcePaneID: desktopAlias, ActorPaneID: desktopAlias, actorVerified: true})
	if err == nil && len(inbox["messages"].([]desktopInboxEntry)) != 0 {
		t.Fatal("an expired reply reached the desktop inbox", inbox)
	}
}

// A signed reply carried in time is delivered as signed.
func TestHostChannelSignedReplyInTimeIsDelivered(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "c9c9c9c9-c9c9-4c9c-8c9c-c9c9c9c9c9c9"
	hostChannelPaneReply(t, f, id)
	settled := hostChannelCarry(t, f.b, "node-b", f.hooksB, f.a, "node-a", f.hooksA)
	if len(settled) != 1 || settled[0]["source_authentication"] != "source_signed" || settled[0]["status"] == "not_delivered" {
		t.Fatal("a signed reply in time was not delivered as signed", settled)
	}
}

// A forged envelope with an expired signed statement, signed by a key the
// receiver does not pin for the sending node, is refused outright. The
// receiver never signs a not_delivered answer for it.
func TestHostChannelForgedExpiredEnvelopeIsRefused(t *testing.T) {
	f, _ := hostChannelLinked(t)
	id := "cacacaca-caca-4aca-8aca-cacacacacaca"
	hostChannelPaneReply(t, f, id)
	claim, err := hostChannelOp(f.b, "node-b", f.hooksB, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal(err)
	}
	impostor, _ := peerFixture(t, "node-b")
	// The impostor also signs its own statement for the message, so the
	// statement verifies against the impostor key and reaches its expiry check.
	deps := defaultCommunicationSigningDeps(impostor, "node-b")
	deps.observe = func(pane string) communicationMember {
		m := f.hooksB.observe(pane)
		m.PID, m.Start = 4242, "fixture"
		return m
	}
	forgedID := "cbcbcbcb-cbcb-4bcb-8bcb-cbcbcbcbcbcb"
	statement, err := communicationSign(impostor, "node-b", CommunicationRequest{Operation: "sign", SourcePaneID: testGroupB, ActorPaneID: testGroupB,
		PaneID: desktopAlias, MessageID: forgedID, Text: "late reply", actorVerified: true}, deps)
	if err != nil {
		t.Fatal(err)
	}
	forged := nativeResign(t, claim["work_envelope"].(string), remoteNativeKind, "node-b", impostor, func(s *remoteNativeSend) {
		s.Wire.MessageID = forgedID
		s.Wire.SourceSignature = statement["source_signature"].(string)
		s.Wire.Fingerprint = remoteMessageFingerprint(s.Wire)
	})
	nativeClock(t, communicationStatementTTL+time.Minute)
	got, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: forged})
	if err == nil {
		t.Fatal("a forged envelope was answered", got)
	}
}
