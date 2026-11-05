package daemon

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func typedWorkReceiveFixture(t *testing.T) (string, *signingHostFixture, communicationTypedRemoteLink, communicationTypedWorkMessage, communicationTypedWorkHooks) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	h := newSigningHost(t, signerNode)
	request := signRequest("private payload")
	target := nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}
	source := communicationEndpoint{NodeID: h.node, Kind: "pane", PaneID: request.SourcePaneID, Provider: h.member.Provider, SessionID: h.member.SessionID}
	destination := communicationEndpoint{NodeID: receiverNode, Kind: "work", Work: &target}
	link := communicationTypedRemoteLink{Version: 2, ID: communicationEndpointPairID(source, destination), Local: destination, Peer: source, RouteID: "route-1", RouteRevision: 1, PeerCertificateSHA256: peerFingerprint(h.keys.cert), AllowedPeerCallers: []string{request.ClientID}, PeerRevision: 3, Revision: 4, CreatedAt: h.clock, UpdatedAt: h.clock}
	proof, err := communicationSignWork(h.root, h.node, request, receiverNode, link.ID, 3, 4, target, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	msg := communicationTypedWorkMessage{Version: 2, LinkID: link.ID, Source: source, Target: destination, SourceLinkRevision: 3, TargetLinkRevision: 4, CallerID: request.ClientID, MessageID: request.MessageID, Text: request.Text, SourceSignature: proof}
	msg.Fingerprint = communicationTypedWorkFingerprint(msg)
	hooks := communicationTypedWorkHooks{
		readAuthorizedLink: func(context.Context, string) (communicationTypedRemoteLink, error) { return link, nil },
		sourceFresh:        func(context.Context, communicationTypedWorkMessage) error { return nil },
		observeWork:        func(context.Context, string) (nativemsg.WorkEndpoint, error) { return target, nil },
		deliverWork: func(ctx context.Context, _ nativemsg.WorkEndpoint, _ communicationTypedWorkMessage, guard func(context.Context) error) (map[string]any, error) {
			if err := guard(ctx); err != nil {
				return nil, err
			}
			return map[string]any{"status": "admitted_not_processed"}, nil
		},
		now: func() time.Time { return h.clock },
	}
	return root, h, link, msg, hooks
}

func TestTypedWorkReceiveClaimsOnceAndKeepsReceiptPrivate(t *testing.T) {
	root, h, link, msg, hooks := typedWorkReceiveFixture(t)
	var calls atomic.Int32
	original := hooks.deliverWork
	hooks.deliverWork = func(ctx context.Context, target nativemsg.WorkEndpoint, m communicationTypedWorkMessage, guard func(context.Context) error) (map[string]any, error) {
		calls.Add(1)
		var receipt communicationTypedWorkReceipt
		if err := communicationRead(remoteReceiptPath(root, m.Source.NodeID, m.MessageID), &receipt); err != nil || receipt.Result["status"] != "outcome_unknown" {
			t.Fatal("delivery without durable claim", err)
		}
		if err := communicationFanoutLocked(root, func() error { return nil }); err != nil {
			t.Fatal("metadata lock held across native I/O", err)
		}
		return original(ctx, target, m, guard)
	}
	got, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "admitted_not_processed" || got["replay_permitted"] != false || calls.Load() != 1 {
		t.Fatal(got, err, calls.Load())
	}
	hooks.sourceFresh = func(context.Context, communicationTypedWorkMessage) error { return errors.New("source disappeared") }
	got, err = communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "admitted_not_processed" || calls.Load() != 1 {
		t.Fatal("duplicate did not return receipt", got, err, calls.Load())
	}

	changed := msg
	changed.Text = "different payload"
	request := signRequest(changed.Text)
	proof, err := communicationSignWork(h.root, h.node, request, receiverNode, changed.LinkID, changed.SourceLinkRevision, changed.TargetLinkRevision, *changed.Target.Work, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	changed.SourceSignature = proof
	changed.Fingerprint = communicationTypedWorkFingerprint(changed)
	if _, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, changed, hooks); err == nil || calls.Load() != 1 {
		t.Fatal("same message ID accepted for changed payload", err)
	}
	data, err := os.ReadFile(remoteReceiptPath(root, msg.Source.NodeID, msg.MessageID))
	if err != nil || strings.Contains(string(data), msg.Text) {
		t.Fatal("message text retained", err)
	}
}

func TestTypedWorkReceiveFailsClosedAndNeverReplaysUnknown(t *testing.T) {
	root, _, link, msg, hooks := typedWorkReceiveFixture(t)
	var observations atomic.Int32
	hooks.sourceFresh = func(context.Context, communicationTypedWorkMessage) error { observations.Add(1); return nil }
	bad := msg
	bad.SourceSignature = "invalid"
	if _, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, bad, hooks); err == nil || observations.Load() != 0 {
		t.Fatal("unauthorized request reached observation", err)
	}
	var dispatches atomic.Int32
	hooks.deliverWork = func(context.Context, nativemsg.WorkEndpoint, communicationTypedWorkMessage, func(context.Context) error) (map[string]any, error) {
		dispatches.Add(1)
		return nil, errors.New("ambiguous native write")
	}
	got, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "outcome_unknown" || dispatches.Load() != 1 {
		t.Fatal(got, err)
	}
	got, err = communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "outcome_unknown" || dispatches.Load() != 1 {
		t.Fatal("unknown was replayed", got, err)
	}
}

func TestTypedWorkReceiveConcurrentDuplicateAndLateSourceChange(t *testing.T) {
	root, _, link, msg, hooks := typedWorkReceiveFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	hooks.deliverWork = func(ctx context.Context, _ nativemsg.WorkEndpoint, _ communicationTypedWorkMessage, guard func(context.Context) error) (map[string]any, error) {
		calls.Add(1)
		close(entered)
		<-release
		if err := guard(ctx); err != nil {
			return nil, err
		}
		return map[string]any{"status": "admitted_not_processed"}, nil
	}
	done := make(chan error, 1)
	go func() {
		_, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
		done <- err
	}()
	<-entered
	got, err := communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "outcome_unknown" || calls.Load() != 1 {
		t.Fatal("concurrent duplicate was not held", got, err, calls.Load())
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	got, err = communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "admitted_not_processed" || calls.Load() != 1 {
		t.Fatal("wrong final receipt", got, err)
	}

	root, _, link, msg, hooks = typedWorkReceiveFixture(t)
	calls.Store(0)
	var checks atomic.Int32
	hooks.sourceFresh = func(context.Context, communicationTypedWorkMessage) error {
		if checks.Add(1) > 1 {
			return errors.New("source changed")
		}
		return nil
	}
	hooks.deliverWork = func(ctx context.Context, _ nativemsg.WorkEndpoint, _ communicationTypedWorkMessage, guard func(context.Context) error) (map[string]any, error) {
		calls.Add(1)
		if err := guard(ctx); err != nil {
			return nil, err
		}
		return map[string]any{"status": "admitted_not_processed"}, nil
	}
	got, err = communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "outcome_unknown" || calls.Load() != 1 || checks.Load() != 2 {
		t.Fatal("late source change not held", got, err, calls.Load(), checks.Load())
	}
	got, err = communicationReceiveTypedWork(context.Background(), root, receiverNode, link.PeerCertificateSHA256, msg, hooks)
	if err != nil || got["status"] != "outcome_unknown" || calls.Load() != 1 {
		t.Fatal("held request replayed", got, err)
	}
}

func TestNativeTypedWorkHooksRequireSourceAuthority(t *testing.T) {
	if _, err := communicationNativeTypedWorkHooks(t.TempDir(), receiverNode, nil); err == nil {
		t.Fatal("missing source authority accepted")
	}
	if _, err := communicationNativeTypedWorkHooks(t.TempDir(), receiverNode, func(context.Context, communicationTypedWorkMessage) error { return nil }); err != nil {
		t.Fatal(err)
	}
}
