package rotationtext

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLegacyPaneHealthSafety(t *testing.T) {
	ctx := context.Background()
	t.Run("test_verified_shell_has_kernel_identity_without_an_agent_session", func(t *testing.T) {
		p := safetyPane(obj{"kind": "shell", "binding": "not_applicable", "activity": "unknown", "allowed_actions": []any{"observe", "attention"}, "session_id": nil})
		rows := []any{p}
		safetyEq(t, validHealthPanes(hostID, snapshotOf(hostID, rows), rows), rows)
	})
	t.Run("test_shell_identity_cannot_be_used_as_agent_repair_authority", func(t *testing.T) {
		for _, mods := range []obj{{"kind": "codex"}, {"session_id": "invented-session"}, {"installed_update": true}, {"allowed_actions": []any{"observe", "repair_link"}}} {
			base := safetyPane(obj{"kind": "shell", "binding": "not_applicable", "activity": "unknown", "allowed_actions": []any{"observe", "attention"}, "session_id": nil})
			for k, v := range mods {
				base[k] = v
			}
			withEvidence(base)
			rows := []any{base}
			safetyRejected(t, func() { validHealthPanes(hostID, snapshotOf(hostID, rows), rows) })
		}
	})
	t.Run("test_rejected_tool_response_keeps_usage_and_never_replays_or_admits_a_tool", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		calls := safetyPost(t, safetyResponse([]any{safetyCall("invented_tool")}))
		r := safetyAssess(1)
		first := j.Assess(ctx, r)
		safetyEq(t, j.Assess(ctx, r), first)
		safetyEq(t, *calls, 1)
		safetyEq(t, first["status"], "failed")
		safetyEq(t, first["charged_microusd"], 25)
		result := first["result"].(obj)
		safetyEq(t, result["code"], "invalid_health_tool_response")
		if _, ok := result["tool_calls"]; ok {
			t.Fatal("failed response admitted tool")
		}
	})
	t.Run("test_unusable_api_usage_keeps_the_full_reservation", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		for n, change := range []obj{{"usage": obj{}}, {"model": "unreviewed-model"}, {"usage": obj{"input_tokens": true, "output_tokens": int64(10)}}} {
			response := parseJSON(safetyResponse([]any{safetyCall("invented_tool")})).(obj)
			for k, v := range change {
				response[k] = v
			}
			safetyPost(t, []byte(compact(response)))
			r := j.Assess(ctx, safetyAssess(n+2, safetyPane(obj{"process_start": int64(458 + n)})))
			safetyEq(t, r["charged_microusd"], apiReservationMicroUSD)
		}
	})
	t.Run("test_failed_usage_cannot_be_rebound_to_another_request", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		j.backend = func(context.Context, obj) any {
			return obj{"v": int64(1), "operation_id": safetyID(1), "status": "failed", "code": "invalid_health_tool_response", "provider": "anthropic_api", "model": apiModel, "usage": obj{"input_tokens": int64(1), "output_tokens": int64(1)}, "binding": obj{"host_id": "wrong-host", "snapshot_id": "wrong-snapshot"}, "source_sha256": strings.Repeat("0", 64)}
		}
		r := j.Assess(ctx, safetyAssess(1))
		safetyEq(t, r["status"], "uncertain")
		safetyEq(t, r["charged_microusd"], apiReservationMicroUSD)
	})
	t.Run("test_actual_tool_payload_is_low_effort_no_thinking_and_journaled_first", func(t *testing.T) {
		j, root := safetyJournal(t, 100)
		var sent obj
		apiPostHook = func(raw []byte, _ string, _ time.Duration) []byte {
			sent = parseJSON(raw).(obj)
			other, err := OpenLedgerJournal(ctx, root)
			if err != nil {
				t.Fatal(err)
			}
			defer other.Close()
			safetyEq(t, other.Status(safetyID(1))["status"], "pending")
			safetyEq(t, other.Status(nil)["charged_today_microusd"], apiReservationMicroUSD)
			return safetyResponse([]any{safetyCall("inspect_pane")})
		}
		r := j.Assess(ctx, safetyAssess(1))
		safetyEq(t, sent["thinking"], obj{"type": "disabled"})
		safetyEq(t, sent["output_config"].(obj)["effort"], "low")
		safetyEq(t, sent["tool_choice"], obj{"type": "any"})
		names := map[string]bool{}
		for _, raw := range sent["tools"].([]any) {
			names[raw.(obj)["name"].(string)] = true
		}
		if !names["repair_agent_link"] || names["shell"] {
			t.Fatal("health tool authority changed")
		}
		safetyEq(t, r["status"], "complete")
		safetyEq(t, r["result"].(obj)["tool_calls"].([]any)[0].(obj)["name"], "inspect_pane")
		if bigOf(r["charged_microusd"]).Int64() >= apiReservationMicroUSD {
			t.Fatal("valid usage not settled")
		}
	})
	t.Run("test_every_eligible_account_over_budget_reports_a_spending_hold_before_submission", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		marker := filepath.Join(t.TempDir(), "unexpected-preflight")
		helper := filepath.Join(t.TempDir(), "credentials")
		writeScript(t, helper, "#!/bin/sh\nprintf unexpected > '"+marker+"'\nexit 1\n")
		old := CredentialHelper
		CredentialHelper = helper
		t.Cleanup(func() { CredentialHelper = old })
		account := apiAccount(obj{"daily_limit_microusd": int64(6_000_000), "monthly_limit_microusd": int64(200_000_000), "billing_group": "anthropic"})
		u := j.usage()
		j.transaction(func() {
			must(j.store.InsertOperation(Operation{ID: safetyID(500), Fingerprint: "account-usage", SettingsDigest: "x", State: "complete", Day: u.day, Month: u.month, Charged: 5_014_081, AccountID: acctAPI, BillingGroup: "anthropic"}))
		})
		calls := safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		before := len(j.operations())
		safetyCode(t, "spending_limit", func() { j.selectAccount(ctx, enabledSettings(obj{"accounts": []any{account}}), true) })
		safetyEq(t, *calls, 0)
		safetyEq(t, len(j.operations()), before)
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("budget-held account ran preflight")
		}
	})
	t.Run("test_unavailable_account_and_a_budget_hold_remain_distinct", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		old := CredentialHelper
		CredentialHelper = filepath.Join(t.TempDir(), "absent-credential-helper")
		t.Cleanup(func() { CredentialHelper = old })
		held := apiAccount(obj{"daily_limit_microusd": int64(6_000_000), "billing_group": "held"})
		unavailable := apiAccount(obj{"id": safetyID(400), "daily_limit_microusd": int64(6_000_000), "billing_group": "unavailable"})
		u := j.usage()
		j.transaction(func() {
			must(j.store.InsertOperation(Operation{ID: safetyID(500), Fingerprint: "account-usage", SettingsDigest: "x", State: "complete", Day: u.day, Month: u.month, Charged: 5_014_081, AccountID: acctAPI, BillingGroup: "held"}))
		})
		safetyCode(t, "no_ready_account", func() { j.selectAccount(ctx, enabledSettings(obj{"accounts": []any{held, unavailable}}), true) })
	})
	t.Run("test_current_api_direct_caller_is_canonicalized_for_native_tools_and_history", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		chosen := safetyCall("inspect_pane")
		chosen["caller"] = obj{"type": "direct"}
		safetyPost(t, safetyResponse([]any{chosen}))
		r := j.Assess(ctx, safetyAssess(1))
		safetyEq(t, r["status"], "complete")
		safetyEq(t, r["result"].(obj)["tool_calls"], []any{safetyCall("inspect_pane")})
		safetyEq(t, r["result"].(obj)["assistant_content"], []any{safetyCall("inspect_pane")})
	})
	t.Run("test_server_tool_callers_and_unknown_tool_fields_are_not_native_authority", func(t *testing.T) {
		for _, extra := range []obj{{"caller": obj{"type": "code_execution_20260120", "tool_id": "server-tool"}}, {"caller": obj{"type": "direct", "extra": true}}, {"command": "no"}} {
			safetyRejected(t, func() {
				validateHealthCalls([]any{mergeSafety(safetyCall("inspect_pane"), extra)}, []any{safetyPane(nil)}, true)
			})
		}
	})
	t.Run("test_native_tool_results_are_sent_back_before_the_model_chooses_repair", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		row := safetyPane(nil)
		req := safetyAssess(1)
		req["messages"] = []any{obj{"role": "assistant", "content": []any{safetyCall("inspect_pane")}}, obj{"role": "user", "content": []any{toolResult("toolu_check_1", compact(obj{"state": "observed", "pane": row}))}}}
		var sent obj
		apiPostHook = func(raw []byte, _ string, _ time.Duration) []byte {
			sent = parseJSON(raw).(obj)
			return safetyResponse([]any{toolUse("toolu_repair", "repair_agent_link", obj{"pane_id": paneA, "evidence_id": row["evidence_id"]})})
		}
		r := j.Assess(ctx, req)
		safetyEq(t, r["status"], "complete")
		ms := sent["messages"].([]any)
		safetyEq(t, ms[len(ms)-1].(obj)["content"].([]any)[0].(obj)["type"], "tool_result")
		safetyEq(t, r["result"].(obj)["tool_calls"].([]any)[0].(obj)["name"], "repair_agent_link")
	})
	t.Run("test_a_replayed_completed_operation_never_makes_a_second_api_call", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		calls := safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		r := safetyAssess(1)
		first := j.Assess(ctx, r)
		safetyEq(t, j.Assess(ctx, r), first)
		safetyEq(t, *calls, 1)
	})
	t.Run("test_ambiguous_api_failure_is_durable_and_never_retried", func(t *testing.T) {
		j, root := safetyJournal(t, 100)
		calls := 0
		apiPostHook = func([]byte, string, time.Duration) []byte { calls++; fail("request_outcome_unknown"); return nil }
		r := safetyAssess(1)
		safetyEq(t, j.Assess(ctx, r)["status"], "uncertain")
		other, err := OpenLedgerJournal(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		defer other.Close()
		safetyEq(t, other.Assess(ctx, r)["status"], "uncertain")
		safetyRejected(t, func() { other.Assess(ctx, safetyAssess(2, safetyPane(obj{"installed_update": true}))) })
		safetyEq(t, calls, 1)
	})
	t.Run("test_health_and_handoff_share_the_host_request_limit", func(t *testing.T) {
		j, _ := safetyJournal(t, 1)
		calls := safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		j.Assess(ctx, safetyAssess(1))
		safetyCode(t, "spending_limit", func() { j.Submit(ctx, submitRequest(safetyID(2), "Known facts.")) })
		safetyEq(t, *calls, 1)
	})
	t.Run("test_missing_api_account_does_not_start_a_cli_fallback", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		j.Configure(safetyID(800), enabledSettings(obj{"providers": []any{"codex_account"}, "codex_path": "/not/a/fixture/provider"}), nil)
		calls := safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		backendCalls := 0
		j.backend = func(context.Context, obj) any {
			backendCalls++
			t.Fatal("health started a fallback backend")
			return nil
		}
		safetyCode(t, "health_api_account_required", func() { j.Assess(ctx, safetyAssess(1)) })
		safetyEq(t, *calls, 0)
		safetyEq(t, backendCalls, 0)
	})
	t.Run("test_snapshot_tampering_duplicate_panes_and_draft_overrides_are_rejected_before_api", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		changed := safetyAssess(1)
		changed["panes"].([]any)[0].(obj)["has_draft"] = true
		extra := safetyAssess(2)
		extra["panes"].([]any)[0].(obj)["command"] = "untrusted command"
		cases := []obj{changed, safetyAssess(3, safetyPane(nil), safetyPane(nil)), safetyAssess(4, safetyPane(obj{"has_draft": true})), safetyAssess(5, safetyPane(obj{"activity": "working"})), safetyAssess(6, safetyPane(obj{"identity_verified": false})), extra}
		calls := safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		for _, r := range cases {
			safetyRejected(t, func() { j.Assess(ctx, r) })
		}
		safetyEq(t, *calls, 0)
	})
	t.Run("test_unknown_tools_cross_pane_arguments_and_extra_commands_are_rejected", func(t *testing.T) {
		for _, call := range []obj{safetyCall("run_shell"), toolUse("toolu_check_1", "inspect_pane", obj{"pane_id": "other-pane"}), toolUse("toolu_check_1", "inspect_pane", obj{"pane_id": paneA, "command": "untrusted"}), toolUse("toolu_check_1", "repair_agent_link", obj{"pane_id": paneA, "evidence_id": "bad"})} {
			safetyRejected(t, func() { validateHealthCalls([]any{call}, []any{safetyPane(nil)}, true) })
		}
	})
	t.Run("test_forged_tool_result_identity_and_duplicate_result_ids_are_rejected", func(t *testing.T) {
		other := safetyPane(obj{"pane_id": paneB})
		user := toolResult("toolu_check_1", compact(obj{"pane": other}))
		safetyRejected(t, func() {
			validateHealthMessages([]any{obj{"role": "assistant", "content": []any{safetyCall("inspect_pane")}}, obj{"role": "user", "content": []any{user}}}, hostID, []any{safetyPane(nil)})
		})
		correct := toolResult("toolu_check_1", compact(obj{"pane": safetyPane(nil)}))
		safetyRejected(t, func() {
			validateHealthMessages([]any{obj{"role": "assistant", "content": []any{safetyCall("inspect_pane")}}, obj{"role": "user", "content": []any{correct, correct}}}, hostID, []any{safetyPane(nil)})
		})
	})
	t.Run("test_report_requires_every_pane_and_current_evidence", func(t *testing.T) {
		row := safetyPane(nil)
		valid := obj{"panes": []any{obj{"pane_id": paneA, "evidence_id": row["evidence_id"], "health": "held", "action": "observe", "reason": "Waiting for the exact safe repair."}}}
		safetyEq(t, validateHealthAssessment(valid, []any{row}), valid)
		bad := []obj{{"panes": []any{}}}
		for _, change := range []obj{{"evidence_id": strings.Repeat("0", 64)}, {"action": "kill"}, {"reason": ""}} {
			r := clone(valid).(obj)
			for k, v := range change {
				r["panes"].([]any)[0].(obj)[k] = v
			}
			bad = append(bad, r)
		}
		for _, r := range bad {
			safetyRejected(t, func() { validateHealthAssessment(r, []any{row}) })
		}
	})
	t.Run("test_success_reports_require_native_connection_identity_and_binding", func(t *testing.T) {
		report := func(row obj, health string) obj {
			return obj{"panes": []any{obj{"pane_id": paneA, "evidence_id": row["evidence_id"], "health": health, "action": "observe", "reason": "Native health evidence."}}}
		}
		good := safetyPane(obj{"binding": "bound", "allowed_actions": []any{"observe", "attention"}})
		validateHealthAssessment(report(good, "healthy"), []any{good})
		for _, change := range []obj{{"identity_verified": false}, {"binding": "unbound"}, {"connection": "disconnected"}} {
			row := safetyPane(mergeSafety(obj{"binding": "bound", "allowed_actions": []any{"observe", "attention"}}, change))
			safetyRejected(t, func() { validateHealthAssessment(report(row, "healthy"), []any{row}) })
		}
		shell := safetyPane(obj{"kind": "shell", "binding": "not_applicable", "allowed_actions": []any{"observe", "attention"}, "session_id": nil})
		validateHealthAssessment(report(shell, "healthy"), []any{shell})
		safetyRejected(t, func() { validateHealthAssessment(report(shell, "working"), []any{shell}) })
		safetyRejected(t, func() { validateHealthAssessment(report(good, "working"), []any{good}) })
		working := safetyPane(obj{"binding": "bound", "activity": "working", "allowed_actions": []any{"observe", "attention"}})
		validateHealthAssessment(report(working, "working"), []any{working})
	})
	t.Run("test_serial_inspections_fit_the_twelve_step_native_pass", func(t *testing.T) {
		row := safetyPane(nil)
		messages := []any{}
		for n := 0; n < 12; n++ {
			id := safetyID(n)
			messages = append(messages, obj{"role": "assistant", "content": []any{toolUse(id, "inspect_pane", obj{"pane_id": paneA})}}, obj{"role": "user", "content": []any{toolResult(id, compact(obj{"state": "observed", "pane": row}))}})
		}
		safetyEq(t, validateHealthMessages(messages, hostID, []any{row}), []any{row})
		safetyRejected(t, func() { validateHealthMessages(append(messages, messages[:2]...), hostID, []any{row}) })
	})
	t.Run("test_handoff_submission_still_uses_the_original_contract", func(t *testing.T) {
		j, _ := safetyJournal(t, 100)
		value := obj{"summary": "Known progress.", "decisions": []any{}, "constraints": []any{}, "pending_work": []any{}, "next_action": "Read the original result.", "uncertainties": []any{}}
		safetyPost(t, []byte(compact(obj{"model": apiModel, "stop_reason": "end_turn", "content": []any{obj{"type": "text", "text": compact(value)}}, "usage": obj{"input_tokens": int64(10), "output_tokens": int64(10)}})))
		r := j.Submit(ctx, submitRequest(safetyID(2), "Known evidence."))
		safetyEq(t, r["status"], "complete")
		safetyEq(t, r["result"].(obj)["draft"], value)
	})
}
