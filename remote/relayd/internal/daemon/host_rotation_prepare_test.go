package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func preparationStatusFixture(e hostRotationEnrollment) map[string]any {
	obs := func(value any, source string) any { return map[string]any{"value": value, "provenance": source} }
	status := map[string]any{"v": 1, "session_id": e.SessionID, "client": e.Client, "owner": "relay", "cwd": e.CWD,
		"turn_seq": uint64(12), "live": false, "signal": nil, "claim": nil, "intent": nil, "ack": nil,
		"usage": map[string]any{
			"context_tokens": 24000, "context_window": 64000, "model": "fixture-model",
			"session": map[string]any{"turns": 5}, "turn": map[string]any{"input": 1200},
			"in_flight_tool": obs(false, "transcript"), "turn_id_fresh": obs(true, "transcript"),
			"transcript_bytes_at_stop": obs(100, "hook"), "transcript_mtime_ms_at_stop": obs(1000, "hook"),
			"owner": obs("relay", "ledger"), "client": obs(e.Client, "hook"),
		},
	}
	status["usage_history"] = []any{map[string]any{
		"v": 1, "session_id": e.SessionID, "turn_id": "completed-turn",
		"seq": uint64(12), "usage": status["usage"],
	}}
	return status
}

func preparationDraftFixture() hostRotationDraft {
	return hostRotationDraft{Summary: "Preserve the original goal.", Decisions: []string{"Use the same pane."},
		Constraints: []string{"Keep settings."}, PendingWork: []string{"Finish restore."}, NextAction: "Verify source.",
		Uncertainties: []string{}}
}

type preparationHarness struct {
	e             hostRotationEnrollment
	status        map[string]any
	deps          hostRotationPrepareDependencies
	cache         map[string]json.RawMessage
	executions    int
	submits       int
	collects      int
	revalidations int
	changedAfter  int
	failSubmit    int
	failure       string
	badReceipt    bool
	disabled      bool
}

func newPreparationHarness(chunks int) *preparationHarness {
	h := &preparationHarness{e: hostRotationFixture(), cache: map[string]json.RawMessage{}}
	h.status = preparationStatusFixture(h.e)
	h.deps.stage = func(_ context.Context, source hostRotationSource, draft hostRotationDraft) (*hostRotationCapsuleReceipt, error) {
		_, receipt, err := encodeHostRotationCapsule(source, draft)
		return &receipt, err
	}
	h.deps.ledger = func(context.Context, hostRotationEnrollment) (json.RawMessage, error) { return json.Marshal(h.status) }
	h.deps.policy = func(context.Context, json.RawMessage, time.Time) (json.RawMessage, error) {
		return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
	}
	h.deps.collect = func(_ context.Context, e hostRotationEnrollment, b hostRotationSourceBoundary) (hostRotationSource, error) {
		h.collects++
		source := hostRotationSource{Enrollment: e, Boundary: b, BindingRevision: "binding-v1",
			TranscriptSHA256: strings.Repeat("a", 64), EvidenceSHA256: strings.Repeat("b", 64)}
		for i := 0; i < chunks; i++ {
			source.Chunks = append(source.Chunks, fmt.Sprintf(`{"message":%d}`, i+1))
		}
		return source, nil
	}
	h.deps.revalidate = func(context.Context, hostRotationSource) error {
		h.revalidations++
		if h.changedAfter > 0 && h.revalidations >= h.changedAfter {
			return errors.New("fixture source changed")
		}
		return nil
	}
	h.deps.text = func(_ context.Context, operation string, request any) (json.RawMessage, error) {
		if operation == "status" {
			return json.Marshal(map[string]any{"v": 1, "status": "ready", "settings": map[string]any{"enabled": !h.disabled}})
		}
		h.submits++
		if h.failSubmit == h.submits {
			return json.Marshal(map[string]any{"v": 1, "status": "failed", "code": h.failure})
		}
		data, _ := json.Marshal(request)
		var input struct {
			OperationID string                  `json:"operation_id"`
			Binding     hostRotationTextBinding `json:"binding"`
			Evidence    string                  `json:"evidence"`
		}
		if err := json.Unmarshal(data, &input); err != nil {
			return nil, err
		}
		if existing, ok := h.cache[input.OperationID]; ok {
			return existing, nil
		}
		h.executions++
		digest := sha256.Sum256([]byte(input.Evidence))
		binding := input.Binding
		if h.badReceipt {
			binding.TurnSeq++
		}
		result, err := json.Marshal(map[string]any{"v": 1, "status": "complete", "operation_id": input.OperationID,
			"result": map[string]any{"v": 1, "status": "draft", "operation_id": input.OperationID,
				"binding": binding, "source_sha256": hex.EncodeToString(digest[:]), "draft": preparationDraftFixture()}})
		h.cache[input.OperationID] = result
		return result, err
	}
	return h
}

func runPreparationHarness(h *preparationHarness) hostRotationPreparation {
	return prepareHostRotationDraft(context.Background(), h.e, func() error { return nil }, func(hostRotationPreparation) error { return nil }, h.deps)
}

func TestHostRotationPreparationBoundsLedgerObservations(t *testing.T) {
	e := hostRotationFixture()
	data, _ := json.Marshal(preparationStatusFixture(e))
	boundary, err := hostRotationBoundary(data, e)
	if err != nil || boundary.TurnSeq != 12 || boundary.TurnID != "completed-turn" || boundary.TranscriptBytes != 100 || boundary.TranscriptMtimeMS != 1000 {
		t.Fatalf("complete usage rejected: %+v %v", boundary, err)
	}
	for _, field := range []string{"owner", "signal", "claim", "intent", "ack", "in_flight_tool", "turn_id_fresh", "transcript_bytes_at_stop", "transcript_mtime_ms_at_stop"} {
		t.Run(field, func(t *testing.T) {
			status := preparationStatusFixture(e)
			switch field {
			case "owner":
				status[field] = "desktop"
			case "signal", "claim", "intent", "ack":
				status[field] = map[string]any{"exists": true}
			default:
				status["usage"].(map[string]any)[field] = map[string]any{"value": nil, "provenance": "absent"}
			}
			raw, _ := json.Marshal(status)
			if _, err := hostRotationBoundary(raw, e); err == nil {
				t.Fatal("accepted invalid completed boundary")
			}
		})
	}
}

func TestHostRotationPreparationCoversAllChunksAndReusesOperations(t *testing.T) {
	h := newPreparationHarness(5)
	first := runPreparationHarness(h)
	if first.State != "prepared" || first.TurnID != "completed-turn" || first.Draft == nil || first.SourceChunks != 5 || first.CompletedRequests != 6 || h.executions != 6 {
		t.Fatalf("incomplete aggregate: %+v executions %d", first, h.executions)
	}
	second := runPreparationHarness(h)
	if second.State != "prepared" || h.executions != 6 || h.submits != 12 {
		t.Fatalf("completed requests were repeated: %+v %d/%d", second, h.executions, h.submits)
	}
	if first.SourceSHA256 != second.SourceSHA256 || first.TurnSeq != second.TurnSeq {
		t.Fatal("restart changed source binding")
	}
}

func TestHostRotationPreparationRefusesPartialStaleAndMisboundResults(t *testing.T) {
	for _, name := range []string{"budget", "stale", "misbound", "disabled", "persistence"} {
		t.Run(name, func(t *testing.T) {
			h := newPreparationHarness(3)
			publish := func(hostRotationPreparation) error { return nil }
			switch name {
			case "budget":
				h.failSubmit = 2
				h.failure = "spending_limit"
			case "stale":
				h.changedAfter = 2
			case "misbound":
				h.badReceipt = true
			case "disabled":
				h.disabled = true
			case "persistence":
				publish = func(hostRotationPreparation) error { return errors.New("fixture disk failure") }
			}
			result := prepareHostRotationDraft(context.Background(), h.e, func() error { return nil }, publish, h.deps)
			if result.Draft != nil || result.State == "prepared" {
				t.Fatalf("accepted unsafe aggregate: %+v", result)
			}
			switch name {
			case "budget":
				if result.State != "budget_limited" || result.CompletedRequests != 1 || h.submits != 2 {
					t.Fatalf("budget did not stop sequence: %+v", result)
				}
			case "stale":
				if result.State != "discarded" || h.submits != 1 {
					t.Fatalf("stale result accepted: %+v", result)
				}
			case "misbound":
				if result.Code != "text_receipt_binding_mismatch" || h.submits != 1 {
					t.Fatalf("misbound result accepted: %+v", result)
				}
			case "disabled", "persistence":
				if h.submits != 0 || h.collects != 0 {
					t.Fatal("disabled service or disk failure did work")
				}
			}
		})
	}
}

func TestHostRotationPreparationRechecksTurnBeforeEveryRequest(t *testing.T) {
	h := newPreparationHarness(2)
	original := h.deps.text
	h.deps.text = func(ctx context.Context, op string, v any) (json.RawMessage, error) {
		out, err := original(ctx, op, v)
		if op == "submit" {
			h.status["turn_seq"] = uint64(13)
		}
		return out, err
	}
	result := runPreparationHarness(h)
	if result.State != "discarded" || result.Draft != nil || h.submits != 1 {
		t.Fatalf("changed ledger turn accepted: %+v", result)
	}
}

func TestHostRotationPreparationSupervisorCancelsAndRejectsLateResult(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	s := newHostRotationSupervisor(filepath.Join(t.TempDir(), "rotation", "state.json"),
		func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
			return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
		},
		func(ctx context.Context, _ hostRotationEnrollment, guard func() error, publish func(hostRotationPreparation) error) hostRotationPreparation {
			if err := publish(hostRotationPreparation{Version: 1, State: "drafting"}); err != nil {
				return hostRotationPreparation{State: "unavailable"}
			}
			close(started)
			<-ctx.Done()
			close(stopped)
			draft := preparationDraftFixture()
			return hostRotationPreparation{Version: 1, State: "prepared", Draft: &draft}
		})
	defer s.close()
	enrollHostRotation(t, s)
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("automatic preparation did not start")
	}
	s.humanInput()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("preparation not cancelled")
	}
	r := s.snapshot()
	if r.Enabled || r.State != "human_takeover" || r.Preparation != nil {
		t.Fatalf("late draft escaped generation fence: %+v", r)
	}
}

func TestHostRotationPreparationSupervisorPersistsDraft(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rotation", "state.json")
	s := newHostRotationSupervisor(path,
		func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
			return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
		},
		func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation {
			draft := preparationDraftFixture()
			return hostRotationPreparation{Version: 1, State: "prepared", SourceChunks: 1, Draft: &draft}
		})
	defer s.close()
	enrollHostRotation(t, s)
	r := awaitHostRotation(t, s, func(r hostRotationRecord) bool { return r.State == "preparation_prepared" })
	data, err := privatePromptEditorBytes(path, 262144)
	var saved hostRotationRecord
	if err != nil || json.Unmarshal(data, &saved) != nil || saved.Preparation == nil || saved.Preparation.Draft == nil {
		t.Fatal("prepared draft not durable")
	}
	r.Preparation.Draft.Decisions[0] = "modified copy"
	if s.snapshot().Preparation.Draft.Decisions[0] == "modified copy" {
		t.Fatal("snapshot aliases live state")
	}
}

func TestHostRotationPreparationRequiresUsageForExactCompletedTurn(t *testing.T) {
	for _, name := range []string{"missing", "new_turn_without_usage", "wrong_session", "empty_turn_id", "duplicate_sequence", "changed_usage", "numeric_precision"} {
		t.Run(name, func(t *testing.T) {
			h := newPreparationHarness(1)
			rows := h.status["usage_history"].([]any)
			row := rows[0].(map[string]any)
			switch name {
			case "missing":
				delete(h.status, "usage_history")
			case "new_turn_without_usage":
				h.status["turn_seq"] = uint64(13)
			case "wrong_session":
				row["session_id"] = "other-session"
			case "empty_turn_id":
				row["turn_id"] = ""
			case "duplicate_sequence":
				h.status["usage_history"] = append(rows, row)
			case "changed_usage", "numeric_precision":
				copyUsage := map[string]any{}
				for key, value := range h.status["usage"].(map[string]any) {
					copyUsage[key] = value
				}
				copyUsage["context_tokens"] = uint64(9007199254740993)
				if name == "numeric_precision" {
					h.status["usage"].(map[string]any)["context_tokens"] = uint64(9007199254740992)
				}
				row["usage"] = copyUsage
			}
			result := runPreparationHarness(h)
			if result.Code != "completed_turn_unavailable" || h.collects != 0 || h.submits != 0 {
				t.Fatalf("unbound usage reached preparation: %+v collects=%d submits=%d", result, h.collects, h.submits)
			}
		})
	}
}

func TestHostRotationPreparationUsageComparisonPreservesNumbersAndObjectOrder(t *testing.T) {
	left := map[string]json.RawMessage{"observation": json.RawMessage(`{"value":9007199254740992,"provenance":"hook"}`)}
	right := map[string]json.RawMessage{"observation": json.RawMessage(`{ "provenance": "hook", "value": 9007199254740992 }`)}
	if !hostRotationUsageMatches(left, right) {
		t.Fatal("key order changed identity")
	}
	right["observation"] = json.RawMessage(`{"value":9007199254740993,"provenance":"hook"}`)
	if hostRotationUsageMatches(left, right) {
		t.Fatal("distinct integers were rounded together")
	}
}

func TestHostRotationPreparationRejectsChangedNativeTurnWithSameSequence(t *testing.T) {
	h := newPreparationHarness(2)
	original := h.deps.text
	h.deps.text = func(ctx context.Context, operation string, input any) (json.RawMessage, error) {
		result, err := original(ctx, operation, input)
		if operation != "status" {
			rows := h.status["usage_history"].([]any)
			rows[len(rows)-1].(map[string]any)["turn_id"] = "different-native-turn"
		}
		return result, err
	}
	result := runPreparationHarness(h)
	if result.State == "prepared" || h.submits != 1 {
		t.Fatalf("native turn identity changed without stopping preparation: %+v; requests %d", result, h.submits)
	}
}
