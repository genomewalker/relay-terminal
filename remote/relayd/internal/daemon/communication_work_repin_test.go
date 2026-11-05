package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func workRestartFixture(t *testing.T) func(owner, incarnation, thread string, fail error) {
	t.Helper()
	oldPrepare, oldObserve := workPrepareReference, workObserveEndpoint
	t.Cleanup(func() { workPrepareReference, workObserveEndpoint = oldPrepare, oldObserve })
	workPrepareReference = func(context.Context, string) error { return nil }
	return func(owner, incarnation, thread string, fail error) {
		workObserveEndpoint = func(_ context.Context, e communicationEndpoint) (communicationEndpoint, error) {
			if fail != nil {
				return communicationEndpoint{}, fail
			}
			if e.Kind == "work" {
				e.Work = &nativemsg.WorkEndpoint{Thread: thread, Owner: owner, Incarnation: incarnation}
			}
			return e, nil
		}
	}
}

func readWorkLinkFile(t *testing.T, root, id string) communicationTypedRemoteLink {
	t.Helper()
	var link communicationTypedRemoteLink
	if err := communicationRead(remoteLinkPath(root, id), &link); err != nil {
		t.Fatal(err)
	}
	return link
}

func TestWorkRestartRepairRestoresTwoWayDelivery(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workTransportFixture(t, false)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// The Work application restarts: same thread, new owner and incarnation.
	restart("owner-after-restart", "77:456", workTestThread, nil)
	newWork := workRequestOrigin{thread: workTestThread, applicationPID: 77, revalidate: func() error { return nil }}
	pane := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	if _, err := executeWorkRequest(ctx, a, "node-a", WorkRequest{Operation: "send", LinkID: al.ID, MessageID: "before-restart-work", Text: "stale", ClientToken: workTestToken}, newWork); err == nil {
		t.Fatal("stale Work pins accepted the restarted Work")
	}
	if got, _ := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: "before-restart-pane", Text: "stale", ClientToken: workTestToken}, pane); got["status"] == "admitted_not_processed" || workCalls.Load() != 0 {
		t.Fatal("stale peer pins delivered", got)
	}

	// Supported repair: one owner command on the Work host, no file edits.
	result, err := repinWorkLink(ctx, a, "node-a", al.ID)
	if err != nil || result["local_changed"] != true || result["peer_status"] != "repinned" {
		t.Fatal("repair", result, err)
	}
	na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID)
	if na.ID != al.ID || nb.ID != bl.ID || na.Local.Work.Incarnation != "77:456" || nb.Peer.Work.Owner != "owner-after-restart" || na.Revision != 1 || nb.PeerRevision != 1 || na.RouteID != al.RouteID || nb.PeerCertificateSHA256 != bl.PeerCertificateSHA256 {
		t.Fatal("re-pin changed more than the pins", na, nb)
	}
	for _, root := range []string{a, b} {
		data, e := os.ReadFile(filepath.Join(root, "work-repin-"+al.ID+".jsonl"))
		if e != nil || !strings.Contains(string(data), `"incarnation":"42:123"`) || !strings.Contains(string(data), `"incarnation":"77:456"`) {
			t.Fatal("audit lacks old and new pins", root, e)
		}
	}

	// Two-way delivery works again under the same link ID.
	if got, err := executeWorkRequest(ctx, a, "node-a", WorkRequest{Operation: "send", LinkID: al.ID, MessageID: "after-repair-work", Text: "hello pane", ClientToken: workTestToken}, newWork); err != nil || got["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("Work to pane after repair", got, err)
	}
	if got, err := executeWorkRequest(ctx, b, "node-b", WorkRequest{Operation: "send", LinkID: bl.ID, MessageID: "after-repair-pane", Text: "hello Work", ClientToken: workTestToken}, pane); err != nil || got["status"] != "admitted_not_processed" || workCalls.Load() != 1 {
		t.Fatal("pane to Work after repair", got, err)
	}

	// Idempotent: a second repair changes nothing.
	if result, err = repinWorkLink(ctx, a, "node-a", al.ID); err != nil || result["local_changed"] != false || result["peer_status"] != "current" {
		t.Fatal("second repair", result, err)
	}
}

func TestWorkRepairRefusesUnprovenIdentity(t *testing.T) {
	a, b, al, bl, _, _ := workTransportFixture(t, false)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	unchanged := func(name string) {
		t.Helper()
		if na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID); !communicationEndpointEqual(na.Local, al.Local) || !communicationEndpointEqual(nb.Peer, bl.Peer) {
			t.Fatal(name, "changed a link")
		}
	}
	restart("", "", "", errors.New("native socket proof failed"))
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil {
		t.Fatal("unproven identity accepted")
	}
	unchanged("failed proof")
	restart("owner-x", "77:456", "66666666-6666-4666-8666-666666666666", nil)
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil {
		t.Fatal("different conversation accepted")
	}
	unchanged("different thread")
	restart("owner-x", "77:456", workTestThread, nil)
	workPrepareReference = func(context.Context, string) error { return errors.New("Work unavailable") }
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil {
		t.Fatal("repair without a refreshed reference accepted")
	}
	unchanged("prepare failed")
	if _, err := repinWorkLink(ctx, b, "node-b", bl.ID); err == nil {
		t.Fatal("repair accepted on the pane host")
	}
	unchanged("pane host")

	// The peer accepts a new pin only from its pinned peer, for the same thread
	// and unchanged relationship.
	m := workWire{Version: 3, Operation: "repin", LinkID: bl.ID, Source: bl.Peer, Target: bl.Local, SourceRevision: 1, TargetRevision: 1, Caller: workRepinCaller, MessageID: "repin-negative", TextSHA256: communicationTextDigest("")}
	m.Source.Work = &nativemsg.WorkEndpoint{Thread: workTestThread, Owner: "forged", Incarnation: "99:1"}
	m.Fingerprint = workFingerprint(m)
	if _, err := workReceive(ctx, b, "node-b", strings.Repeat("0", 64), m); err == nil {
		t.Fatal("re-pin from an unpinned peer accepted")
	}
	stale := m
	stale.SourceRevision = 2
	stale.Fingerprint = workFingerprint(stale)
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, stale); err == nil {
		t.Fatal("re-pin with a different revision accepted")
	}
	carry := m
	carry.Text = "smuggled"
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, carry); err == nil {
		t.Fatal("re-pin carrying a message accepted")
	}
	other := m
	other.Caller = "someone-else"
	other.Fingerprint = workFingerprint(other)
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, other); err == nil {
		t.Fatal("re-pin from a message caller accepted")
	}
	unchanged("peer negatives")
}
