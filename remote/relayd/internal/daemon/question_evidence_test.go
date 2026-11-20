package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
)

func TestQuestionEvidenceReadsExactAttachmentWithoutWrites(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	ctx := context.Background()
	binding, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	path, err := fx.deps.store.path("pane-1")
	if err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fx.deps.lock = func() (func(), error) { t.Fatal("read took the mutation lock"); return nil, nil }
	var calls []string
	realm := "realm-1"
	rows := []questionEvidenceRow{
		{EntryID: "finding", ThreadID: "thread-a", Kind: "evidence", Revision: 1, Verification: "verified",
			Check: json.RawMessage(`{"exit_status":0,"selected_count":1}`)},
		{EntryID: "failed-attempt", ThreadID: "thread-a", Kind: "counter", Revision: 2, Verification: "unverified",
			Check: json.RawMessage(`{"exit_status":2,"selected_count":1}`)},
	}
	fx.deps.ledger = func(_ context.Context, op string, args any) (json.RawMessage, error) {
		calls = append(calls, op)
		if !reflect.DeepEqual(args, map[string]any{"thread_id": "thread-a"}) {
			t.Fatalf("wrong ledger args: %v", args)
		}
		switch op {
		case "question_state":
			return json.Marshal(map[string]any{"question": map[string]string{"thread_id": "thread-a", "realm": realm}})
		case "evidence_get":
			return json.Marshal(map[string]any{"rows": rows})
		}
		t.Fatalf("unexpected ledger operation %s", op)
		return nil, nil
	}
	read := func(request CommunicationRequest, expected string) map[string]any {
		t.Helper()
		got, err := readQuestionEvidence(ctx, fx.deps, request)
		if err != nil || got["status"] != expected {
			t.Fatalf("got %v, %v; expected %s", got, err, expected)
		}
		if expected != "ready" && got["rows"] != nil {
			t.Fatal("rows leaked when attachment or backend was unavailable")
		}
		return got
	}
	request := CommunicationRequest{PaneID: "pane-1"}
	read(request, "attached")
	request.ThreadID, request.Realm, request.QuestionBindingID = binding.ThreadID, binding.Realm, binding.Incarnation
	wrong := request
	wrong.ThreadID = "other-thread"
	read(wrong, "attachment_changed")
	wrong = request
	wrong.QuestionBindingID = "different-incarnation"
	read(wrong, "attachment_changed")
	if len(calls) != 0 {
		t.Fatalf("attachment lookup or mismatch should not touch Chitta, got %v", calls)
	}
	got := read(request, "ready")
	if returned := got["rows"].([]questionEvidenceRow); len(returned) != 2 ||
		returned[0].EntryID != "failed-attempt" || returned[1].Verification != "verified" {
		t.Fatalf("wrong evidence returned: %+v", returned)
	}
	if !reflect.DeepEqual(calls, []string{"question_state", "evidence_get"}) {
		t.Fatalf("unexpected ledger calls: %v", calls)
	}
	realm = "other-realm"
	read(request, "unavailable")
	realm = "realm-1"
	rows[0].ThreadID = "other-thread"
	read(request, "unavailable")
	rows[0].ThreadID = "thread-a"
	for i := uint64(3); i <= 30; i++ {
		rows = append(rows, questionEvidenceRow{EntryID: fmt.Sprintf("extra-%d", i), ThreadID: "thread-a", Kind: "claim", Revision: i})
	}
	got = read(request, "ready")
	if returned := got["rows"].([]questionEvidenceRow); len(returned) != questionEvidenceLimit ||
		got["total"] != 30 || returned[0].Revision != 30 {
		t.Fatalf("unbounded or unordered result: %v", got)
	}
	ledger := fx.deps.ledger
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "evidence_get" {
			replacement := binding
			replacement.Incarnation = "rebound-while-reading"
			if err := fx.deps.store.save(replacement); err != nil {
				t.Fatal(err)
			}
		}
		return ledger(ctx, op, args)
	}
	read(request, "attachment_changed")
	if err := fx.deps.store.save(binding); err != nil {
		t.Fatal(err)
	}
	fx.deps.ledger = func(context.Context, string, any) (json.RawMessage, error) {
		return nil, errors.New("Chitta unavailable")
	}
	read(request, "unavailable")
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) || len(fx.sends) != 0 {
		t.Fatalf("read altered binding or delivered a notice, err=%v sends=%v", err, fx.sends)
	}
}

func TestQuestionEvidenceRequiresOwnerChannel(t *testing.T) {
	request := CommunicationRequest{Operation: "question_evidence", PaneID: "pane-1", ActorPaneID: "pane-1"}
	if !communicationOwnerOperation(request.Operation) || CheckCommunicationOwner(request, 0) == nil {
		t.Fatal("host transport did not apply its existing owner gate")
	}
	if _, err := ExecuteCommunication(request); err == nil {
		t.Fatal("scoped agent reached the evidence operation")
	}
}
