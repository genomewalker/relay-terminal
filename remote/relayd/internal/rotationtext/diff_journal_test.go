package rotationtext

import (
	"fmt"
	"math/rand"
	"testing"
)

const journalNow = "2026-10-21T12:00:00"

func jstep(op string, request any) oracleStep { return oracleStep{Op: op, Request: asciiJSON(request)} }

func configureStep(id string, settings obj) oracleStep {
	return jstep("configure", obj{"operation_id": id, "settings": settings})
}

func submitRequest(id, evidence string) obj {
	return obj{"v": int64(1), "operation_id": id, "binding": obj{"session_id": "sess_1", "client": "codex", "turn_seq": int64(9)}, "evidence": evidence}
}

func assessRequest(id string) obj {
	panes := defaultPanes()
	return obj{"v": int64(1), "operation_id": id, "host_id": hostID, "snapshot_id": snapshotOf(hostID, panes), "panes": panes, "messages": []any{}}
}

func assistRequest(id, request string, messages []any) obj {
	return obj{"v": int64(1), "operation_id": id, "request_id": request, "host_id": hostID,
		"context": "Here: pane " + paneA + ".", "messages": messages}
}

// cannedDraft is a backend result echoing a submit request's binding.
func cannedDraft(id, evidence string, mods obj) string {
	result := obj{"v": int64(1), "operation_id": id, "status": "draft", "provider": "anthropic_api", "model": apiModel,
		"binding": submitRequest(id, evidence)["binding"], "source_sha256": sha256Hex(evidence), "submitted_sha256": sha256Hex(evidence),
		"credential_redactions": int64(0), "account_id": "", "billing_group": "", "draft": validDraft(),
		"usage": obj{"input_tokens": int64(2000), "output_tokens": int64(400)}, "attempts": []any{}}
	for key, value := range mods {
		if value == nil {
			delete(result, key)
		} else {
			result[key] = value
		}
	}
	return asciiJSON(result)
}

func journalCase(name string, f cliFixture, execute string, steps []oracleStep, canned []string, api ...oracleAPI) oracleCase {
	return oracleCase{name: name, Fn: "journal", Now: journalNow, Execute: execute, Steps: steps, Canned: canned,
		Env: f.env(), Unset: credentialUnset, ExpectKey: fakeKey, API: api}
}

func TestDifferentialJournal(t *testing.T) {
	useLegacyAssistant(t)
	f := newCLIFixture(t)
	evidenceA, evidenceC, evidenceD := "Evidence A.", "Evidence C.", "Evidence D."
	opA, opB, opC, opD := "a0000000000000000000000000000000", "b0000000000000000000000000000000", "c0000000000000000000000000000000", "d0000000000000000000000000000000"
	settings := enabledSettings(nil)
	cases := []oracleCase{
		journalCase("canned-lifecycle", f, "canned", []oracleStep{
			jstep("status", obj{}),
			jstep("status", obj{"operation_id": opA}),
			jstep("status", obj{"operation_id": ""}),
			jstep("status", obj{"operation_id": int64(0)}),
			jstep("submit", submitRequest(opA, evidenceA)),
			configureStep(opID, settings),
			configureStep(opID, settings),
			configureStep(opID, enabledSettings(obj{"max_requests_per_day": int64(51)})),
			jstep("configure", obj{"operation_id": opID2, "settings": settings, "expected_configuration_id": opID3}),
			jstep("configure", obj{"operation_id": opID2, "settings": settings, "expected_configuration_id": opID}),
			jstep("configure", obj{"operation_id": opID3, "settings": settings, "expected_configuration_id": int64(5)}),
			jstep("submit", submitRequest(opA, evidenceA)),
			jstep("status", obj{"operation_id": opA}),
			jstep("submit", submitRequest(opA, evidenceA)),
			jstep("submit", submitRequest(opB, evidenceA)),
			jstep("submit", submitRequest(opA, evidenceC)),
			jstep("submit", submitRequest(opC, evidenceC)),
			jstep("submit", submitRequest(opD, evidenceD)),
			jstep("status", obj{}),
			jstep("abandon", obj{"operation_id": opC}),
			jstep("abandon", obj{"operation_id": opC}),
			jstep("abandon", obj{"operation_id": "zz"}),
			jstep("submit", submitRequest(opD, evidenceD)),
			jstep("status", obj{}),
		}, []string{
			cannedDraft(opA, evidenceA, nil),
			cannedDraft(opC, evidenceC, obj{"status": "failed", "code": "request_outcome_unknown", "draft": nil}),
			cannedDraft(opD, evidenceD, obj{"status": "unavailable", "draft": nil, "usage": nil}),
		}),
		journalCase("canned-result-checks", f, "canned", []oracleStep{
			configureStep(opID, enabledSettings(nil)),
			jstep("submit", submitRequest(opA, "e1")), jstep("abandon", obj{"operation_id": opA}),
			jstep("submit", submitRequest(opB, "e2")), jstep("abandon", obj{"operation_id": opB}),
			jstep("submit", submitRequest(opC, "e3")), jstep("abandon", obj{"operation_id": opC}),
			jstep("submit", submitRequest(opD, "e4")), jstep("abandon", obj{"operation_id": opD}),
			jstep("submit", submitRequest(opID2, "e5")), jstep("abandon", obj{"operation_id": opID2}),
			jstep("submit", submitRequest(opID3, "e6")), jstep("status", obj{}),
		}, []string{
			cannedDraft(opA, "e1", obj{"binding": obj{"session_id": "other", "client": "codex", "turn_seq": int64(9)}}),
			cannedDraft(opB, "e2", obj{"model": "claude-opus-5-5"}),
			cannedDraft(opC, "e3", obj{"draft": obj{"summary": "x"}}),
			cannedDraft(opD, "e4", obj{"usage": obj{"input_tokens": int64(150000), "output_tokens": int64(900000)}}),
			cannedDraft(opID2, "e5", obj{"provider": "claude_account", "usage": obj{}}),
			cannedDraft(opID3, "e6", obj{"status": "failed", "code": "api_http_400", "usage": obj{"input_tokens": int64(10), "output_tokens": int64(1), "cache_read_input_tokens": true}}),
		}),
	}

	cases = append(cases, journalCase("canned-overflow", f, "canned", []oracleStep{
		configureStep(opID, enabledSettings(nil)),
		jstep("submit", submitRequest(opA, "e1")),
		jstep("status", obj{}),
		jstep("status", obj{"operation_id": opA}),
	}, []string{cannedDraft(opA, "e1", obj{"usage": obj{"input_tokens": parseJSON("1180591620717411303424"), "output_tokens": int64(1)}})}))

	// Charge boundaries: ceil(n/10) at exactly 100000 inputs, n%10 == 1, and a
	// charge equal to the reservation (complete, not uncertain).
	cases = append(cases, journalCase("canned-charge-boundaries", f, "canned", []oracleStep{
		configureStep(opID, enabledSettings(nil)),
		jstep("submit", submitRequest(opA, "e1")),
		jstep("submit", submitRequest(opB, "e2")),
		jstep("submit", submitRequest(opC, "e3")),
		jstep("submit", submitRequest(opD, "e4")),
		jstep("status", obj{}),
	}, []string{
		cannedDraft(opA, "e1", obj{"usage": obj{"input_tokens": int64(100000), "output_tokens": int64(0)}}),
		cannedDraft(opB, "e2", obj{"usage": obj{"input_tokens": int64(1), "output_tokens": int64(0)}}),
		cannedDraft(opC, "e3", obj{"usage": obj{"input_tokens": int64(0), "output_tokens": int64(2_000_000)}}),
		cannedDraft(opD, "e4", obj{"usage": obj{"input_tokens": int64(100001), "output_tokens": int64(0)}}),
	}))

	// Assistant step limit: nine steps of one request are allowed, the tenth is not.
	stepLimit := []oracleStep{configureStep(opID, enabledSettings(obj{"max_requests_per_day": int64(100)}))}
	stepCanned := []string{}
	for n := 1; n <= 10; n++ {
		id := fmt.Sprintf("%032x", 0xe0+n)
		stepLimit = append(stepLimit, jstep("assist", assistRequest(id, reqID, []any{obj{"role": "user", "content": "Why is pane A held?"}})))
		stepCanned = append(stepCanned, asciiJSON(obj{"v": int64(1), "operation_id": id, "status": "unavailable"}))
	}
	cases = append(cases, journalCase("canned-assistant-step-limit", f, "canned", append(stepLimit, jstep("status", obj{})), stepCanned))

	// Real backends through the API hook: draft, health assessment and assistant.
	health, panes := healthRequest()
	_ = health
	healthBlocks := []any{toolUse("toolu_1", "inspect_pane", obj{"pane_id": paneA})}
	assistantBlocks := []any{obj{"type": "text", "text": "Checking."}, toolUse("toolu_a", "get_pane_health", obj{"pane_id": paneA})}
	question := []any{obj{"role": "user", "content": "Why is pane A held?"}}
	followUp := append(append([]any{}, question...), obj{"role": "assistant", "content": assistantBlocks},
		obj{"role": "user", "content": []any{toolResult("toolu_a", `{"hold":"update"}`)}})
	cases = append(cases, journalCase("backend-flow", f, "draft", []oracleStep{
		configureStep(opID, enabledSettings(obj{"max_requests_per_day": int64(100)})),
		jstep("submit", submitRequest(opA, evidenceA)),
		jstep("assess", assessRequest(opB)),
		jstep("assist", assistRequest(opC, reqID, question)),
		jstep("assist", assistRequest(opD, reqID, followUp)),
		jstep("assess", assessRequest(opB)),
		jstep("status", obj{}),
		jstep("status", obj{"operation_id": opD}),
	}, nil,
		apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", nil)),
		apiBody(apiResponse(healthBlocks, "tool_use", nil)),
		apiBody(apiResponse(assistantBlocks, "tool_use", nil)),
		apiBody(apiResponse([]any{obj{"type": "text", "text": "Held for an update."}}, "end_turn", nil)),
	))
	cases = append(cases, journalCase("backend-limits", f, "draft", []oracleStep{
		configureStep(opID, enabledSettings(obj{"max_requests_per_day": int64(12), "daily_limit_microusd": int64(2_500_000)})),
		jstep("assist", assistRequest(opC, reqID, question)),
		jstep("submit", submitRequest(opA, evidenceA)),
		jstep("submit", submitRequest(opB, evidenceC)),
		jstep("submit", submitRequest(opD, evidenceD)),
		jstep("assess", assessRequest(opID2)),
		jstep("status", obj{}),
	}, nil,
		apiBody(apiResponse([]any{obj{"type": "text", "text": "ok"}}, "end_turn", nil)),
		apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", nil)),
		oracleAPI{Error: "request_outcome_unknown"},
	))
	cases = append(cases, journalCase("backend-health-report", f, "draft", []oracleStep{
		configureStep(opID, enabledSettings(nil)),
		jstep("assess", assessRequest(opB)),
	}, nil, apiBody(apiResponse([]any{toolUse("toolu_9", "report_health", reportFor(panes, "healthy"))}, "tool_use", nil))))

	// Accounts: provider order, preflight, per-account and group budgets.
	accounts := enabledSettings(obj{"providers": []any{"anthropic_api", "claude_account"}, "daily_limit_microusd": int64(200_000_000),
		"monthly_limit_microusd": int64(200_000_000), "max_requests_per_day": int64(100),
		"accounts": []any{
			apiAccount(obj{"daily_limit_microusd": int64(1_500_000), "max_requests_per_day": int64(3)}),
			apiAccount(obj{"id": "a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2", "name": "Locked", "credential_ref": "e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3"}),
			cliAccount(obj{"auth_directory": f.auth, "cli_path": f.cli("claude-ok")}),
		}})
	cases = append(cases, journalCase("accounts-flow", f, "draft", []oracleStep{
		configureStep(opID, accounts),
		jstep("submit", submitRequest(opA, evidenceA)),
		jstep("submit", submitRequest(opB, evidenceC)),
		jstep("assess", assessRequest(opC)),
		jstep("status", obj{}),
	}, nil,
		apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", obj{"usage": obj{"input_tokens": int64(5000), "output_tokens": int64(1000)}})),
	))
	fallthroughSettings := clone(accounts).(obj)
	fallthroughSettings["accounts"].([]any)[0].(obj)["max_requests_per_day"] = int64(1)
	cases = append(cases, journalCase("accounts-fallthrough", f, "draft", []oracleStep{
		configureStep(opID, fallthroughSettings),
		jstep("submit", submitRequest(opA, evidenceA)),
		jstep("submit", submitRequest(opB, evidenceC)),
		jstep("assess", assessRequest(opC)),
		jstep("status", obj{}),
	}, nil,
		apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", nil)),
	))
	// Account reservation: 1000 already charged plus the 1000000 reservation
	// exceeds a 1000000 daily limit, so the second draft falls to the CLI account.
	reserveSettings := clone(accounts).(obj)
	reserveSettings["accounts"].([]any)[0].(obj)["daily_limit_microusd"] = int64(1_000_000)
	cases = append(cases, journalCase("accounts-reservation", f, "draft", []oracleStep{
		configureStep(opID, reserveSettings),
		jstep("submit", submitRequest(opA, evidenceA)),
		jstep("submit", submitRequest(opB, evidenceC)),
		jstep("status", obj{}),
	}, nil,
		apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", obj{"usage": obj{"input_tokens": int64(5000), "output_tokens": int64(1000)}})),
	))
	cases = append(cases, journalCase("accounts-health", f, "draft", []oracleStep{
		configureStep(opID, accounts),
		jstep("assess", assessRequest(opC)),
		jstep("status", obj{}),
	}, nil, apiBody(apiResponse(healthBlocks, "tool_use", nil))))
	cases = append(cases, journalCase("accounts-none-ready", f, "draft", []oracleStep{
		configureStep(opID, enabledSettings(obj{"accounts": []any{apiAccount(obj{"credential_ref": "e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3"})}})),
		jstep("submit", submitRequest(opA, evidenceA)),
		configureStep(opID2, enabledSettings(obj{"accounts": []any{apiAccount(obj{"max_requests_per_day": int64(1), "daily_limit_microusd": int64(1_000_000)})}})),
		jstep("assist", assistRequest(opB, reqID, question)),
		jstep("submit", submitRequest(opC, evidenceC)),
		jstep("submit", submitRequest(opD, evidenceD)),
	}, nil, apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn", nil))))
	cases = append(cases, journalCase("settings-errors", f, "draft", []oracleStep{
		configureStep(opID, enabledSettings(obj{"accounts": []any{apiAccount(nil), apiAccount(obj{"id": acctCLI})}})),
		configureStep(opID, enabledSettings(obj{"accounts": []any{apiAccount(obj{"enabled": false})}})),
		configureStep(opID, enabledSettings(obj{"accounts": []any{apiAccount(nil), apiAccount(nil)}})),
		configureStep(opID, enabledSettings(obj{"daily_limit_microusd": int64(10)})),
		configureStep(opID, obj{"enabled": true}),
		configureStep("bad", enabledSettings(nil)),
		jstep("submit", obj{"v": int64(1)}),
		jstep("submit", submitRequest("bad", "e")),
		jstep("submit", func() obj { r := submitRequest(opA, "e"); r["v"] = int64(2); return r }()),
		jstep("submit", submitRequest(opA, " 　 ")),
		jstep("assess", obj{"v": true}),
		jstep("assist", obj{"v": int64(1)}),
		jstep("submit", submitRequest(opA, "e")),
	}, nil))

	// Random journeys: random requests and canned results, mutated.
	random := rand.New(rand.NewSource(77))
	ids := []string{opA, opB, opC, opD, opID2}
	for i := 0; i < 160; i++ {
		steps := []oracleStep{configureStep(opID, enabledSettings(obj{"max_requests_per_day": int64(1 + random.Intn(30)),
			"daily_limit_microusd": int64(1_000_000 + random.Intn(4)*1_000_000)}))}
		canned := []string{}
		for n := 3 + random.Intn(6); n > 0; n-- {
			id := ids[random.Intn(len(ids))]
			evidence := []string{evidenceA, evidenceC, evidenceD}[random.Intn(3)]
			var request any
			op := []string{"submit", "submit", "assess", "assist", "status", "abandon"}[random.Intn(6)]
			switch op {
			case "submit":
				request = submitRequest(id, evidence)
				result := parseJSON(cannedDraft(id, evidence, nil))
				if random.Intn(2) == 0 {
					result = mutated(random, result, 2)
				}
				canned = append(canned, asciiJSON(result))
			case "assess":
				request = assessRequest(id)
				canned = append(canned, asciiJSON(obj{"v": int64(1), "operation_id": id, "status": "failed", "code": "api_http_500"}))
			case "assist":
				request = assistRequest(id, []string{reqID, reqID2}[random.Intn(2)], question)
				canned = append(canned, asciiJSON(obj{"v": int64(1), "operation_id": id, "status": "unavailable"}))
			default:
				request = obj{"operation_id": id}
			}
			if random.Intn(6) == 0 {
				request = mutated(random, request, 2)
			}
			steps = append(steps, jstep(op, request))
		}
		cases = append(cases, journalCase(fmt.Sprint("random-journey-", i), f, "canned", steps, canned))
	}
	// The same journeys over the Go ledger store.
	for _, c := range append([]oracleCase(nil), cases...) {
		c.name, c.ledger = "ledger-"+c.name, true
		cases = append(cases, c)
	}
	compareOracle(t, cases)
}
