package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/nativemsg"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const workTestToken = "isolated-work-transport-credential"
const workTestCaller = "33333333-3333-4333-8333-333333333333"
const workTestThread = "44444444-4444-4444-8444-444444444444"
const workTestSession = "55555555-5555-4555-8555-555555555555"

func workTransportFixture(t *testing.T, dropReply bool) (string, string, communicationTypedRemoteLink, communicationTypedRemoteLink, *atomic.Int32, *atomic.Int32) {
	t.Helper()
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	work := communicationEndpoint{NodeID: "node-a", Kind: "work", Work: &nativemsg.WorkEndpoint{Thread: workTestThread, Owner: "owner", Incarnation: "42:123"}}
	pane := communicationEndpoint{NodeID: "node-b", Kind: "pane", PaneID: testGroupB, Provider: "codex", SessionID: workTestSession}
	oldObserve, oldPaneObserve, oldPaneSend, oldRun, oldSign := workObserveEndpoint, workPaneObserve, workPaneSend, workRunNativeTarget, workSignPane
	t.Cleanup(func() {
		workObserveEndpoint = oldObserve
		workPaneObserve = oldPaneObserve
		workPaneSend = oldPaneSend
		workRunNativeTarget = oldRun
		workSignPane = oldSign
	})
	workObserveEndpoint = func(_ context.Context, e communicationEndpoint) (communicationEndpoint, error) { return e, nil }
	workPaneObserve = func(id string) communicationMember {
		return communicationMember{PaneID: id, PID: 4242, Start: "123", Provider: pane.Provider, SessionID: pane.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}
	paneCalls, workCalls := &atomic.Int32{}, &atomic.Int32{}
	workPaneSend = func(id string, p map[string]any) (map[string]any, error) {
		if id != pane.PaneID {
			t.Error("wrong target", id)
		}
		source := p["source"].(map[string]any)
		if source["authentication"] != "source_work_host_attested" || source["workThread"] != workTestThread || source["paneID"] != nil {
			t.Error("incorrect Work origin", source)
		}
		paneCalls.Add(1)
		return map[string]any{"status": "accepted_by_provider"}, nil
	}
	workRunNativeTarget = func(ctx context.Context, _ nativemsg.Host, target nativemsg.Target, packet []byte, m *nativemsg.WorkMessage) (map[string]any, error) {
		if target.Kind != "work" || target.Work == nil || target.Work.Thread != workTestThread || len(packet) != 0 {
			t.Error("incorrect Work destination", target)
		}
		if err := m.Authorize(ctx); err != nil {
			return nil, err
		}
		workCalls.Add(1)
		return map[string]any{"status": "admitted_not_processed"}, nil
	}
	workSignPane = func(root, node, caller string, r WorkRequest, origin workRequestOrigin, link communicationTypedRemoteLink) (string, error) {
		d := defaultCommunicationSigningDeps(root, node)
		d.observe = func(string) communicationMember {
			return communicationMember{PaneID: pane.PaneID, PID: 4242, Start: "123", Provider: pane.Provider, SessionID: pane.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
		}
		request := CommunicationRequest{Operation: "remote_send", SourcePaneID: origin.pane, ActorPaneID: origin.pane, MessageID: r.MessageID, Text: r.Text, ClientID: caller, actorVerified: true}
		return communicationSignWork(root, node, request, link.Peer.NodeID, link.ID, link.Revision, link.PeerRevision, *link.Peer.Work, d)
	}
	server := func(root, node string, drop bool) *httptest.Server {
		h := peerHandler(root, node, communicationGroupNative{})
		if drop {
			base := h
			h = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				data, _ := io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewReader(data))
				var wire workWire
				_ = json.Unmarshal(data, &wire)
				if wire.Version == 3 && wire.Operation == "send" {
					rec := httptest.NewRecorder()
					base.ServeHTTP(rec, r)
					c, _, e := w.(http.Hijacker).Hijack()
					if e != nil {
						t.Error(e)
						return
					}
					_ = c.Close()
					return
				}
				base.ServeHTTP(w, r)
			})
		}
		s := httptest.NewUnstartedServer(h)
		var e error
		s.TLS, e = peerServerTLS(root, node)
		if e != nil {
			t.Fatal(e)
		}
		s.Config.ErrorLog = log.New(io.Discard, "", 0)
		s.StartTLS()
		t.Cleanup(s.Close)
		return s
	}
	as := server(a, "node-a", false)
	bs := server(b, "node-b", dropReply)
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(bs.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", strings.TrimPrefix(as.URL, "https://"), acert)
	ac, _ := peerCertificate(acert, "node-a")
	bc, _ := peerCertificate(bcert, "node-b")
	stamp := time.Now().UTC()
	id := communicationEndpointPairID(work, pane)
	al := communicationTypedRemoteLink{Version: 2, ID: id, Local: work, Peer: pane, RouteID: "route", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(bc), AllowedPeerCallers: []string{workTestCaller}, Revision: 1, PeerRevision: 1, CreatedAt: stamp, UpdatedAt: stamp}
	bl := al
	bl.Local = pane
	bl.Peer = work
	bl.PeerCertificateSHA256 = peerFingerprint(ac)
	digest := sha256.Sum256([]byte(workTestToken))
	policy := communicationPolicy{Callers: []communicationCaller{{ID: workTestCaller, Label: "Work transport fixture", TokenHash: hex.EncodeToString(digest[:])}}}
	for _, root := range []string{a, b} {
		if e := communicationAtomic(communicationPolicyPath(root), policy); e != nil {
			t.Fatal(e)
		}
	}
	if e := communicationAtomic(remoteLinkPath(a, id), al); e != nil {
		t.Fatal(e)
	}
	if e := communicationAtomic(remoteLinkPath(b, id), bl); e != nil {
		t.Fatal(e)
	}
	return a, b, al, bl, paneCalls, workCalls
}

func TestWorkTransportRealMTLSRoundTripAndNoReplay(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workTransportFixture(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	wr := WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "private Work message", ClientToken: workTestToken}
	wo := workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
	result, err := executeWorkRequest(ctx, a, "node-a", wr, wo)
	if err != nil || result["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("Work to pane", result, err, paneCalls.Load())
	}
	result, err = executeWorkRequest(ctx, a, "node-a", wr, wo)
	if err != nil || paneCalls.Load() != 1 {
		t.Fatal("duplicate replayed", result, err)
	}
	wr.Text = "conflicting text"
	if _, err = executeWorkRequest(ctx, a, "node-a", wr, wo); err == nil {
		t.Fatal("same ID changed text accepted")
	}
	pr := WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: testGroupID, Text: "private pane reply", ClientToken: workTestToken}
	po := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	result, err = executeWorkRequest(ctx, b, "node-b", pr, po)
	if err != nil || result["status"] != "admitted_not_processed" || workCalls.Load() != 1 {
		t.Fatal("pane to Work", result, err, workCalls.Load())
	}
	for _, p := range []string{workOutboundPath(a, wr.MessageID), workInboundPath(b, "node-a", wr.MessageID), workOutboundPath(b, pr.MessageID), workInboundPath(a, "node-b", pr.MessageID)} {
		data, e := os.ReadFile(p)
		if e != nil || bytes.Contains(data, []byte("private Work message")) || bytes.Contains(data, []byte(pr.Text)) || bytes.Contains(data, []byte(workTestToken)) {
			t.Fatal("receipt retained payload or credential", p, e)
		}
	}
}
func TestWorkTransportLostReplyReconcilesOriginalReceipt(t *testing.T) {
	a, _, al, _, calls, _ := workTransportFixture(t, true)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	r := WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "lost reply", ClientToken: workTestToken}
	o := workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
	got, e := executeWorkRequest(ctx, a, "node-a", r, o)
	if e != nil || got["status"] != "outcome_unknown" || calls.Load() != 1 {
		t.Fatal(got, e, calls.Load())
	}
	got, e = executeWorkRequest(ctx, a, "node-a", r, o)
	if e != nil || calls.Load() != 1 {
		t.Fatal("unknown replayed", got, e)
	}
	r.Operation = "receipt"
	r.Text = ""
	got, e = executeWorkRequest(ctx, a, "node-a", r, o)
	if e != nil || got["status"] != "accepted_by_provider" || calls.Load() != 1 {
		t.Fatal("receipt recovery", got, e, calls.Load())
	}
}
func TestWorkTransportRejectsWrongOriginAndStaleEndpoint(t *testing.T) {
	a, _, al, _, calls, _ := workTransportFixture(t, false)
	r := WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "must not send", ClientToken: workTestToken}
	for _, o := range []workRequestOrigin{{thread: workTestSession, revalidate: func() error { return nil }}, {thread: workTestThread, applicationPID: 42, revalidate: func() error { return errors.New("pipe replaced") }}} {
		if _, e := executeWorkRequest(context.Background(), a, "node-a", r, o); e == nil {
			t.Fatal("invalid origin accepted")
		}
	}
	workObserveEndpoint = func(_ context.Context, e communicationEndpoint) (communicationEndpoint, error) {
		if e.Kind == "work" {
			w := *e.Work
			w.Incarnation = "changed"
			e.Work = &w
		}
		return e, nil
	}
	if _, e := executeWorkRequest(context.Background(), a, "node-a", r, workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}); e == nil {
		t.Fatal("stale endpoint accepted")
	}
	if calls.Load() != 0 {
		t.Fatal("unauthorized native send", calls.Load())
	}
}
func TestWorkTransportRejectsCallerPauseAndBadPaneProof(t *testing.T) {
	a, b, al, bl, calls, workCalls := workTransportFixture(t, false)
	policy := communicationPolicy{Callers: []communicationCaller{{ID: workTestCaller, Label: "fixture", TokenHash: strings.Repeat("a", 64), Paused: true}}}
	if e := communicationAtomic(communicationPolicyPath(a), policy); e != nil {
		t.Fatal(e)
	}
	r := WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "refuse", ClientToken: workTestToken}
	if _, e := executeWorkRequest(context.Background(), a, "node-a", r, workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}); e == nil {
		t.Fatal("paused caller accepted")
	}
	m := workWire{Version: 3, Operation: "send", LinkID: bl.ID, Source: bl.Local, Target: bl.Peer, SourceRevision: 1, TargetRevision: 1, Caller: workTestCaller, MessageID: testGroupID, Text: "fake pane", TextSHA256: communicationTextDigest("fake pane"), PaneSignature: "forged"}
	m.Fingerprint = workFingerprint(m)
	if _, e := workReceive(context.Background(), a, "node-a", al.PeerCertificateSHA256, m); e == nil {
		t.Fatal("forged pane proof accepted")
	}
	if calls.Load() != 0 || workCalls.Load() != 0 {
		t.Fatal("unauthorized delivery")
	}
	_ = b
}
func TestWorkTransportStrictSourceAndDuplicateKeyBoundary(t *testing.T) {
	for _, raw := range []string{`{"operation":"status","link_id":"` + strings.Repeat("a", 64) + `","source_pane_id":"` + testGroupB + `"}`, `{"operation":"status","operation":"send","link_id":"` + strings.Repeat("a", 64) + `"}`} {
		var r WorkRequest
		if communicationStrictWorkJSONLimit([]byte(raw), &r, 128<<10) == nil {
			t.Fatal("ambiguous or source override accepted", raw)
		}
	}
}

func TestWorkPaneSignerSuppliesKernelActorForReconciliation(t *testing.T) {
	old := workReconcilePaneActor
	defer func() { workReconcilePaneActor = old }()
	sentinel := errors.New("reconciliation reached")
	seen := false
	workReconcilePaneActor = func(r CommunicationRequest, pid int) (CommunicationRequest, error) {
		seen = true
		if r.ActorPaneID != testGroupB || r.SourcePaneID != testGroupB || r.actorVerified || pid <= 1 {
			t.Fatal("pane signing bypassed or omitted actor verification", r.ActorPaneID, r.SourcePaneID, pid)
		}
		return r, sentinel
	}
	_, e := workSignPane(t.TempDir(), "node-b", workTestCaller, WorkRequest{MessageID: signedMessage, Text: "actor regression", ClientToken: workTestToken}, workRequestOrigin{pane: testGroupB}, communicationTypedRemoteLink{})
	if !seen || !errors.Is(e, sentinel) {
		t.Fatal("production signer did not reconcile native actor", e)
	}
}
