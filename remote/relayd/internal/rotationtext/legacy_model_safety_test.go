package rotationtext

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

// These sequences exercise real Journal/ledger methods, not a mirror alone.
// The independent model records only admission, unknown hold, abandon and charge.
func TestLegacyBoundedPurposeSafety(t *testing.T) {
	ctx := context.Background()
	statesSeen := map[string]bool{}
	transitions := 0
	for sequence := 0; sequence < 64; sequence++ {
		t.Run(fmt.Sprintf("history-%02d", sequence), func(t *testing.T) {
			j, _ := safetyJournal(t, 100)
			calls := 0
			j.backend = func(_ context.Context, r obj) any {
				calls++
				return obj{"v": int64(1), "operation_id": r["operation_id"], "status": "failed", "code": "request_outcome_unknown"}
			}
			state := [3]string{}
			count := 0
			encoded := sequence
			for step := 0; step < 3; step++ {
				action := encoded % 4
				encoded /= 4
				transitions++
				if action == 2 {
					r := j.Abandon(safetyID(1))
					if state[0] == "" {
						safetyEq(t, r["status"], "not_found")
					} else {
						state[0] = "abandoned"
						safetyEq(t, r["status"], "abandoned")
					}
				} else {
					index := action
					if action == 3 {
						index = 2
					}
					id := safetyID(index + 1)
					held := false
					if state[index] == "" {
						for other, s := range state {
							if s == "uncertain" && (other == index || other == 2 || index == 2) {
								held = true
							}
						}
					}
					var r obj
					code, _ := expectDraft(t, func() {
						switch index {
						case 0:
							r = j.Assist(ctx, safetyAssist(1, 1))
						case 1:
							r = j.Assess(ctx, safetyAssess(2))
						case 2:
							r = j.Submit(ctx, safetySubmit(3, "legacy evidence"))
						}
					})
					if held {
						safetyEq(t, code, "reconciliation_required")
					} else {
						safetyEq(t, code, "")
						if state[index] == "" {
							state[index] = "uncertain"
							count++
						}
						safetyEq(t, r["status"], state[index])
						safetyEq(t, r["operation_id"], id)
					}
				}
				safetyEq(t, calls, count)
				status := j.Status(nil)
				safetyEq(t, status["requests_today"], count)
				safetyEq(t, status["charged_today_microusd"], int64(count)*apiReservationMicroUSD)
				expected := obj{}
				for i, s := range state {
					if s == "uncertain" {
						purpose := []string{"relay_assistant", "pane_health", "legacy"}[i]
						expected[purpose] = []any{safetyID(i + 1)}
					}
				}
				safetyEq(t, status["unresolved_by_purpose"], expected)
				statesSeen[fmt.Sprint(state)] = true
			}
		})
	}
	t.Logf("real code: 64 histories depth 3, %d transitions, %d distinct noninitial modeled states", transitions, len(statesSeen))
}

func TestLegacyTwoActorPurposeInterleavings(t *testing.T) {
	ctx := context.Background()
	schedules := []string{"AABB", "ABAB", "ABBA", "BAAB", "BABA", "BBAA"}
	transitions := 0
	for _, schedule := range schedules {
		t.Run(schedule, func(t *testing.T) {
			first, root := safetyJournal(t, 100)
			second, err := OpenLedgerJournal(ctx, root)
			if err != nil {
				t.Fatal(err)
			}
			defer second.Close()
			calls := 0
			backend := func(_ context.Context, r obj) any {
				calls++
				return obj{"v": int64(1), "operation_id": r["operation_id"], "status": "failed", "code": "request_outcome_unknown"}
			}
			first.backend = backend
			second.backend = backend
			done := [2]int{}
			state := [2]string{}
			for _, actor := range schedule {
				transitions++
				i := 0
				j := first
				if actor == 'B' {
					i = 1
					j = second
				}
				done[i]++
				if done[i] == 1 {
					var r obj
					if i == 0 {
						r = j.Assist(ctx, safetyAssist(1, 1))
					} else {
						r = j.Assess(ctx, safetyAssess(2))
					}
					safetyEq(t, r["status"], "uncertain")
					state[i] = "uncertain"
				} else {
					r := j.Abandon(safetyID(i + 1))
					safetyEq(t, r["status"], "abandoned")
					state[i] = "abandoned"
				}
				count := 0
				for _, s := range state {
					if s != "" {
						count++
					}
				}
				safetyEq(t, calls, count)
				status := j.Status(nil)
				safetyEq(t, status["requests_today"], count)
				safetyEq(t, status["charged_today_microusd"], int64(count)*apiReservationMicroUSD)
				for other, s := range state {
					if s != "" {
						safetyEq(t, j.Status(safetyID(other + 1))["status"], s)
					}
				}
			}
			safetyEq(t, first.Assist(ctx, safetyAssist(1, 1))["status"], "abandoned")
			safetyEq(t, second.Assess(ctx, safetyAssess(2))["status"], "abandoned")
			safetyEq(t, calls, 2)
		})
	}
	t.Logf("real code: all 6 two-actor order-preserving schedules, %d transitions", transitions)
}

func FuzzLegacyNestedRedaction(f *testing.F) {
	f.Add("name", uint8(0))
	f.Add("tool_use_id", uint8(8))
	f.Add("type", uint8(3))
	f.Fuzz(func(t *testing.T, field string, depth uint8) {
		if len(field) > 1024 || !utf8.ValidString(field) {
			return
		}
		key := "sk-ant-api03-FIXTURE12345678901234567890123456"
		if strings.Contains(field, key) {
			return
		}
		var input any = obj{"type": key, "id": key, "role": key, "tool_use_id": key, field: key}
		for n := 0; n < int(depth%9); n++ {
			input = obj{"nested": []any{input, key}}
		}
		messages := []any{obj{"role": "assistant", "content": []any{toolUse("envelope-id", "list_panes", obj{"payload": input})}}}
		out := redactAssistantMessages(messages, key)
		if strings.Contains(compact(out), key) {
			t.Fatal("nested secret escaped redaction")
		}
		block := out[0].(obj)["content"].([]any)[0].(obj)
		safetyEq(t, []any{out[0].(obj)["role"], block["type"], block["id"], block["name"]}, []any{"assistant", "tool_use", "envelope-id", "list_panes"})
		again := redactAssistantMessages(out, key)
		if !pyEqual(out, again) {
			t.Fatal("redaction is not idempotent")
		}
	})
}
