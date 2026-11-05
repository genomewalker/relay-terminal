package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

func countQuestionCalls(calls []string, operation string) int {
	count := 0
	for _, call := range calls {
		if call == operation {
			count++
		}
	}
	return count
}

// A release whose reply never arrives leaves its key unresolved. A rebind on that
// key is held without a claim, and its notices wait, even after the record is gone.
func TestQuestionUnresolvedReleaseHoldsRebindAndNotices(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	fx.deps.lock = lockCommunicationRootForQuestions
	ctx := context.Background()
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	fx.chitta.releaseErr = errors.New("transport timeout")
	if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err == nil {
		t.Fatal("unbind must report the unresolved release")
	}
	fx.chitta.releaseErr = nil
	// The retry resolves its own release and removes the record. The first
	// release still has no reply, so the key stays unresolved.
	tickQuestionThreads(ctx, fx.deps)
	if _, found, _ := fx.deps.loadQuestionState("pane-1"); found {
		t.Fatal("tick retry did not finish the release")
	}
	claimsBefore := countQuestionCalls(fx.chitta.calls, "lease_claim")
	rebound, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	if !rebound.LeasePending || rebound.Generation != 0 {
		t.Fatalf("rebind over an unresolved release must be held: %+v", rebound)
	}
	if countQuestionCalls(fx.chitta.calls, "lease_claim") != claimsBefore {
		t.Fatal("held rebind issued a lease claim on an unresolved key")
	}
	if _, err := sendQuestionNotice(fx.deps, "pane-1", "11111111-2222-4333-8444-555555555555"); err == nil {
		t.Fatal("notice must be held while the lease is not confirmed")
	}
	for i := 0; i < 3; i++ {
		tickQuestionThreads(ctx, fx.deps)
	}
	held, _, _ := fx.deps.loadQuestionState("pane-1")
	if !held.LeasePending || countQuestionCalls(fx.chitta.calls, "lease_claim") != claimsBefore {
		t.Fatalf("held binding was claimed while its key stayed unresolved: %+v", held)
	}
	if len(fx.sends) != 0 {
		t.Fatalf("held binding delivered a notice: %v", fx.sends)
	}
}

// A claim whose outcome is unknown is recorded as an orphan, so its lease is
// released. The unknown claim also keeps its key held for the next bind.
func TestQuestionUnknownClaimIsReleasedAndHoldsKey(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	fx.deps.lock = lockCommunicationRootForQuestions
	ctx := context.Background()
	base := fx.deps.ledger
	failClaim := true
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		reply, err := base(ctx, op, args)
		if op == "lease_claim" && failClaim {
			failClaim = false
			return nil, errors.New("reply lost")
		}
		return reply, err
	}
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err == nil {
		t.Fatal("bind must fail when the claim outcome is unknown")
	}
	tickQuestionThreads(ctx, fx.deps)
	if countQuestionCalls(fx.chitta.calls, "lease_release") == 0 {
		t.Fatal("orphan of the unknown claim was not released")
	}
	bound, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	if !bound.LeasePending {
		t.Fatal("rebind over the unknown claim must be held")
	}
}

// An orphan whose key has a live owner is dropped without any release.
func TestQuestionOrphanNeverReleasesOwnedKey(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	fx.deps.lock = lockCommunicationRootForQuestions
	ctx := context.Background()
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	releasesBefore := countQuestionCalls(fx.chitta.calls, "lease_release")
	if err := fx.deps.saveQuestionOrphan("sess-1", "thread-1", nil); err != nil {
		t.Fatal(err)
	}
	settleQuestionOrphans(ctx, fx.deps)
	if countQuestionCalls(fx.chitta.calls, "lease_release") != releasesBefore {
		t.Fatal("orphan released a key that a live binding owns")
	}
	journal, err := fx.deps.loadLeaseJournal()
	if err != nil || len(journal.Orphans) != 0 {
		t.Fatalf("owned orphan not dropped: %+v err=%v", journal, err)
	}
}

// leaseEpochModel is a ledger model of chitta's lease_epoch contract. With epochs
// on, a claim returns the lease's epoch (kept on same-session renewal), and a
// release that names an epoch removes nothing unless it matches the current one.
// With epochs off, claims carry no epoch and a release removes the lease.
type leaseEpochModel struct {
	base     questionLedger
	epochs   bool
	current  map[string]uint64
	revision uint64
	releases []map[string]any
}

func leaseModelKey(args any) string {
	a := args.(map[string]any)
	return a["session_id"].(string) + "|" + a["thread_id"].(string)
}

func (m *leaseEpochModel) ledger(ctx context.Context, op string, args any) (json.RawMessage, error) {
	switch op {
	case questionLeaseClaim, questionLeaseRelease:
	default:
		return m.base(ctx, op, args)
	}
	raw, err := m.base(ctx, op, args)
	if err != nil {
		return raw, err
	}
	key := leaseModelKey(args)
	if op == questionLeaseClaim {
		var reply questionLeaseReply
		if err := json.Unmarshal(raw, &reply); err != nil || !reply.Claimed {
			return raw, err
		}
		if _, held := m.current[key]; !held {
			m.revision++
			m.current[key] = m.revision
		}
		if !m.epochs {
			return raw, nil
		}
		epoch := m.current[key]
		reply.LeaseEpoch = &epoch
		return json.Marshal(reply)
	}
	m.releases = append(m.releases, args.(map[string]any))
	want, named := args.(map[string]any)["lease_epoch"]
	if m.epochs && named {
		if cur, ok := m.current[key]; !ok || cur != want.(uint64) {
			return json.Marshal(map[string]any{"released": false, "reason": "epoch_mismatch"})
		}
	}
	delete(m.current, key)
	return raw, nil
}

func installLeaseModel(fx *questionFixture, epochs bool) *leaseEpochModel {
	model := &leaseEpochModel{base: fx.deps.ledger, epochs: epochs, current: map[string]uint64{}}
	fx.deps.ledger = model.ledger
	return model
}

// Both modes: the release carries the bound epoch only when chitta returned one,
// and an ordinary unbind completes.
func TestQuestionLeaseEpochSentOnlyWhenReturned(t *testing.T) {
	for _, epochs := range []bool{false, true} {
		t.Run(map[bool]string{false: "no_epoch", true: "epoch"}[epochs], func(t *testing.T) {
			t.Setenv("XDG_STATE_HOME", t.TempDir())
			fx := newQuestionFixture(t, "claude")
			fx.deps.lock = lockCommunicationRootForQuestions
			model := installLeaseModel(fx, epochs)
			ctx := context.Background()
			bound, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
			if err != nil {
				t.Fatal(err)
			}
			if (bound.LeaseEpoch != nil) != epochs {
				t.Fatalf("bound epoch presence = %v, want %v", bound.LeaseEpoch != nil, epochs)
			}
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Fatal(err)
			}
			if len(model.releases) != 1 {
				t.Fatalf("releases = %v", model.releases)
			}
			_, sent := model.releases[0]["lease_epoch"]
			if sent != epochs {
				t.Fatalf("release carried lease_epoch = %v, want %v", sent, epochs)
			}
			if sent && model.releases[0]["lease_epoch"] != *bound.LeaseEpoch {
				t.Fatalf("release epoch %v != bound epoch %d", model.releases[0]["lease_epoch"], *bound.LeaseEpoch)
			}
			if journal, _ := fx.deps.loadLeaseJournal(); len(journal.Ops) != 0 {
				t.Fatalf("journal not resolved: %+v", journal)
			}
		})
	}
}

// Epoch mode: a lease re-granted under a new epoch survives a release that still
// carries the old epoch. The release is a known outcome, so unbind succeeds and
// nothing is retried. Without epochs the same release removes the new lease, which
// is the residual that epochs close.
func TestQuestionStaleEpochReleaseRemovesNothing(t *testing.T) {
	for _, epochs := range []bool{false, true} {
		t.Run(map[bool]string{false: "no_epoch", true: "epoch"}[epochs], func(t *testing.T) {
			t.Setenv("XDG_STATE_HOME", t.TempDir())
			fx := newQuestionFixture(t, "claude")
			fx.deps.lock = lockCommunicationRootForQuestions
			model := installLeaseModel(fx, epochs)
			ctx := context.Background()
			if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
				t.Fatal(err)
			}
			// chitta grants the same key again under a newer epoch.
			model.current["sess-1|thread-1"] = 999
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Fatalf("stale-epoch unbind must complete: %v", err)
			}
			_, live := model.current["sess-1|thread-1"]
			if live != epochs {
				t.Fatalf("re-granted lease survives = %v, want %v", live, epochs)
			}
			if journal, _ := fx.deps.loadLeaseJournal(); len(journal.Ops) != 0 {
				t.Fatalf("epoch mismatch left a retry in the journal: %+v", journal)
			}
		})
	}
}

// A held bind is inert while its lease is unconfirmed: no notice, no poll, no
// opt-in. Confirmation is what writes the opt-in.
func TestQuestionHeldBindIsInertUntilConfirmed(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	fx.deps.lock = lockCommunicationRootForQuestions
	ctx := context.Background()
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	base := fx.deps.ledger
	interleaved := false
	var rebound questionThreadBinding
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "lease_release" && !interleaved {
			interleaved = true
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Fatal(err)
			}
			var err error
			rebound, err = bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
			if err != nil {
				t.Fatal(err)
			}
			if !rebound.LeasePending {
				t.Fatal("rebind over an in-flight release must be held")
			}
			if _, err := os.Stat(optInPath(t, fx.config, "sess-1")); err == nil {
				t.Fatal("held bind wrote its opt-in")
			}
			questionsBefore := countQuestionCalls(fx.chitta.calls, "question_events")
			tickQuestionThreads(ctx, fx.deps)
			if countQuestionCalls(fx.chitta.calls, "question_events") != questionsBefore {
				t.Fatal("held bind polled")
			}
			if _, err := sendQuestionNotice(fx.deps, "pane-1", "11111111-2222-4333-8444-555555555555"); err == nil {
				t.Fatal("held bind delivered a notice")
			}
		}
		return base(ctx, op, args)
	}
	if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
		t.Fatal(err)
	}
	confirmed, found, err := fx.deps.loadQuestionState("pane-1")
	if err != nil || !found || confirmed.LeasePending {
		t.Fatalf("held bind not confirmed after the release resolved: %+v found=%v err=%v", confirmed, found, err)
	}
	if _, err := os.Stat(optInPath(t, fx.config, "sess-1")); err != nil {
		t.Fatalf("confirmed bind did not write its opt-in: %v", err)
	}
	if len(fx.sends) != 0 {
		t.Fatalf("held bind delivered notices: %v", fx.sends)
	}
}

// A release whose reply is lost after chitta executed it. Nothing clears it: a
// successful second release of the record does not prove the first one stopped.
// The key stays held in both modes, and the bind reply says why.
func TestQuestionLostReleaseHoldsInBothModes(t *testing.T) {
	for _, epochs := range []bool{false, true} {
		t.Run(map[bool]string{false: "no_epoch", true: "epoch"}[epochs], func(t *testing.T) {
			t.Setenv("XDG_STATE_HOME", t.TempDir())
			fx := newQuestionFixture(t, "claude")
			fx.deps.lock = lockCommunicationRootForQuestions
			installLeaseModel(fx, epochs)
			ctx := context.Background()
			if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
				t.Fatal(err)
			}
			inner := fx.deps.ledger
			lost := true
			fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
				raw, err := inner(ctx, op, args)
				if op == questionLeaseRelease && lost {
					lost = false
					return nil, errors.New("reply lost after execution")
				}
				return raw, err
			}
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err == nil {
				t.Fatal("unbind must report the lost reply")
			}
			tickQuestionThreads(ctx, fx.deps)
			if _, found, _ := fx.deps.loadQuestionState("pane-1"); found {
				t.Fatal("the record's own retry did not finish the release")
			}
			journal, err := fx.deps.loadLeaseJournal()
			if err != nil || len(journal.Ops) != 1 {
				t.Fatalf("lost release must stay journaled: %+v err=%v", journal.Ops, err)
			}
			reply, err := questionOperation(ctx, fx.deps, CommunicationRequest{Operation: "question_bind",
				PaneID: "pane-1", SourcePaneID: "pane-1", ThreadID: "thread-1", Realm: "work"})
			if err != nil {
				t.Fatal(err)
			}
			if reply["status"] != "pending_lease" || reply["reason"] != questionLeaseUnconfirmedReason || reply["lease_confirmed"] != false {
				t.Fatalf("held bind reply does not explain the hold: %+v", reply)
			}
			for i := 0; i < 3; i++ {
				tickQuestionThreads(ctx, fx.deps)
			}
			held, _, _ := fx.deps.loadQuestionState("pane-1")
			if !held.LeasePending {
				t.Fatal("a second release cleared the unresolved mutation")
			}
		})
	}
}

// If the journal cannot be written, the mutation is not dispatched.
func TestQuestionJournalWriteFailureDispatchesNothing(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "claude")
	fx.deps.lock = lockCommunicationRootForQuestions
	saved := questionJournalSync
	questionJournalSync = func(*os.File) error { return errors.New("disk full") }
	t.Cleanup(func() { questionJournalSync = saved })
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err == nil {
		t.Fatal("bind must fail when the journal cannot be made durable")
	}
	if n := countQuestionCalls(fx.chitta.calls, "lease_claim"); n != 0 {
		t.Fatalf("claim dispatched without a durable journal entry: %d", n)
	}
	if n := countQuestionCalls(fx.chitta.calls, "lease_release"); n != 0 {
		t.Fatalf("release dispatched without a durable journal entry: %d", n)
	}
}
