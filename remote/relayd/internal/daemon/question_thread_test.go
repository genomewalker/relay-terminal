package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeQuestionChitta records ledger_op calls and answers from fixed state.
type fakeQuestionChitta struct {
	calls      []string
	ownerLive  string
	generation uint64
	revision   uint64
	rows       []questionEventRow
	eventsErr  error
	releaseErr error
	lastEvents map[string]any
	stateRealm string
}

func (f *fakeQuestionChitta) ledger(_ context.Context, operation string, args any) (json.RawMessage, error) {
	f.calls = append(f.calls, operation)
	switch operation {
	case "session_bind":
		return json.RawMessage(`{"session_id":"sess-1"}`), nil
	case "lease_claim":
		if f.ownerLive != "" {
			return json.Marshal(questionLeaseReply{Claimed: false, Reason: "live_owner", OwnerSessionID: f.ownerLive})
		}
		f.generation++
		return json.Marshal(questionLeaseReply{Claimed: true, Generation: f.generation})
	case "question_state":
		if f.stateRealm == "" {
			return nil, errors.New("question_state unavailable")
		}
		return json.Marshal(map[string]string{"realm": f.stateRealm})
	case "lease_release":
		if f.releaseErr != nil {
			return nil, f.releaseErr
		}
		return json.RawMessage(`{"released":true}`), nil
	case "question_events":
		f.lastEvents = args.(map[string]any)
		if f.eventsErr != nil {
			return nil, f.eventsErr
		}
		return json.Marshal(questionEventsReply{Rows: f.rows, Revision: f.revision})
	}
	return nil, errors.New("unexpected op " + operation)
}

func (f *fakeQuestionChitta) count(operation string) int {
	n := 0
	for _, call := range f.calls {
		if call == operation {
			n++
		}
	}
	return n
}

type questionFixture struct {
	deps    questionThreadDeps
	chitta  *fakeQuestionChitta
	clock   *time.Time
	binding *AgentBindingRecord
	sends   []string
	// recipients records the admitted recipient each native send was given.
	recipients []questionRecipient
	sendErr    error
	notSent    bool
	config     string
}

func newQuestionFixture(t *testing.T, provider string) *questionFixture {
	t.Helper()
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	fx := &questionFixture{chitta: &fakeQuestionChitta{}, clock: &now, config: t.TempDir(),
		binding: &AgentBindingRecord{SessionID: "sess-1", Producer: agentProducer{PaneID: "pane-1", Provider: provider, ProcessID: 42, ProcessStart: 7}}}
	fx.deps = questionThreadDeps{
		ledger:     fx.chitta.ledger,
		binding:    func(string) (AgentBindingRecord, error) { return *fx.binding, nil },
		cwd:        func(string) (string, error) { return "/work", nil },
		store:      questionThreadStore{dir: filepath.Join(t.TempDir(), "question-threads")},
		configHome: fx.config,
		lock:       func() (func(), error) { return func() {}, nil },
		send: func(_ context.Context, _, messageID, text string, admitted questionRecipient) (string, bool, error) {
			fx.sends = append(fx.sends, messageID+"|"+text)
			fx.recipients = append(fx.recipients, admitted)
			return "turn_started", fx.notSent, fx.sendErr
		},
		now: func() time.Time { return *fx.clock },
	}
	return fx
}

func optInPath(t *testing.T, config, session string) string {
	t.Helper()
	path, err := questionClassifierOptInPath(config, session)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func TestQuestionThreadBindClaimsRenewsAndPersists(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	if binding.Generation != 1 || fx.chitta.count("session_bind") != 1 || fx.chitta.count("lease_claim") != 1 {
		t.Fatalf("bind calls %v generation %d", fx.chitta.calls, binding.Generation)
	}
	stored, found, err := fx.deps.store.load("pane-1")
	if err != nil || !found || stored.ThreadID != "thread-a" || stored.Realm != "realm-1" || stored.SessionID != "sess-1" {
		t.Fatalf("stored record %+v found %v err %v", stored, found, err)
	}
	info, err := os.Stat(optInPath(t, fx.config, "sess-1"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("opt-in file %v %v", info, err)
	}
	// Before half the TTL, a tick renews nothing.
	*fx.clock = fx.clock.Add(20 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, binding); err != nil || fx.chitta.count("lease_claim") != 1 {
		t.Fatalf("early renewal calls %v err %v", fx.chitta.calls, err)
	}
	// Past half the TTL, the same session and process renew the lease.
	*fx.clock = fx.clock.Add(15 * time.Second)
	renewed, err := renewQuestionThread(context.Background(), fx.deps, binding)
	if err != nil || fx.chitta.count("lease_claim") != 2 || renewed.Generation != 2 {
		t.Fatalf("renewal calls %v generation %d err %v", fx.chitta.calls, renewed.Generation, err)
	}
}

func TestQuestionThreadRefusesLiveOwnerWithoutForce(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	fx.chitta.ownerLive = "sess-other"
	_, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err == nil || !strings.Contains(err.Error(), "sess-other") {
		t.Fatalf("live owner error %v", err)
	}
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("refused bind persisted a record")
	}
	if _, statErr := os.Stat(optInPath(t, fx.config, "sess-1")); !os.IsNotExist(statErr) {
		t.Fatal("refused bind wrote the classifier opt-in")
	}
	if fx.chitta.count("lease_release") != 0 {
		t.Fatalf("refused bind released a lease it never held: %v", fx.chitta.calls)
	}
}

func TestQuestionThreadReleasesWhenBindingChanges(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	fx.binding.Producer.ProcessStart = 8
	*fx.clock = fx.clock.Add(31 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, binding); err != nil {
		t.Fatal(err)
	}
	if fx.chitta.count("lease_release") != 1 || fx.chitta.count("lease_claim") != 1 {
		t.Fatalf("calls after process change %v", fx.chitta.calls)
	}
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("released binding is still persisted")
	}
	if _, statErr := os.Stat(optInPath(t, fx.config, "sess-1")); !os.IsNotExist(statErr) {
		t.Fatal("release left the classifier opt-in behind")
	}
}

func TestQuestionThreadUnbindRetainsRecordWhenReleaseFails(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60); err != nil {
		t.Fatal(err)
	}
	fx.chitta.releaseErr = errors.New("down")
	if _, err := unbindQuestionThread(context.Background(), fx.deps, "pane-1"); err == nil {
		t.Fatal("unbind hid a failed release")
	}
	if _, found, _ := fx.deps.store.load("pane-1"); !found {
		t.Fatal("failed release dropped the record, so no retry is possible")
	}
	fx.chitta.releaseErr = nil
	if _, err := unbindQuestionThread(context.Background(), fx.deps, "pane-1"); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("retried release left the record")
	}
}

func TestQuestionClassifierOptInCreatesRemovesAndRefusesSymlinks(t *testing.T) {
	config := t.TempDir()
	if err := writeQuestionClassifierOptIn(config, "sess-1"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(optInPath(t, config, "sess-1"))
	if err != nil || string(data) != "on\n" {
		t.Fatalf("opt-in content %q err %v", data, err)
	}
	if err := removeQuestionClassifierOptIn(config, "sess-1"); err != nil {
		t.Fatal(err)
	}
	if err := removeQuestionClassifierOptIn(config, "sess-1"); err != nil {
		t.Fatalf("second remove should be idempotent: %v", err)
	}

	if err := writeQuestionClassifierOptIn(config, "../escape"); err == nil {
		t.Fatal("invalid session accepted")
	}

	// A symlinked leaf is refused and its target untouched.
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	dirPath := filepath.Join(config, "chitta", "prompt-classifier.d")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dirPath, "sess-2")); err != nil {
		t.Fatal(err)
	}
	if err := writeQuestionClassifierOptIn(config, "sess-2"); err == nil {
		t.Fatal("symlinked leaf was followed")
	}
	if data, _ := os.ReadFile(target); string(data) != "keep" {
		t.Fatal("symlink target was overwritten")
	}
	if err := removeQuestionClassifierOptIn(config, "sess-2"); err == nil {
		t.Fatal("symlinked leaf was removed")
	}

	// A symlinked directory component is refused.
	elsewhere := t.TempDir()
	linked := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(linked, "chitta")); err != nil {
		t.Fatal(err)
	}
	if err := writeQuestionClassifierOptIn(linked, "sess-3"); err == nil {
		t.Fatal("symlinked directory component was followed")
	}
	if entries, _ := os.ReadDir(elsewhere); len(entries) != 0 {
		t.Fatal("write escaped through a symlinked directory")
	}
}

func TestQuestionPollRecordsNoticesWithoutSendingThem(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	fx.chitta.revision = 7
	fx.chitta.rows = []questionEventRow{
		{Revision: 5, Op: "job_update", ID: "job-1", ThreadID: "thread-a", Row: map[string]any{"status": "done"}},
		{Revision: 6, Op: "question_note", ThreadID: "thread-a", Row: map[string]any{"kind": "decision"}},
		{Revision: 7, Op: "job_update", ID: "job-2", ThreadID: "thread-b", Row: map[string]any{"status": "done"}},
	}
	if binding, err = pollQuestionThread(context.Background(), fx.deps, binding); err != nil {
		t.Fatal(err)
	}
	if len(fx.sends) != 0 || len(binding.Outbox) != 1 || binding.Cursor != 7 {
		t.Fatalf("poll sends %v outbox %+v cursor %d", fx.sends, binding.Outbox, binding.Cursor)
	}
	stored, _, _ := fx.deps.store.load("pane-1")
	if stored.Cursor != 7 || len(stored.Outbox) != 1 || stored.Outbox[0].Revision != 5 {
		t.Fatalf("persisted state cursor %d outbox %+v", stored.Cursor, stored.Outbox)
	}
	// The same revisions are not recorded again.
	*fx.clock = fx.clock.Add(questionPollInterval)
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "job_update", ID: "job-1", ThreadID: "thread-a", Row: map[string]any{"status": "done"}}}
	if binding, err = pollQuestionThread(context.Background(), fx.deps, binding); err != nil || len(binding.Outbox) != 1 {
		t.Fatalf("duplicate record outbox %+v err %v", binding.Outbox, err)
	}
	if fx.chitta.lastEvents["after_revision"] != uint64(7) || fx.chitta.lastEvents["realm"] != "realm-1" {
		t.Fatalf("poll args %v", fx.chitta.lastEvents)
	}
}

func TestQuestionNoticeDeliveredWhenPromptIsEmptyAndAcked(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	messageID := binding.Outbox[0].MessageID

	reply, err := pullQuestionNotices(fx.deps, []string{"pane-1"})
	if err != nil {
		t.Fatal(err)
	}
	if notices := reply["notices"].([]questionPendingNotice); len(notices) != 1 || notices[0].MessageID != messageID || notices[0].Text == "" {
		t.Fatalf("pull %+v", reply)
	}
	fx.notSent = false
	sent, err := sendQuestionNotice(fx.deps, "pane-1", messageID)
	if err != nil || sent["outcome"] != questionAckDelivered || len(fx.sends) != 1 {
		t.Fatalf("send %+v sends %v err %v", sent, fx.sends, err)
	}
	stored, _, _ := fx.deps.store.load("pane-1")
	if len(stored.Outbox) != 0 || len(stored.Acks) != 1 || stored.Acks[0].Outcome != questionAckDelivered || stored.Acks[0].MessageID != messageID {
		t.Fatalf("receipt and ack not recorded: outbox %+v acks %+v", stored.Outbox, stored.Acks)
	}
	if _, err := sendQuestionNotice(fx.deps, "pane-1", messageID); err == nil || len(fx.sends) != 1 {
		t.Fatalf("delivered notice sent again: sends %v err %v", fx.sends, err)
	}
}

func TestQuestionNoticeHeldForDraftIsRetriedUntilClear(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	messageID := binding.Outbox[0].MessageID

	if _, err := ackQuestionNoticeHeld(fx.deps, "pane-1", messageID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		reply, _ := pullQuestionNotices(fx.deps, []string{"pane-1"})
		if notices := reply["notices"].([]questionPendingNotice); len(notices) != 1 {
			t.Fatalf("held notice not pulled again: %+v", reply)
		}
	}
	if len(fx.sends) != 0 {
		t.Fatalf("held notice was sent: %v", fx.sends)
	}
	// The draft has cleared; the app now sends it, exactly once.
	if _, err := sendQuestionNotice(fx.deps, "pane-1", messageID); err != nil || len(fx.sends) != 1 {
		t.Fatalf("cleared notice not delivered: sends %v err %v", fx.sends, err)
	}
}

func TestQuestionNoticeNotSentStaysQueued(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	messageID := binding.Outbox[0].MessageID
	fx.notSent, fx.sendErr = true, errors.New("pane socket not connected")
	reply, err := sendQuestionNotice(fx.deps, "pane-1", messageID)
	if err != nil || reply["outcome"] != "not_sent" {
		t.Fatalf("not-sent reply %+v err %v", reply, err)
	}
	fx.sendErr = nil
	if pulled, _ := pullQuestionNotices(fx.deps, []string{"pane-1"}); len(pulled["notices"].([]questionPendingNotice)) != 1 {
		t.Fatalf("not-sent notice not pullable again: %+v", pulled)
	}
}

func TestQuestionNoticeOutcomeUnknownIsNeverReplayed(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 4
	fx.chitta.rows = []questionEventRow{{Revision: 4, Op: "job_update", ID: "job-9", ThreadID: "thread-a", Row: map[string]any{"status": "lost"}}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	messageID := binding.Outbox[0].MessageID
	fx.sendErr = errors.New("socket closed after write")
	reply, err := sendQuestionNotice(fx.deps, "pane-1", messageID)
	if err != nil || reply["outcome"] != questionAckOutcomeUnknown {
		t.Fatalf("uncertain send reply %+v err %v", reply, err)
	}
	fx.sendErr = nil
	if pulled, _ := pullQuestionNotices(fx.deps, []string{"pane-1"}); len(pulled["notices"].([]questionPendingNotice)) != 0 {
		t.Fatal("outcome_unknown notice was offered again")
	}
	if _, err := sendQuestionNotice(fx.deps, "pane-1", messageID); err == nil || len(fx.sends) != 1 {
		t.Fatalf("outcome_unknown was replayed: sends %v err %v", fx.sends, err)
	}
	stored, _, _ := fx.deps.store.load("pane-1")
	if stored.Outbox[0].State != questionOutboxOutcomeUnknown || stored.Acks[len(stored.Acks)-1].Outcome != questionAckOutcomeUnknown {
		t.Fatalf("unknown outcome not recorded: %+v acks %+v", stored.Outbox, stored.Acks)
	}
}

func TestQuestionNoticeDroppedWhenBindingNoLongerMatches(t *testing.T) {
	for name, change := range map[string]func(*AgentBindingRecord){
		"session": func(b *AgentBindingRecord) { b.SessionID = "sess-2" },
		"process": func(b *AgentBindingRecord) { b.Producer.ProcessStart = 8 },
	} {
		t.Run(name, func(t *testing.T) {
			fx := newQuestionFixture(t, "codex")
			binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
			fx.chitta.revision = 5
			fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
			binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
			messageID := binding.Outbox[0].MessageID
			change(fx.binding)
			if pulled, _ := pullQuestionNotices(fx.deps, []string{"pane-1"}); len(pulled["notices"].([]questionPendingNotice)) != 0 {
				t.Fatal("notice offered to a changed binding")
			}
			stored, _, _ := fx.deps.store.load("pane-1")
			if len(stored.Outbox) != 0 || len(stored.Acks) != 1 || stored.Acks[0].Outcome != questionAckDropped || stored.Acks[0].Reason != "binding_changed" {
				t.Fatalf("drop not recorded: outbox %+v acks %+v", stored.Outbox, stored.Acks)
			}
			if _, err := sendQuestionNotice(fx.deps, "pane-1", messageID); err == nil || len(fx.sends) != 0 {
				t.Fatalf("dropped notice sent: sends %v err %v", fx.sends, err)
			}
		})
	}
}

func TestQuestionOutboxCrashMidSendDoesNotReplay(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	binding := questionThreadBinding{Version: 1, PaneID: "pane-1", SessionID: "sess-1", Provider: "claude",
		ThreadID: "thread-a", Realm: "realm-1", Cursor: 9,
		Outbox: []questionOutboxEntry{{Revision: 9, MessageID: "m-1", Text: "t", State: questionOutboxSending}}}
	if err := fx.deps.store.save(binding); err != nil {
		t.Fatal(err)
	}
	reloaded, found, err := fx.deps.store.load("pane-1")
	if err != nil || !found || reloaded.Outbox[0].State != questionOutboxOutcomeUnknown {
		t.Fatalf("crash-left entry state %+v found %v err %v", reloaded.Outbox, found, err)
	}
	if pulled, _ := pullQuestionNotices(fx.deps, []string{"pane-1"}); len(pulled["notices"].([]questionPendingNotice)) != 0 || len(fx.sends) != 0 {
		t.Fatal("crash-left entry was offered or sent")
	}
}

func TestQuestionTurnReceiptMapping(t *testing.T) {
	started, err := turnStartedReceipt("msg-1", "turn-abc")
	if err != nil || started.Status != paneReceiptTurnStarted || started.TurnID != "turn-abc" {
		t.Fatalf("started receipt %+v err %v", started, err)
	}
	if _, err := turnStartedReceipt("msg-2", "bad turn/id"); err == nil {
		t.Fatal("invalid turn ID accepted")
	}
	other, _ := turnStartedReceipt("msg-3", "turn-other")
	receipts := []paneTurnReceipt{started, other}
	if n := completeTurnReceipts(receipts, "turn-abc"); n != 1 {
		t.Fatalf("completed %d receipts", n)
	}
	if receipts[0].Status != paneReceiptTurnCompleted || receipts[1].Status != paneReceiptTurnStarted {
		t.Fatalf("receipts after completion %+v", receipts)
	}
	if n := completeTurnReceipts(receipts, ""); n != 0 {
		t.Fatal("empty Stop turn ID completed a receipt")
	}
}

func TestQuestionThreadRefusesRealmMismatchWithChitta(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	fx.chitta.stateRealm = "realm-other"
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60); err == nil {
		t.Fatal("realm mismatch accepted")
	}
	if fx.chitta.count("lease_claim") != 0 {
		t.Fatalf("mismatched bind claimed a lease: %v", fx.chitta.calls)
	}
}

func TestQuestionThreadTickDoesNotResaveReleasedRecord(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60); err != nil {
		t.Fatal(err)
	}
	fx.binding.Producer.ProcessID = 99
	*fx.clock = fx.clock.Add(31 * time.Second)
	tickQuestionThreads(context.Background(), fx.deps)
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("tick re-saved a released binding")
	}
	if fx.chitta.count("question_events") != 0 {
		t.Fatalf("tick polled a released binding: %v", fx.chitta.calls)
	}
}

func TestQuestionTurnReceiptsCompleteOnStopAndLogMismatch(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	result := map[string]any{"message_id": "11111111-1111-4111-8111-111111111111", "status": "accepted_by_provider", "provider_turn_id": "turn-7"}
	markTurnStarted(result)
	if result["status"] != paneReceiptTurnStarted || result["turn_id"] != "turn-7" {
		t.Fatalf("turn_started mapping %+v", result)
	}
	plain := map[string]any{"status": "written_to_socket"}
	markTurnStarted(plain)
	if plain["status"] != "written_to_socket" {
		t.Fatal("non-admitted outcome was relabeled")
	}
	receipt := communicationReceipt{Version: 1, Fingerprint: "f", Result: result}
	if err := communicationAtomic(filepath.Join(root, "message-11111111-1111-4111-8111-111111111111.json"), receipt); err != nil {
		t.Fatal(err)
	}
	if err := recordQuestionTurnStop("turn-unknown"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "turn-mismatch.log")); err != nil {
		t.Fatalf("mismatched Stop was not logged: %v", err)
	}
	if err := recordQuestionTurnStop("turn-7"); err != nil {
		t.Fatal(err)
	}
	var stored communicationReceipt
	if err := communicationRead(filepath.Join(root, "message-11111111-1111-4111-8111-111111111111.json"), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Result["status"] != paneReceiptTurnCompleted {
		t.Fatalf("receipt after Stop %+v", stored.Result)
	}
}

func TestQuestionBindRejectsMalformedTTLAndForeignPane(t *testing.T) {
	for _, ttl := range []string{"+30", "30x", "29", "86401", "1e3"} {
		_, err := communicationQuestionOperation(CommunicationRequest{Operation: "question_bind", SourcePaneID: "pane-1",
			PaneID: "pane-1", ThreadID: "thread-a", Realm: "realm-1", TTL: ttl})
		if err == nil {
			t.Fatalf("ttl %q accepted", ttl)
		}
	}
	if _, err := communicationQuestionOperation(CommunicationRequest{Operation: "question_bind",
		SourcePaneID: "pane-1", PaneID: "pane-2", ThreadID: "thread-a", Realm: "realm-1"}); err == nil {
		t.Fatal("bind to another pane accepted")
	}
}

func TestQuestionNoticeHoldOnlyWithoutVerifiedBinding(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	fx.deps.binding = func(string) (AgentBindingRecord, error) { return AgentBindingRecord{}, errors.New("unavailable") }
	if pulled, _ := pullQuestionNotices(fx.deps, []string{"pane-1"}); len(pulled["notices"].([]questionPendingNotice)) != 0 {
		t.Fatal("notice offered without a verified binding")
	}
	stored, _, _ := fx.deps.store.load("pane-1")
	if len(stored.Outbox) != 1 || len(stored.Acks) != 0 {
		t.Fatalf("unknown binding dropped or acked the notice: %+v %+v", stored.Outbox, stored.Acks)
	}
}

func TestQuestionNoticeAckAcceptsOnlyHeldDraftWithoutSending(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	if _, err := communicationQuestionNoticeAck(CommunicationRequest{Operation: "question_notice_ack", PaneID: "pane-1",
		MessageID: binding.Outbox[0].MessageID, Outcome: questionAckDelivered}); err == nil {
		t.Fatal("delivered accepted as a plain ack")
	}
	if len(fx.sends) != 0 {
		t.Fatal("ack sent a notice")
	}
}

func TestQuestionNoticeTextComesOnlyFromTheOutbox(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	binding, _ := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	fx.chitta.revision = 5
	fx.chitta.rows = []questionEventRow{{Revision: 5, Op: "question_close", ThreadID: "thread-a"}}
	binding, _ = pollQuestionThread(context.Background(), fx.deps, binding)
	if _, err := sendQuestionNotice(fx.deps, "pane-1", "00000000-0000-4000-8000-000000000001"); err == nil {
		t.Fatal("unknown notice sent")
	}
	if _, err := sendQuestionNotice(fx.deps, "pane-1", binding.Outbox[0].MessageID); err != nil {
		t.Fatal(err)
	}
	if fx.sends[0] == "" || strings.Contains(fx.sends[0], "forged") {
		t.Fatalf("sent %q", fx.sends)
	}
}

// A poll that was taken before a send must not restore the notice. The store
// is reloaded under the lock, so a stale snapshot is ignored and the notice is
// sent once, whether the first send was delivered or ended outcome_unknown.
func TestQuestionStalePollDoesNotRestoreSentNotice(t *testing.T) {
	for _, uncertain := range []bool{false, true} {
		name := "delivered"
		if uncertain {
			name = "outcome_unknown"
		}
		t.Run(name, func(t *testing.T) {
			fx := newQuestionFixture(t, "claude")
			binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60)
			if err != nil {
				t.Fatal(err)
			}
			fx.chitta.revision = 1
			fx.chitta.rows = []questionEventRow{{Revision: 1, Op: "question_close", ThreadID: "thread-1"}}
			stale, err := pollQuestionThread(context.Background(), fx.deps, binding)
			if err != nil {
				t.Fatal(err)
			}
			id := stale.Outbox[0].MessageID
			if uncertain {
				fx.sendErr = errors.New("ambiguous native failure")
			}
			if _, err := sendQuestionNotice(fx.deps, "pane-1", id); err != nil {
				t.Fatal(err)
			}
			*fx.clock = fx.clock.Add(31 * time.Second)
			if _, err := pollQuestionThread(context.Background(), fx.deps, stale); err != nil {
				t.Fatal(err)
			}
			fx.sendErr = nil
			if _, err := sendQuestionNotice(fx.deps, "pane-1", id); err == nil {
				t.Fatal("a sent or unknown notice was accepted for a second send")
			}
			if len(fx.sends) != 1 {
				t.Fatalf("notice sent %d times", len(fx.sends))
			}
		})
	}
}

// The opt-in file is never created or removed through a symlinked parent.
func TestQuestionOptInRefusesSymlinkedParentOnCreateAndRemove(t *testing.T) {
	config := t.TempDir()
	outside := t.TempDir()
	if err := os.Mkdir(filepath.Join(outside, "prompt-classifier.d"), 0o700); err != nil {
		t.Fatal(err)
	}
	leaf := filepath.Join(outside, "prompt-classifier.d", "sess-1")
	if err := os.WriteFile(leaf, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(config, "chitta")); err != nil {
		t.Fatal(err)
	}
	if err := removeQuestionClassifierOptIn(config, "sess-1"); err == nil {
		t.Fatal("removal followed a symlinked parent")
	}
	if data, err := os.ReadFile(leaf); err != nil || string(data) != "sentinel" {
		t.Fatalf("file outside the config home was touched: %q %v", data, err)
	}
	if err := writeQuestionClassifierOptIn(config, "sess-2"); err == nil {
		t.Fatal("creation followed a symlinked parent")
	}
	if _, err := os.Stat(filepath.Join(outside, "prompt-classifier.d", "sess-2")); !os.IsNotExist(err) {
		t.Fatal("opt-in was created outside the config home")
	}
}

// A failed opt-in removal keeps the record in the cleanup stage. The next tick
// retries only that cleanup: no lease claim, no lease release, no renewal.
func TestQuestionReleaseFailureRetriesCleanupWithoutReclaiming(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	leaf := optInPath(t, fx.config, "sess-1")
	if err := os.Remove(leaf); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(leaf, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := unbindQuestionThread(context.Background(), fx.deps, "pane-1"); err == nil {
		t.Fatal("expected opt-in removal failure")
	}
	stored, found, err := fx.deps.store.load("pane-1")
	if err != nil || !found || stored.ReleaseStage != questionReleaseCleanup {
		t.Fatalf("record after failed release: found %v stage %q err %v", found, stored.ReleaseStage, err)
	}
	claims, releases := fx.chitta.count("lease_claim"), fx.chitta.count("lease_release")
	*fx.clock = fx.clock.Add(31 * time.Second)
	tickQuestionThreads(context.Background(), fx.deps)
	if fx.chitta.count("lease_claim") != claims || fx.chitta.count("lease_release") != releases {
		t.Fatalf("tick touched the lease again: %v", fx.chitta.calls)
	}
	if err := os.Remove(leaf); err != nil {
		t.Fatal(err)
	}
	tickQuestionThreads(context.Background(), fx.deps)
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("cleanup retry did not finish the release")
	}
	if fx.chitta.count("lease_release") != releases {
		t.Fatal("cleanup retry released the lease a second time")
	}
}

// A notice with an existing delivery claim is refused before any native write.
func TestQuestionDeliveryRefusesExistingClaim(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	messageID := "11111111-2222-4333-8444-555555555555"
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "message-"+messageID+".json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	status, notSent, err := deliverQuestionNotice(context.Background(), "pane-1", messageID, "text", questionRecipient{})
	if err == nil || notSent || status != "" {
		t.Fatalf("existing claim: status %q notSent %v err %v", status, notSent, err)
	}
}

// The state lock excludes a second holder even within one process, which is
// how the poller and an app request in another process are serialized.
func TestQuestionStateLockExcludesSecondHolder(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	unlock, err := lockCommunicationRootForQuestions()
	if err != nil {
		t.Fatal(err)
	}
	acquired := make(chan struct{})
	go func() {
		second, err := lockCommunicationRootForQuestions()
		if err == nil {
			second()
		}
		close(acquired)
	}()
	select {
	case <-acquired:
		t.Fatal("second holder acquired the state lock while the first held it")
	case <-time.After(200 * time.Millisecond):
	}
	unlock()
	select {
	case <-acquired:
	case <-time.After(5 * time.Second):
		t.Fatal("second holder did not acquire the lock after release")
	}
}

// The packets below are the exact bytes RelayQuestionThreadInput emits for the
// pane 11111111-.... Tests/RelayTests/RelayQuestionThreadRouteTests.swift asserts
// the same literals, so the app's route and relayd share one packet contract.
const (
	questionBindPacketFromSwift   = `{"operation":"question_bind","pane_id":"11111111-1111-4111-8111-111111111111","realm":"project:relay","source_pane_id":"11111111-1111-4111-8111-111111111111","thread_id":"q:thread-1","ttl":"900"}`
	questionUnbindPacketFromSwift = `{"operation":"question_unbind","pane_id":"11111111-1111-4111-8111-111111111111","source_pane_id":"11111111-1111-4111-8111-111111111111"}`
)

// The route-to-daemon path: the app's packet decodes into the daemon request,
// passes the own-pane gate, binds, and a foreign caller is refused.
func TestQuestionAppPacketReachesBindAndRefusesForeignPane(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	var request CommunicationRequest
	if err := json.Unmarshal([]byte(questionBindPacketFromSwift), &request); err != nil {
		t.Fatal(err)
	}
	reply, err := questionOperation(context.Background(), fx.deps, request)
	if err != nil {
		t.Fatalf("app bind refused: %v", err)
	}
	if reply["status"] != "bound" || fx.chitta.count("lease_claim") != 1 {
		t.Fatalf("reply %v calls %v", reply, fx.chitta.calls)
	}
	foreign := request
	foreign.SourcePaneID = "22222222-2222-4222-8222-222222222222"
	if _, err := questionOperation(context.Background(), fx.deps, foreign); err == nil || err.Error() != "a question thread binds only the caller's own pane" {
		t.Fatalf("foreign caller not refused: %v", err)
	}
	var unbind CommunicationRequest
	if err := json.Unmarshal([]byte(questionUnbindPacketFromSwift), &unbind); err != nil {
		t.Fatal(err)
	}
	reply, err = questionOperation(context.Background(), fx.deps, unbind)
	if err != nil || reply["status"] != "unbound" {
		t.Fatalf("app unbind: %v %v", reply, err)
	}
}

// assertCommunicationLocksFree fails if another holder has either question
// state or the communication lock. It is called from inside chitta calls, so a
// lock held across an external call is caught where it happens.
func assertCommunicationLocksFree(t *testing.T, operation string) {
	t.Helper()
	for _, name := range []string{"lock", "question-state.lock"} {
		file, err := OpenPrivateFile(filepath.Join(communicationRoot(), name), os.O_RDWR)
		if err != nil {
			continue
		}
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		}
		file.Close()
		if err != nil {
			t.Fatalf("%s runs while %s is held", operation, name)
		}
	}
}

// Chitta calls run with no question or communication lock held, so a stalled
// call cannot block ordinary pane communication.
func TestQuestionChittaCallsRunWithoutLocks(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "claude")
	fx.deps.lock = lockCommunicationRootForQuestions
	inner := fx.deps.ledger
	fx.deps.ledger = func(ctx context.Context, operation string, args any) (json.RawMessage, error) {
		assertCommunicationLocksFree(t, operation)
		return inner(ctx, operation, args)
	}
	binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	fx.chitta.revision = 1
	fx.chitta.rows = []questionEventRow{{Revision: 1, Op: "question_close", ThreadID: "thread-1"}}
	*fx.clock = fx.clock.Add(31 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, binding); err != nil {
		t.Fatal(err)
	}
	tickQuestionThreads(context.Background(), fx.deps)
	if fx.chitta.count("question_events") == 0 {
		t.Fatal("poll never reached chitta")
	}
}

// Each chitta call has its own deadline. A call that never returns cannot hold a tick.
func TestQuestionChittaCallsAreBounded(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	saved := questionCallTimeout
	questionCallTimeout = 20 * time.Millisecond
	t.Cleanup(func() { questionCallTimeout = saved })
	fx.deps.ledger = func(ctx context.Context, _ string, _ any) (json.RawMessage, error) {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("chitta call without a deadline")
		}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	*fx.clock = fx.clock.Add(31 * time.Second)
	done := make(chan struct{})
	go func() {
		tickQuestionThreads(context.Background(), fx.deps)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a stalled chitta call held the tick")
	}
}

// A renewal whose claim lands after an unbind is released again, so the
// unbind's release is not undone by the renewal.
func TestQuestionRenewalDuringUnbindReleasesTheNewClaim(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	binding, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	inner := fx.deps.ledger
	unbound := false
	fx.deps.ledger = func(ctx context.Context, operation string, args any) (json.RawMessage, error) {
		raw, err := inner(ctx, operation, args)
		if operation == "lease_claim" && !unbound {
			unbound = true
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Error(err)
			}
		}
		return raw, err
	}
	*fx.clock = fx.clock.Add(31 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, binding); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("record survived the unbind")
	}
	if fx.chitta.count("lease_release") != 2 {
		t.Fatalf("claim made during unbind was not released: %v", fx.chitta.calls)
	}
}

// The admitted recipient is passed to the native send unchanged.
func TestQuestionSendPassesAdmittedRecipient(t *testing.T) {
	fx := newQuestionFixture(t, "claude")
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	fx.chitta.revision = 1
	fx.chitta.rows = []questionEventRow{{Revision: 1, Op: "question_close", ThreadID: "thread-1"}}
	stale, err := pollQuestionThread(context.Background(), fx.deps, questionThreadBinding{PaneID: "pane-1"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sendQuestionNotice(fx.deps, "pane-1", stale.Outbox[0].MessageID); err != nil {
		t.Fatal(err)
	}
	want := questionRecipient{SessionID: "sess-1", ProcessID: 42, ProcessStart: 7}
	if len(fx.recipients) != 1 || fx.recipients[0] != want {
		t.Fatalf("recipients %+v, want %+v", fx.recipients, want)
	}
}

// If the pane's conversation changes between admission and the native write,
// nothing is submitted. The claim is undone so the notice is held, not replayed.
func TestQuestionDeliveryRefusesRecipientChangedBeforeSubmit(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if err := os.MkdirAll(communicationRoot(), 0o700); err != nil {
		t.Fatal(err)
	}
	savedDiscover, savedBinding, savedSend := questionDiscover, questionVerifiedBinding, questionNativeSend
	t.Cleanup(func() {
		questionDiscover, questionVerifiedBinding, questionNativeSend = savedDiscover, savedBinding, savedSend
	})
	questionDiscover = func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Endpoint: map[string]any{"sessionID": "sess-B"},
			SessionID: "sess-B", PID: 42, Provider: "claude"}
	}
	questionVerifiedBinding = func(string) (AgentBindingRecord, error) {
		return AgentBindingRecord{SessionID: "sess-B", Producer: agentProducer{ProcessID: 42, ProcessStart: 7}}, nil
	}
	questionNativeSend = func(string, map[string]any) (map[string]any, error) {
		t.Fatal("notice was submitted to a pane that is no longer the admitted recipient")
		return nil, nil
	}
	messageID := "22222222-3333-4444-8555-666666666666"
	admitted := questionRecipient{SessionID: "sess-A", ProcessID: 42, ProcessStart: 7}
	status, notSent, err := deliverQuestionNotice(context.Background(), "pane-1", messageID, "text", admitted)
	if err == nil || !notSent || status != "" {
		t.Fatalf("mismatch: status %q notSent %v err %v", status, notSent, err)
	}
	if _, statErr := os.Stat(filepath.Join(communicationRoot(), "message-"+messageID+".json")); !os.IsNotExist(statErr) {
		t.Fatal("refused delivery left a claim behind, so the notice could never be retried")
	}
}

// A renewal that lands after the bind was released and rebound leaves the newer
// bind, its record and its opt-in untouched.
func TestQuestionLateRenewalLeavesReboundBindAlone(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	fx := newQuestionFixture(t, "codex")
	fx.deps.lock = lockCommunicationRootForQuestions
	original, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	inner := fx.deps.ledger
	rebound := false
	var newBinding questionThreadBinding
	fx.deps.ledger = func(ctx context.Context, operation string, args any) (json.RawMessage, error) {
		raw, err := inner(ctx, operation, args)
		if operation == "lease_claim" && !rebound {
			rebound = true
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Error(err)
			}
			if newBinding, err = bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
				t.Error(err)
			}
		}
		return raw, err
	}
	*fx.clock = fx.clock.Add(31 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, original); err != nil {
		t.Fatal(err)
	}
	stored, found, err := fx.deps.loadQuestionState("pane-1")
	if err != nil || !found || stored.Incarnation != newBinding.Incarnation || stored.ReleaseStage != "" {
		t.Fatalf("rebound record changed: found %v stage %q err %v", found, stored.ReleaseStage, err)
	}
	if _, err := os.Stat(optInPath(t, fx.config, "sess-1")); err != nil {
		t.Fatalf("rebound opt-in removed by the late renewal: %v", err)
	}
}

// A renewal whose claim lands after an unbind finished leaves a tombstone, and
// the tombstone's release runs before any new bind can start.
func TestQuestionLateRenewalAfterUnbindReleasesThroughTombstone(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	original, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60)
	if err != nil {
		t.Fatal(err)
	}
	inner := fx.deps.ledger
	unbound := false
	fx.deps.ledger = func(ctx context.Context, operation string, args any) (json.RawMessage, error) {
		raw, err := inner(ctx, operation, args)
		if operation == "lease_claim" && !unbound {
			unbound = true
			if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err != nil {
				t.Error(err)
			}
		}
		return raw, err
	}
	*fx.clock = fx.clock.Add(31 * time.Second)
	if _, err := renewQuestionThread(context.Background(), fx.deps, original); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := fx.deps.store.load("pane-1"); found {
		t.Fatal("tombstone was not released")
	}
	if _, err := os.Stat(optInPath(t, fx.config, "sess-1")); !os.IsNotExist(err) {
		t.Fatal("opt-in survived the tombstone release")
	}
	if fx.chitta.count("lease_release") != 2 {
		t.Fatalf("expected the unbind and the tombstone to each release once: %v", fx.chitta.calls)
	}
}

// A Stop that arrives before its admission is journaled, and the admission
// consumes the journal entry.
func TestQuestionStopJournalIsConsumedByAdmission(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if err := os.MkdirAll(communicationRoot(), 0o700); err != nil {
		t.Fatal(err)
	}
	savedDiscover, savedBinding, savedSend := questionDiscover, questionVerifiedBinding, questionNativeSend
	t.Cleanup(func() {
		questionDiscover, questionVerifiedBinding, questionNativeSend = savedDiscover, savedBinding, savedSend
	})
	questionDiscover = func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Endpoint: map[string]any{"sessionID": "sess-A", "pid": 42}, SessionID: "sess-A", PID: 42}
	}
	questionVerifiedBinding = func(string) (AgentBindingRecord, error) {
		return AgentBindingRecord{SessionID: "sess-A", Producer: agentProducer{ProcessID: 42, ProcessStart: 7}}, nil
	}
	questionNativeSend = func(string, map[string]any) (map[string]any, error) {
		if err := recordQuestionTurnStop("turn-journal"); err != nil {
			t.Fatal(err)
		}
		return map[string]any{"status": "accepted_by_provider", "provider_turn_id": "turn-journal"}, nil
	}
	const id = "33333333-3333-4333-8333-333333333333"
	if _, _, err := deliverQuestionNotice(context.Background(), "pane-1", id, "text", questionRecipient{SessionID: "sess-A", ProcessID: 42, ProcessStart: 7}); err != nil {
		t.Fatal(err)
	}
	var receipt communicationReceipt
	if err := communicationRead(filepath.Join(communicationRoot(), "message-"+id+".json"), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Result["status"] != paneReceiptTurnCompleted {
		t.Fatalf("turn did not complete: %v", receipt.Result["status"])
	}
	if _, err := os.Stat(turnStopJournalPath(communicationRoot(), "turn-journal")); !os.IsNotExist(err) {
		t.Fatal("journal entry survived the admission")
	}
}

// The pull names the panes that hold any binding, so a client can stop
// pulling a host whose agent panes have none.
func TestQuestionNoticePullReportsBoundPanes(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	reply, err := pullQuestionNotices(fx.deps, []string{"pane-1", "pane-2"})
	if err != nil || len(reply["bound"].([]string)) != 0 {
		t.Fatalf("unbound pull %+v %v", reply, err)
	}
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60); err != nil {
		t.Fatal(err)
	}
	reply, err = pullQuestionNotices(fx.deps, []string{"pane-1", "pane-2"})
	if bound := reply["bound"].([]string); err != nil || len(bound) != 1 || bound[0] != "pane-1" {
		t.Fatalf("bound pull %+v %v", reply, err)
	}
}
