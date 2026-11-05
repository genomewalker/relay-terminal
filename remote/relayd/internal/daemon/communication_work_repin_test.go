package daemon

import (
	"context"
	"errors"
	"net"
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
	m := workWire{Version: 3, Operation: "repin", LinkID: bl.ID, Source: bl.Peer, Target: bl.Local, SourceRevision: 1, TargetRevision: 1, PinGeneration: 1, Caller: workRepinCaller, MessageID: "repin-negative", TextSHA256: communicationTextDigest("")}
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

// A re-pin frame replayed after a later re-pin must be refused, even though it
// is authentic, carries the pinned peer's certificate and matches the unchanged
// revisions.
func TestWorkRepinReplayIsRefused(t *testing.T) {
	a, b, al, bl, _, _ := workTransportFixture(t, false)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	frame := func(owner, incarnation string, generation uint64) workWire {
		m := workWire{Version: 3, Operation: "repin", LinkID: bl.ID, Source: bl.Peer, Target: bl.Local, SourceRevision: 1, TargetRevision: 1, PinGeneration: generation, Caller: workRepinCaller, MessageID: "replay-" + owner, TextSHA256: communicationTextDigest("")}
		m.Source.Work = &nativemsg.WorkEndpoint{Thread: workTestThread, Owner: owner, Incarnation: incarnation}
		m.Fingerprint = workFingerprint(m)
		return m
	}

	restart("owner-1", "77:1", workTestThread, nil)
	if r, err := repinWorkLink(ctx, a, "node-a", al.ID); err != nil || r["peer_status"] != "repinned" {
		t.Fatal("first re-pin", r, err)
	}
	// The exact frame the work host sent for the first re-pin.
	first := frame("owner-1", "77:1", readWorkLinkFile(t, a, al.ID).PinGeneration)
	restart("owner-2", "88:2", workTestThread, nil)
	if r, err := repinWorkLink(ctx, a, "node-a", al.ID); err != nil || r["peer_status"] != "repinned" {
		t.Fatal("second re-pin", r, err)
	}
	na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID)
	if na.PinGeneration != 2 || nb.PinGeneration != 2 || na.Revision != 1 || nb.PeerRevision != 1 {
		t.Fatal("generations", na.PinGeneration, nb.PinGeneration)
	}
	if first.PinGeneration != 1 {
		t.Fatal("first frame generation", first.PinGeneration)
	}
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, first); err == nil || !strings.Contains(err.Error(), "stale") {
		t.Fatal("replayed older re-pin accepted")
	}
	// Same pins as the stored ones but an older generation are refused too.
	older := frame("owner-2", "88:2", 1)
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, older); err == nil || !strings.Contains(err.Error(), "stale") {
		t.Fatal("older generation with the current pin accepted")
	}
	// Generation zero (a sender that predates the field) is invalid.
	if _, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, frame("owner-3", "99:3", 0)); err == nil {
		t.Fatal("re-pin without a generation accepted")
	}
	if after := readWorkLinkFile(t, b, bl.ID); !communicationEndpointEqual(after.Peer, nb.Peer) || after.PinGeneration != 2 {
		t.Fatal("refused replay changed the peer link", after.Peer.Work, after.PinGeneration)
	}
	// A genuine later re-pin still advances.
	if r, err := workReceive(ctx, b, "node-b", bl.PeerCertificateSHA256, frame("owner-3", "99:3", 3)); err != nil || r["status"] != "repinned" {
		t.Fatal("next generation refused", r, err)
	}
}

// The re-pin identity proof must run before anything is persisted, and must be
// the real native observer, not a stub: with no Work application socket (and
// then with a socket held by a process that is not the Work application) the
// real observer fails and neither the saved reference nor either link changes.
func TestWorkRepinRealObserverRefusesAndPersistsNothing(t *testing.T) {
	a, b, al, bl, _, _ := workTransportFixture(t, false)
	oldPrepare, oldObserve := workPrepareReference, workObserveEndpoint
	t.Cleanup(func() { workPrepareReference, workObserveEndpoint = oldPrepare, oldObserve })
	workObserveEndpoint = observeWorkEndpoint // the real observer
	prepared := 0
	workPrepareReference = func(context.Context, string) error { prepared++; return nil }
	// A unix socket path must stay short, so this home is under /tmp.
	home, err := os.MkdirTemp("/tmp", "wr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	t.Setenv("HOME", home)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	check := func(name string) {
		t.Helper()
		_, observeErr := workObserveEndpoint(ctx, al.Local)
		if observeErr == nil {
			t.Fatal(name, "real observer accepted")
		}
		t.Log(name, "real observer error:", observeErr)
		if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil {
			t.Fatal(name, "re-pin accepted")
		}
		if prepared != 0 {
			t.Fatal(name, "saved reference refreshed before the identity proof")
		}
		if na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID); !communicationEndpointEqual(na.Local, al.Local) || !communicationEndpointEqual(nb.Peer, bl.Peer) || na.PinGeneration != 0 || nb.PinGeneration != 0 {
			t.Fatal(name, "changed a link")
		}
	}
	check("no Work socket")

	// A listening socket at the Work IPC path, owned by this (non-Work) process.
	dir := filepath.Join(home, ".codex", "ipc")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(dir, "ipc.sock"))
	if err != nil {
		t.Skip("cannot create a unix socket here:", err)
	}
	defer listener.Close()
	if err := os.Chmod(filepath.Join(dir, "ipc.sock"), 0o600); err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			c.Close()
		}
	}()
	check("socket held by a non-Work process")
}

// Preparing the native reference happens only after the proof, and a prepare
// failure leaves both links untouched.
func TestWorkRepinPreparesOnlyAfterProof(t *testing.T) {
	a, b, al, bl, _, _ := workTransportFixture(t, false)
	restart := workRestartFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	prepared := 0
	workPrepareReference = func(context.Context, string) error { prepared++; return nil }
	restart("", "", "", errors.New("native socket proof failed"))
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil || prepared != 0 {
		t.Fatal("prepare ran before a failed proof", err, prepared)
	}
	restart("owner-x", "77:456", "66666666-6666-4666-8666-666666666666", nil)
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil || prepared != 0 {
		t.Fatal("prepare ran for another conversation", err, prepared)
	}
	restart("owner-x", "77:456", workTestThread, nil)
	workPrepareReference = func(context.Context, string) error { prepared++; return errors.New("Work unavailable") }
	if _, err := repinWorkLink(ctx, a, "node-a", al.ID); err == nil || !strings.Contains(err.Error(), "link unchanged") || prepared != 1 {
		t.Fatal("prepare failure", err, prepared)
	}
	if na, nb := readWorkLinkFile(t, a, al.ID), readWorkLinkFile(t, b, bl.ID); !communicationEndpointEqual(na.Local, al.Local) || !communicationEndpointEqual(nb.Peer, bl.Peer) {
		t.Fatal("prepare failure changed a link")
	}
}

type workWatchLog struct{ lines []string }

func (w *workWatchLog) Write(p []byte) (int, error) {
	w.lines = append(w.lines, strings.TrimSpace(string(p)))
	return len(p), nil
}

func TestWorkWatchDelayBacksOffAndCaps(t *testing.T) {
	want := []time.Duration{15 * time.Second, 15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 10 * time.Minute, 10 * time.Minute}
	for failures, d := range want {
		if got := workWatchDelay(failures); got != d {
			t.Fatal("delay", failures, got, d)
		}
	}
	if workWatchDelay(1<<30) != workWatchMaxDelay {
		t.Fatal("delay not capped")
	}
}

func TestWorkWatchLogsStateChangesOnlyAndBacksOff(t *testing.T) {
	a, _, al, _, _, _ := workTransportFixture(t, false)
	workRestartFixture(t)
	failing := errors.New("native socket proof failed")
	healthy := false
	workObserveEndpoint = func(_ context.Context, e communicationEndpoint) (communicationEndpoint, error) {
		if !healthy {
			return communicationEndpoint{}, failing
		}
		return e, nil
	}
	log := &workWatchLog{}
	var delays []time.Duration
	sleep := func(d time.Duration) bool {
		delays = append(delays, d)
		if len(delays) == 6 {
			healthy = true
		}
		return len(delays) < 9
	}
	if err := workRepinWatch(a, "node-a", al.ID, log, sleep); err != nil {
		t.Fatal(err)
	}
	if len(delays) != 9 {
		t.Fatal("iterations", delays)
	}
	want := []time.Duration{15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute}
	for i, d := range want {
		if delays[i] != d {
			t.Fatal("backoff", delays)
		}
	}
	for _, d := range delays[6:] {
		if d != workWatchInterval {
			t.Fatal("interval not restored after recovery", delays)
		}
	}
	waiting, recovered := 0, 0
	for _, line := range log.lines {
		if strings.Contains(line, `"waiting"`) {
			waiting++
		}
		if strings.Contains(line, `"recovered":true`) {
			recovered++
		}
	}
	if waiting != 1 || recovered != 1 || len(log.lines) != 2 {
		t.Fatal("watcher logged per poll instead of per state change", log.lines)
	}
}
