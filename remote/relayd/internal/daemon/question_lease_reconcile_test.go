package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// 2026-11-24 dandy-07: a bind's lease_claim was journaled (op 309cc3a1) and
// chitta's reply was a plain reference refusal, which relayd read as an unknown
// outcome. The claim stayed journaled, so every later bind on the thread was
// held as pending_lease with no way to clear it.

func TestDecodeLedgerReferenceRefusalIsAKnownOutcome(t *testing.T) {
	refused := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"unknown thread_sessions reference"}],"isError":true,"structured":null}}`
	_, err := decodeHostNativeLedgerResponse([]byte(refused))
	var refusal *nativeLedgerRefusal
	if !errors.As(err, &refusal) || refusal.Message != "unknown thread_sessions reference" {
		t.Fatalf("reference refusal must be known, got %v", err)
	}
	for _, unknown := range []string{
		// A failure that may come after changes were staged stays unknown.
		`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"WAL append failed"}],"isError":true,"structured":null}}`,
		`{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"unknown threads reference"},{"type":"text","text":"x"}],"isError":true}}`,
		`{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"unknown threads reference"}}`,
	} {
		if _, err := decodeHostNativeLedgerResponse([]byte(unknown)); err == nil || errors.As(err, &refusal) {
			t.Fatalf("%s must stay an unknown outcome, got %v", unknown, err)
		}
	}
}

func TestQuestionRefusedClaimIsResolvedAndLeavesNoOrphan(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	ctx := context.Background()
	base := fx.deps.ledger
	refuse := true
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "lease_claim" && refuse {
			refuse = false
			return nil, &nativeLedgerRefusal{Message: "unknown thread_sessions reference"}
		}
		return base(ctx, op, args)
	}
	_, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
	if err == nil || !strings.Contains(err.Error(), "unknown thread_sessions reference") {
		t.Fatalf("a refused claim must fail the bind with chitta's reason, got %v", err)
	}
	journal, err := fx.deps.loadLeaseJournal()
	if err != nil || len(journal.Ops) != 0 || len(journal.Orphans) != 0 {
		t.Fatalf("a refused claim must leave no mutation or orphan: %+v %v", journal, err)
	}
	bound, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil || bound.LeasePending {
		t.Fatalf("the next bind must claim normally, got pending=%v err=%v", bound.LeasePending, err)
	}
}

type reconcileFixture struct {
	fx      *questionFixture
	op      questionLeaseOp
	rows    []questionLeaseRow
	listErr error
	running int
}

func newReconcileFixture(t *testing.T, kind string) *reconcileFixture {
	t.Helper()
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	rf := &reconcileFixture{fx: newQuestionFixture(t, "codex")}
	id, err := newHostNativeUUID()
	if err != nil {
		t.Fatal(err)
	}
	rf.op = questionLeaseOp{ID: id, Op: kind, SessionID: "sess-1", ThreadID: "thread-1"}
	if err := rf.fx.deps.saveLeaseJournal(questionLeaseJournal{Ops: []questionLeaseOp{rf.op}}); err != nil {
		t.Fatal(err)
	}
	base := rf.fx.deps.ledger
	rf.fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "lease_list" {
			if rf.listErr != nil {
				return nil, rf.listErr
			}
			return json.Marshal(map[string]any{"after": nil, "rows": rf.rows})
		}
		return base(ctx, op, args)
	}
	saved := questionLedgerClientsRunning
	questionLedgerClientsRunning = func() (int, error) { return rf.running, nil }
	t.Cleanup(func() { questionLedgerClientsRunning = saved })
	return rf
}

func (rf *reconcileFixture) journal(t *testing.T) questionLeaseJournal {
	t.Helper()
	journal, err := rf.fx.deps.loadLeaseJournal()
	if err != nil {
		t.Fatal(err)
	}
	return journal
}

func epoch(v uint64) *uint64 { return &v }

func TestReconcileClearsAClaimWhenChittaHoldsNoLease(t *testing.T) {
	rf := newReconcileFixture(t, questionLeaseClaim)
	rf.rows = []questionLeaseRow{{ThreadID: "other-thread", SessionID: "sess-9", LeaseEpoch: epoch(4), ExpiresAt: 1e12}}
	ctx := context.Background()

	dry, err := reconcileQuestionLeaseClaim(ctx, rf.fx.deps, rf.op.ID, false)
	if err != nil || dry.Applied || len(rf.journal(t).Ops) != 1 {
		t.Fatalf("without apply nothing may change: %+v %v", dry, err)
	}
	receipt, err := reconcileQuestionLeaseClaim(ctx, rf.fx.deps, rf.op.ID, true)
	if err != nil || !receipt.Applied || receipt.Observed != nil {
		t.Fatalf("claim with no lease must be cleared: %+v %v", receipt, err)
	}
	if j := rf.journal(t); len(j.Ops) != 0 || len(j.Orphans) != 0 {
		t.Fatalf("journal after reconcile: %+v", j)
	}
	bound, err := bindQuestionThread(ctx, rf.fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil || bound.LeasePending {
		t.Fatalf("bind after reconcile must be confirmed, got pending=%v err=%v", bound.LeasePending, err)
	}
}

func TestReconcileTurnsAnOwnSessionLeaseIntoAFencedOrphan(t *testing.T) {
	rf := newReconcileFixture(t, questionLeaseClaim)
	rf.rows = []questionLeaseRow{{ThreadID: "thread-1", SessionID: "sess-1", LeaseEpoch: epoch(7), ExpiresAt: 1e12}}
	receipt, err := reconcileQuestionLeaseClaim(context.Background(), rf.fx.deps, rf.op.ID, true)
	if err != nil || !receipt.Applied || receipt.OrphanID == "" {
		t.Fatalf("own-session lease must be reconciled into an orphan: %+v %v", receipt, err)
	}
	j := rf.journal(t)
	if len(j.Ops) != 0 || len(j.Orphans) != 1 || j.Orphans[0].LeaseEpoch == nil || *j.Orphans[0].LeaseEpoch != 7 {
		t.Fatalf("orphan must carry the observed epoch: %+v", j)
	}
}

func TestReconcileClearsAClaimThatLostToALiveOwner(t *testing.T) {
	rf := newReconcileFixture(t, questionLeaseClaim)
	now := float64(rf.fx.clock.UnixNano()) / 1e9
	rf.rows = []questionLeaseRow{{ThreadID: "thread-1", SessionID: "sess-9", LeaseEpoch: epoch(3), ExpiresAt: now + 600}}
	receipt, err := reconcileQuestionLeaseClaim(context.Background(), rf.fx.deps, rf.op.ID, true)
	if err != nil || !receipt.Applied || receipt.OrphanID != "" {
		t.Fatalf("a claim that lost to a live owner must be cleared without an orphan: %+v %v", receipt, err)
	}
}

func TestReconcileRefusesWithoutProof(t *testing.T) {
	ctx := context.Background()
	cases := map[string]func(rf *reconcileFixture){
		"expired lease of another session": func(rf *reconcileFixture) {
			rf.rows = []questionLeaseRow{{ThreadID: "thread-1", SessionID: "sess-9", LeaseEpoch: epoch(3), ExpiresAt: 1}}
		},
		"own lease without an epoch": func(rf *reconcileFixture) {
			rf.rows = []questionLeaseRow{{ThreadID: "thread-1", SessionID: "sess-1", ExpiresAt: 1e12}}
		},
		"ledger client still running": func(rf *reconcileFixture) { rf.running = 1 },
		"lease table unavailable":     func(rf *reconcileFixture) { rf.listErr = errors.New("timeout") },
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			rf := newReconcileFixture(t, questionLeaseClaim)
			setup(rf)
			receipt, _ := reconcileQuestionLeaseClaim(ctx, rf.fx.deps, rf.op.ID, true)
			if receipt.Applied || len(rf.journal(t).Ops) != 1 {
				t.Fatalf("must refuse and keep the claim: %+v", receipt)
			}
		})
	}
}

func TestReconcileNeverClearsARelease(t *testing.T) {
	rf := newReconcileFixture(t, questionLeaseRelease)
	receipt, err := reconcileQuestionLeaseClaim(context.Background(), rf.fx.deps, rf.op.ID, true)
	if err != nil || receipt.Applied || !strings.HasPrefix(receipt.Decision, "refused") || len(rf.journal(t).Ops) != 1 {
		t.Fatalf("a release must never be reconciled: %+v %v", receipt, err)
	}
}
