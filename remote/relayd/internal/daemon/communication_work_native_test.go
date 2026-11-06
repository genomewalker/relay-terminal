package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

const workNativeSecondID = "22222222-2222-4222-8222-222222222222"

// workNativeFixture is workTransportFixture with both bindings switched to the
// Relay host channel. The pinned certificates are unchanged.
func workNativeFixture(t *testing.T) (string, string, communicationTypedRemoteLink, communicationTypedRemoteLink, *atomic.Int32, *atomic.Int32) {
	t.Helper()
	a, b, al, bl, paneCalls, workCalls := workTransportFixture(t, false)
	for _, root := range []string{a, b} {
		workNativeSetEndpoint(t, root, workNativeEndpoint)
	}
	return a, b, al, bl, paneCalls, workCalls
}

func workNativeSetEndpoint(t *testing.T, root, endpoint string) {
	t.Helper()
	path := filepath.Join(root, "peer-binding-binding.json")
	var binding CommunicationPeerBinding
	if e := communicationRead(path, &binding); e != nil {
		t.Fatal(e)
	}
	binding.Endpoint = endpoint
	if e := communicationAtomic(path, binding); e != nil {
		t.Fatal(e)
	}
}

func workNativeOp(root, node string, r CommunicationRequest) (map[string]any, error) {
	return communicationWorkNative(context.Background(), root, node, r)
}

func workNativeClaimEnvelope(t *testing.T, root, node, id string) (map[string]any, string) {
	t.Helper()
	claim, err := workNativeOp(root, node, CommunicationRequest{Operation: "work_native_claim", MessageID: id})
	if err != nil {
		t.Fatal("claim", err)
	}
	envelope, _ := claim["work_envelope"].(string)
	return claim, envelope
}

// workNativeCarry is the app carrier: pending, claim, deliver, settle.
func workNativeCarry(t *testing.T, from, fromNode, to, toNode string) []map[string]any {
	t.Helper()
	pending, err := workNativeOp(from, fromNode, CommunicationRequest{Operation: "work_native_pending"})
	if err != nil || pending["node_id"] != fromNode {
		t.Fatal("pending", pending, err)
	}
	var settled []map[string]any
	for _, item := range pending["items"].([]map[string]any) {
		if item["peer_node_id"] != toNode {
			t.Fatal("pending item for wrong peer", item)
		}
		id := item["message_id"].(string)
		_, envelope := workNativeClaimEnvelope(t, from, fromNode, id)
		delivered, err := workNativeOp(to, toNode, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
		if err != nil {
			t.Fatal("deliver", err)
		}
		result, err := workNativeOp(from, fromNode, CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: delivered["work_reply"].(string)})
		if err != nil {
			t.Fatal("settle", err)
		}
		settled = append(settled, result)
	}
	return settled
}

func workNativeWorkOrigin() workRequestOrigin {
	return workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
}

func workNativeQueueSend(t *testing.T, a string, link communicationTypedRemoteLink, id, text string) map[string]any {
	t.Helper()
	got, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "send", LinkID: link.ID, MessageID: id, Text: text, ClientToken: workTestToken}, workNativeWorkOrigin())
	if err != nil || got["status"] != "outcome_unknown" || got["carrier"] != "relay_host_channel" {
		t.Fatal("native send must queue for the carrier", got, err)
	}
	return got
}

// resign replaces the envelope payload and re-signs it with the given root's
// identity, so tests can present a well-signed but altered wire.
func workNativeResign(t *testing.T, envelope, root, node string, edit func(*workNativeSend)) string {
	t.Helper()
	payload, _, err := workNativeVerify(envelope, "work", node, "")
	if err != nil {
		t.Fatal(err)
	}
	var send workNativeSend
	if err := json.Unmarshal(payload, &send); err != nil {
		t.Fatal(err)
	}
	edit(&send)
	body, _ := json.Marshal(send)
	signed, err := workNativeSign(root, node, "work", body)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func TestWorkNativeRoundTripBothDirectionsWithoutHTTPS(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "private Work message")
	// The pending record holds the text only until dispatch.
	data, _ := os.ReadFile(workNativePendingPath(a, signedMessage))
	if !bytes.Contains(data, []byte("private Work message")) || paneCalls.Load() != 0 {
		t.Fatal("send must queue, not deliver", string(data), paneCalls.Load())
	}
	settled := workNativeCarry(t, a, "node-a", b, "node-b")
	if len(settled) != 1 || settled[0]["status"] != "accepted_by_provider" || settled[0]["peer_authentication"] != workNativeAuth || paneCalls.Load() != 1 {
		t.Fatal("Work to pane over host channel", settled, paneCalls.Load())
	}
	if _, err := os.Stat(workNativePendingPath(a, signedMessage)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("settled pending record kept", err)
	}
	if got := workNativeCarry(t, a, "node-a", b, "node-b"); len(got) != 0 || paneCalls.Load() != 1 {
		t.Fatal("settled message carried again", got)
	}
	got, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "receipt", LinkID: al.ID, MessageID: signedMessage, ClientToken: workTestToken}, workNativeWorkOrigin())
	if err != nil || got["status"] != "accepted_by_provider" {
		t.Fatal("receipt after settle", got, err)
	}
	// dandy -> Mac: the pane host's outbox is pulled the same way.
	pr := WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: testGroupID, Text: "private pane reply", ClientToken: workTestToken}
	po := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	got, err = executeWorkRequest(context.Background(), b, "node-b", pr, po)
	if err != nil || got["status"] != "outcome_unknown" || workCalls.Load() != 0 {
		t.Fatal("pane send must queue", got, err)
	}
	settled = workNativeCarry(t, b, "node-b", a, "node-a")
	if len(settled) != 1 || settled[0]["status"] != "admitted_not_processed" || workCalls.Load() != 1 {
		t.Fatal("pane to Work over host channel", settled, workCalls.Load())
	}
	for _, p := range []string{workOutboundPath(a, signedMessage), workInboundPath(b, "node-a", signedMessage), workOutboundPath(b, testGroupID), workInboundPath(a, "node-b", testGroupID)} {
		data, e := os.ReadFile(p)
		if e != nil || bytes.Contains(data, []byte("private Work message")) || bytes.Contains(data, []byte(pr.Text)) || bytes.Contains(data, []byte(workTestToken)) {
			t.Fatal("receipt retained payload or credential", p, e)
		}
	}
	// The HTTPS transport refuses a native binding outright.
	if _, err := remotePeerPost(context.Background(), a, "node-a", CommunicationPeerBinding{Endpoint: workNativeEndpoint}, []byte("{}")); !errors.Is(err, errNativePeerRoute) {
		t.Fatal("HTTPS post attempted on native binding", err)
	}
}

func TestWorkNativeNoResendOnUnknown(t *testing.T) {
	a, b, al, _, paneCalls, _ := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "lost in carrier")
	claim, first := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	if claim["operation"] != "send" {
		t.Fatal("first claim must send", claim)
	}
	// The carrier loses the envelope. Every later claim is a receipt query.
	claim, query := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	payload, _, err := workNativeVerify(query, "work", "node-a", "")
	if err != nil || claim["operation"] != "receipt" || bytes.Contains(payload, []byte("lost in carrier")) {
		t.Fatal("second claim resent text", claim, err)
	}
	if data, _ := os.ReadFile(workNativePendingPath(a, signedMessage)); bytes.Contains(data, []byte("lost in carrier")) {
		t.Fatal("dispatched pending record still holds text")
	}
	delivered, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: query})
	if err != nil || paneCalls.Load() != 0 {
		t.Fatal("receipt query delivered", err, paneCalls.Load())
	}
	settled, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: delivered["work_reply"].(string)})
	if err != nil || settled["status"] != "outcome_unknown" {
		t.Fatal("unknown peer outcome must stay unknown", settled, err)
	}
	// A send from the same ID never re-queues the text.
	got, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "lost in carrier", ClientToken: workTestToken}, workNativeWorkOrigin())
	if err != nil || got["status"] != "outcome_unknown" {
		t.Fatal("repeat send", got, err)
	}
	if data, _ := os.ReadFile(workNativePendingPath(a, signedMessage)); bytes.Contains(data, []byte("lost in carrier")) {
		t.Fatal("repeat send re-queued text")
	}
	// The first envelope, if it later arrives, delivers exactly once and the
	// reply settles the sender.
	delivered, err = workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: first})
	if err != nil || paneCalls.Load() != 1 {
		t.Fatal("late envelope", err, paneCalls.Load())
	}
	if _, err = workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: first}); err != nil || paneCalls.Load() != 1 {
		t.Fatal("idempotent message ID delivered twice", err, paneCalls.Load())
	}
	settled, err = workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: delivered["work_reply"].(string)})
	if err != nil || settled["status"] != "accepted_by_provider" {
		t.Fatal("late settle", settled, err)
	}
	// Query polling is bounded and never turns into a resend.
	workNativeQueueSend(t, a, al, workNativeSecondID, "never answered")
	workNativeClaimEnvelope(t, a, "node-a", workNativeSecondID)
	for i := 0; i < workNativeQueryLimit; i++ {
		workNativeClaimEnvelope(t, a, "node-a", workNativeSecondID)
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: workNativeSecondID}); err == nil {
		t.Fatal("receipt polling unbounded")
	}
	if _, err := os.Stat(workNativePendingPath(a, workNativeSecondID)); !errors.Is(err, os.ErrNotExist) || paneCalls.Load() != 1 {
		t.Fatal("exhausted item kept or delivered", err, paneCalls.Load())
	}
}

func TestWorkNativeRejectsWrongHostKeyAndTampering(t *testing.T) {
	a, b, al, _, paneCalls, _ := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "authentic text")
	_, envelope := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	// A different host key that claims to be node-a.
	impostor, _ := peerFixture(t, "node-a")
	forged := workNativeResign(t, envelope, impostor, "node-a", func(*workNativeSend) {})
	if _, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: forged}); err == nil {
		t.Fatal("wrong host key accepted")
	}
	// Payload altered after signing.
	var env workNativeEnvelope
	_ = json.Unmarshal([]byte(envelope), &env)
	payload, _ := base64.StdEncoding.DecodeString(env.Payload)
	env.Payload = base64.StdEncoding.EncodeToString(bytes.Replace(payload, []byte("authentic text"), []byte("tampered text!"), 1))
	tampered, _ := json.Marshal(env)
	if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(string(tampered))); err == nil {
		t.Fatal("tampered payload accepted")
	}
	// Signer node and wire source must agree.
	env.Payload = base64.StdEncoding.EncodeToString(payload)
	env.Node = "node-b"
	renamed, _ := json.Marshal(env)
	if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(string(renamed))); err == nil {
		t.Fatal("renamed signer accepted")
	}
	if paneCalls.Load() != 0 {
		t.Fatal("rejected envelope delivered", paneCalls.Load())
	}
	// A correctly delivered reply signed by the wrong host does not settle.
	delivered, err := workNativeOp(b, "node-b", CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope})
	if err != nil || paneCalls.Load() != 1 {
		t.Fatal("authentic envelope", err)
	}
	replyPayload, _, _ := workNativeVerify(delivered["work_reply"].(string), "reply", "node-b", "")
	other, _ := peerFixture(t, "node-b")
	wrongReply, _ := workNativeSign(other, "node-b", "reply", replyPayload)
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: wrongReply}); err == nil {
		t.Fatal("reply from wrong host key settled")
	}
	// A reply for another message does not settle this one.
	var reply workNativeReply
	_ = json.Unmarshal(replyPayload, &reply)
	reply.MessageID = workNativeSecondID
	body, _ := json.Marshal(reply)
	mismatched, _ := workNativeSign(b, "node-b", "reply", body)
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: mismatched}); err == nil {
		t.Fatal("mismatched reply settled")
	}
	got, _ := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "receipt", LinkID: al.ID, MessageID: signedMessage, ClientToken: workTestToken}, workNativeWorkOrigin())
	if got["status"] != "outcome_unknown" {
		t.Fatal("rejected replies changed the receipt", got)
	}
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: delivered["work_reply"].(string)}); err != nil {
		t.Fatal("authentic reply", err)
	}
}

// CommandRequestOrEnvelope builds a delivery request for a raw envelope.
func CommandRequestOrEnvelope(envelope string) CommunicationRequest {
	return CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: envelope}
}

func TestWorkNativeRejectsWrongLinkStaleRevisionWrongCallerAndStaleSource(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string
	}{
		{"route not native on receiver", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			workNativeSetEndpoint(t, b, "127.0.0.1:9")
			return envelope
		}},
		{"unknown link", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			return workNativeResign(t, envelope, a, "node-a", func(s *workNativeSend) {
				s.Wire.LinkID = strings.Repeat("a", 64)
				s.Wire.Fingerprint = workFingerprint(s.Wire)
			})
		}},
		{"stale revision", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			bl.Revision = 2
			if e := communicationAtomic(remoteLinkPath(b, bl.ID), bl); e != nil {
				t.Fatal(e)
			}
			return envelope
		}},
		{"wrong caller", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			bl.AllowedPeerCallers = []string{"44444444-4444-4444-8444-444444444444"}
			if e := communicationAtomic(remoteLinkPath(b, bl.ID), bl); e != nil {
				t.Fatal(e)
			}
			return envelope
		}},
		{"pin changed", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			bl.PeerCertificateSHA256 = strings.Repeat("0", 64)
			if e := communicationAtomic(remoteLinkPath(b, bl.ID), bl); e != nil {
				t.Fatal(e)
			}
			return envelope
		}},
		{"stale source attestation", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			return workNativeResign(t, envelope, a, "node-a", func(s *workNativeSend) { s.SourceCurrentAt = s.SourceCurrentAt.Add(-3 * time.Minute) })
		}},
		{"missing source attestation", func(t *testing.T, a, b string, bl communicationTypedRemoteLink, envelope string) string {
			return workNativeResign(t, envelope, a, "node-a", func(s *workNativeSend) { s.SourceCurrentAt = time.Time{} })
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, b, al, bl, paneCalls, _ := workNativeFixture(t)
			workNativeQueueSend(t, a, al, signedMessage, "must not deliver")
			_, envelope := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
			if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(c.setup(t, a, b, bl, envelope))); err == nil || paneCalls.Load() != 0 {
				t.Fatal("refused delivery accepted", err, paneCalls.Load())
			}
		})
	}
}

func TestWorkNativeSenderRefusals(t *testing.T) {
	a, _, al, _, _, _ := workNativeFixture(t)
	// Files are refused before any receipt is claimed.
	file := &workAttachment{name: "a.txt", sha256: communicationTextDigest("x"), content: []byte("x")}
	_, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "with file", ClientToken: workTestToken, file: file}, workNativeWorkOrigin())
	if err == nil {
		t.Fatal("file accepted on native route")
	}
	if _, e := os.Stat(workOutboundPath(a, signedMessage)); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("refused file burned the message ID", e)
	}
	// Owner-only carrier operations.
	for _, op := range []string{"work_native_pending", "work_native_claim", "deliver_signed_work", "work_native_settle"} {
		if _, e := workNativeOp(a, "node-a", CommunicationRequest{Operation: op, ClientToken: workTestToken}); e == nil {
			t.Fatal("scoped caller ran", op)
		}
		if _, e := workNativeOp(a, "node-a", CommunicationRequest{Operation: op, ActorPaneID: testGroupB}); e == nil {
			t.Fatal("pane actor ran", op)
		}
	}
	// A paused caller or a changed source endpoint is not dispatched.
	workNativeQueueSend(t, a, al, signedMessage, "held at source")
	var policy communicationPolicy
	_ = communicationRead(communicationPolicyPath(a), &policy)
	paused := policy
	paused.Callers = append([]communicationCaller(nil), policy.Callers...)
	paused.Callers[0].Paused = true
	_ = communicationAtomic(communicationPolicyPath(a), paused)
	if _, e := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage}); e == nil {
		t.Fatal("paused caller dispatched")
	}
	_ = communicationAtomic(communicationPolicyPath(a), policy)
	workObserveEndpoint = func(_ context.Context, e communicationEndpoint) (communicationEndpoint, error) {
		w := *e.Work
		w.Incarnation = "43:999"
		e.Work = &w
		return e, nil
	}
	if _, e := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage}); e == nil {
		t.Fatal("changed source dispatched")
	}
	var p workNativePending
	if e := communicationRead(workNativePendingPath(a, signedMessage), &p); e != nil || p.Dispatched || p.Text != "held at source" {
		t.Fatal("refused claim consumed the message", p, e)
	}
}

func TestWorkNativeWorkOwnerRefusedIsNotSettledAsDelivered(t *testing.T) {
	a, b, _, bl, _, _ := workNativeFixture(t)
	refusals := &atomic.Int32{}
	workRunNativeTarget = func(ctx context.Context, _ nativemsg.Host, _ nativemsg.Target, _ []byte, m *nativemsg.WorkMessage) (map[string]any, error) {
		if err := m.Authorize(ctx); err != nil {
			return nil, err
		}
		refusals.Add(1)
		return nil, errors.New("Work response refused or identity changed")
	}
	pr := WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: testGroupID, Text: "to a refused Work owner", ClientToken: workTestToken}
	po := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if _, err := executeWorkRequest(context.Background(), b, "node-b", pr, po); err != nil {
		t.Fatal(err)
	}
	settled := workNativeCarry(t, b, "node-b", a, "node-a")
	if len(settled) != 1 || settled[0]["status"] != "outcome_unknown" || refusals.Load() != 1 {
		t.Fatal("refused Work owner settled as delivered", settled, refusals.Load())
	}
	// Later passes only query; the refused message is never re-delivered.
	workNativeCarry(t, b, "node-b", a, "node-a")
	if refusals.Load() != 1 {
		t.Fatal("refused message re-delivered", refusals.Load())
	}
}

// Two carriers claiming at once: only one may receive the text.
func TestWorkNativeConcurrentClaimSendsOnce(t *testing.T) {
	a, _, al, _, _, _ := workNativeFixture(t)
	workNativeQueueSend(t, a, al, signedMessage, "claimed twice")
	base := workObserveEndpoint
	var nested map[string]any
	entered := false
	workObserveEndpoint = func(ctx context.Context, e communicationEndpoint) (communicationEndpoint, error) {
		if !entered {
			entered = true
			// A second carrier completes its claim while the first is
			// observing the source outside the lock.
			var err error
			nested, err = workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage})
			if err != nil {
				t.Error("nested claim", err)
			}
		}
		return base(ctx, e)
	}
	outer, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: signedMessage})
	if err != nil || nested == nil {
		t.Fatal(err)
	}
	sends := 0
	for _, claim := range []map[string]any{outer, nested} {
		payload, _, err := workNativeVerify(claim["work_envelope"].(string), "work", "node-a", "")
		if err != nil {
			t.Fatal(err)
		}
		if claim["operation"] == "send" {
			if !bytes.Contains(payload, []byte("claimed twice")) {
				t.Fatal("send claim without its text")
			}
			sends++
		} else if bytes.Contains(payload, []byte("claimed twice")) {
			t.Fatal("receipt query carried text")
		}
	}
	if sends != 1 {
		t.Fatal("text dispatched", sends, "times")
	}
}

func TestWorkNativeBindingTransportSwitchKeepsPinAndRoundTrips(t *testing.T) {
	a, b, al, _, paneCalls, _ := workTransportFixture(t, false)
	var before CommunicationPeerBinding
	_ = communicationRead(filepath.Join(a, "peer-binding-binding.json"), &before)
	httpsEndpoint := before.Endpoint
	switchTo := func(root, node, endpoint string) error {
		_, err := communicationRouteOperation(root, node, CommunicationRequest{Operation: "route_binding_transport_set", TransportBindingID: "binding", PeerBinding: &CommunicationPeerBinding{ID: "binding", Endpoint: endpoint}})
		return err
	}
	// Owner only.
	if _, err := communicationRouteOperation(a, "node-a", CommunicationRequest{Operation: "route_binding_transport_set", ClientToken: workTestToken, TransportBindingID: "binding", PeerBinding: &CommunicationPeerBinding{ID: "binding", Endpoint: workNativeEndpoint}}); err == nil {
		t.Fatal("scoped caller switched transport")
	}
	// Only the native marker or the saved HTTPS endpoint are accepted.
	if err := switchTo(a, "node-a", "203.0.113.9:443"); err == nil {
		t.Fatal("retargeted HTTPS endpoint accepted")
	}
	if err := switchTo(a, "node-a", workNativeEndpoint); err != nil {
		t.Fatal(err)
	}
	if err := switchTo(b, "node-b", workNativeEndpoint); err != nil {
		t.Fatal(err)
	}
	var after CommunicationPeerBinding
	_ = communicationRead(filepath.Join(a, "peer-binding-binding.json"), &after)
	if after.CertificatePEM != before.CertificatePEM || after.PeerNodeID != before.PeerNodeID || after.Endpoint != workNativeEndpoint {
		t.Fatal("switch changed more than the endpoint", after)
	}
	// The existing link works over the host channel without re-linking.
	workNativeQueueSend(t, a, al, signedMessage, "after switch")
	if got := workNativeCarry(t, a, "node-a", b, "node-b"); len(got) != 1 || got[0]["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("switched link", got)
	}
	if err := switchTo(a, "node-a", "203.0.113.9:443"); err == nil {
		t.Fatal("restore to an unsaved endpoint accepted")
	}
	if err := switchTo(a, "node-a", httpsEndpoint); err != nil {
		t.Fatal("rollback", err)
	}
	_ = communicationRead(filepath.Join(a, "peer-binding-binding.json"), &after)
	if after != before {
		t.Fatal("rollback did not restore the binding", after)
	}
}
