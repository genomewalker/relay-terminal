package rotationtext

import (
	"fmt"
	"math/big"
	"math/rand"
	"sort"
	"testing"
)

func mutated(random *rand.Rand, base any, times int) any {
	value := clone(base)
	for n := 1 + random.Intn(times); n > 0; n-- {
		value = mutate(random, value)
	}
	return value
}

func TestDifferentialHealthValidators(t *testing.T) {
	random := rand.New(rand.NewSource(21))
	panes := defaultPanes()
	snapshot := snapshotOf(hostID, panes)
	cases := []oracleCase{fnCase("panes-valid", "valid_health_panes", hostID, snapshot, panes)}
	for _, host := range []any{"", "bad host", "a:b.c-d_e", nil, int64(1), string(make([]byte, 129))} {
		cases = append(cases, fnCase("panes-host", "valid_health_panes", host, snapshotOf(fmt.Sprint(host), panes), panes))
	}
	for i := 0; i < 1500; i++ {
		value := mutated(random, panes, 3)
		if random.Intn(2) == 0 {
			rehash(value)
		}
		snap := safeSnapshot(hostID, value)
		if random.Intn(10) == 0 {
			snap = mutate(random, snap)
		}
		cases = append(cases, fnCase(fmt.Sprint("panes-random-", i), "valid_health_panes", hostID, snap, value))
	}
	// Single-pane variants exercise the admissibility matrix directly.
	for i := 0; i < 600; i++ {
		pane := makePane(paneA, obj{})
		for n := 1 + random.Intn(4); n > 0; n-- {
			key := []string{"kind", "connection", "binding", "activity", "identity_verified", "prompt_empty", "has_draft",
				"pending_approvals", "input_idle", "installed_update", "allowed_actions", "session_id", "process_id"}[random.Intn(13)]
			pane[key] = []any{"claude", "codex", "shell", "other", "connected", "disconnected", "bound", "unbound", "not_applicable",
				"quiet", "working", true, false, nil, int64(0), int64(1), int64(3),
				[]any{"observe", "repair_link"}, []any{"observe", "apply_update"}, []any{"observe", "reconnect"}, []any{"attention"},
				[]any{"observe", "observe"}}[random.Intn(22)]
		}
		withEvidence(pane)
		list := []any{pane}
		cases = append(cases, fnCase(fmt.Sprint("pane-matrix-", i), "valid_health_panes", hostID, snapshotOf(hostID, list), list))
	}

	blocks := []any{obj{"type": "text", "text": "Checking."}, toolUse("toolu_1", "inspect_pane", obj{"pane_id": paneA}),
		toolUse("toolu_2", "repair_agent_link", obj{"pane_id": paneA, "evidence_id": panes[0].(obj)["evidence_id"]})}
	report := []any{toolUse("toolu_9", "report_health", reportFor(panes, "healthy"))}
	report[0].(obj)["caller"] = obj{"type": "direct"}
	for _, flag := range []bool{true, false} {
		cases = append(cases, fnCase("calls-valid", "validate_health_calls", blocks, panes, flag),
			fnCase("calls-report", "validate_health_calls", report, panes, flag))
	}
	for i := 0; i < 900; i++ {
		base := any(blocks)
		if i%3 == 0 {
			base = report
		}
		cases = append(cases, fnCase(fmt.Sprint("calls-random-", i), "validate_health_calls", mutated(random, base, 3), panes, i%2 == 0))
	}

	updated := makePane(paneA, obj{"binding": "bound", "observed_at": int64(1700000100)})
	messages := []any{obj{"role": "assistant", "content": []any{toolUse("toolu_1", "inspect_pane", obj{"pane_id": paneA}),
		toolUse("toolu_2", "verify_pane", obj{"pane_id": paneC})}},
		obj{"role": "user", "content": []any{toolResult("toolu_1", compact(obj{"pane": updated})),
			obj{"type": "tool_result", "tool_use_id": "toolu_2", "content": `{"ok":true}`, "is_error": false}}}}
	cases = append(cases, fnCase("messages-valid", "validate_health_messages", messages, hostID, panes))
	for i := 0; i < 900; i++ {
		value := mutated(random, messages, 3)
		if i%4 == 0 {
			// Mutate the reported pane inside the tool result text.
			pane := mutated(random, updated, 2)
			if pane, ok := pane.(obj); ok && random.Intn(2) == 0 {
				func() { defer func() { recover() }(); withEvidence(pane) }()
			}
			value = clone(messages)
			func() {
				defer func() { recover() }()
				value.([]any)[1].(obj)["content"].([]any)[0].(obj)["content"] = compact(obj{"pane": pane})
			}()
		}
		cases = append(cases, fnCase(fmt.Sprint("messages-random-", i), "validate_health_messages", value, hostID, panes))
	}

	working := reportFor(panes, "working")
	cases = append(cases, fnCase("assessment-working-shell", "validate_health_assessment", func() obj {
		items := working["panes"].([]any)
		items[2].(obj)["health"] = "working"
		return working
	}(), panes), fnCase("assessment-healthy-unbound", "validate_health_assessment", func() obj {
		value := reportFor(panes, "healthy")
		value["panes"].([]any)[0].(obj)["health"] = "healthy"
		return value
	}(), panes), fnCase("assessment-reason-control", "validate_health_assessment", func() obj {
		value := reportFor(panes, "healthy")
		value["panes"].([]any)[0].(obj)["reason"] = "line\nbreak"
		return value
	}(), panes))
	assessment := reportFor(panes, "healthy")
	cases = append(cases, fnCase("assessment-valid", "validate_health_assessment", assessment, panes))
	for i := 0; i < 900; i++ {
		cases = append(cases, fnCase(fmt.Sprint("assessment-random-", i), "validate_health_assessment", mutated(random, assessment, 3), panes))
	}
	compareOracle(t, cases)
}

// sampleArgs builds schema-valid arguments for an assistant tool.
func sampleArgs(random *rand.Rand, schema obj, all bool) obj {
	properties := schema["properties"].(obj)
	required := map[string]bool{}
	for _, name := range stringsOf(schema["required"]) {
		required[name] = true
	}
	args := obj{}
	names := keysOf(properties)
	sort.Strings(names)
	for _, name := range names {
		if !required[name] && !all && random.Intn(2) == 0 {
			continue
		}
		rule := properties[name].(obj)
		switch rule["type"] {
		case "string":
			if enum, ok := rule["enum"].([]any); ok {
				args[name] = enum[random.Intn(len(enum))]
			} else {
				args[name] = []string{"x", paneA, "/home/example", "ls -la", "", "İstanbul"}[random.Intn(6)]
			}
		case "integer":
			args[name] = getDefault(rule, "minimum", int64(1))
		case "boolean":
			args[name] = random.Intn(2) == 0
		case "array":
			args[name] = []any{sampleArgs(random, rule["items"].(obj), false)}
		}
	}
	return args
}

func TestDifferentialAssistantValidators(t *testing.T) {
	useLegacyAssistant(t)
	random := rand.New(rand.NewSource(33))
	cases := []oracleCase{}
	for _, name := range append(append([]string{}, assistantNames...), "unknown_tool", "") {
		schema := assistantSchemas[name]
		if schema == nil {
			cases = append(cases, fnCase("input-unknown", "validate_assistant_input", name, obj{}))
			continue
		}
		cases = append(cases, fnCase("input-all-"+name, "validate_assistant_input", name, sampleArgs(random, schema, true)))
		for i := 0; i < 25; i++ {
			cases = append(cases, fnCase(fmt.Sprintf("input-%s-%d", name, i), "validate_assistant_input", name,
				mutated(random, sampleArgs(random, schema, false), 2)))
		}
	}
	long := make([]byte, 8193)
	for i := range long {
		long[i] = 'a'
	}
	cases = append(cases,
		fnCase("input-maxlength", "validate_assistant_input", "send_command", obj{"pane_id": paneA, "text": string(long)}),
		fnCase("input-maxlength-unicode", "validate_assistant_input", "list_panes", obj{"query": string([]rune("ééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé"))}),
		fnCase("input-int-bounds", "validate_assistant_input", "exec_command", obj{"host": "h", "command": "c", "timeout_seconds": int64(3601)}),
		fnCase("input-int-bool", "validate_assistant_input", "exec_command", obj{"host": "h", "command": "c", "timeout_seconds": true}),
		fnCase("input-int-float", "validate_assistant_input", "exec_command", obj{"host": "h", "command": "c", "timeout_seconds": 5.0}),
		fnCase("input-steps-9", "validate_assistant_input", "propose_plan", obj{"steps": []any{obj{"op": "select"}, obj{"op": "select"},
			obj{"op": "select"}, obj{"op": "select"}, obj{"op": "select"}, obj{"op": "select"}, obj{"op": "select"}, obj{"op": "select"}, obj{"op": "select"}}}),
		fnCase("input-steps-empty", "validate_assistant_input", "propose_plan", obj{"steps": []any{}}),
		fnCase("input-inf", "validate_assistant_input", "list_panes", rawJSON(`{"query":1e999}`)),
	)

	blocks := []any{obj{"type": "text", "text": "Looking.", "citations": []any{obj{"a": "b"}}},
		toolUse("toolu_a", "get_pane_health", obj{"pane_id": paneA}), toolUse("toolu_b", "select_pane", obj{"pane_id": paneB})}
	blocks[1].(obj)["caller"] = obj{"type": "direct"}
	cases = append(cases, fnCase("blocks-valid", "validate_assistant_blocks", blocks))
	for i := 0; i < 700; i++ {
		cases = append(cases, fnCase(fmt.Sprint("blocks-random-", i), "validate_assistant_blocks", mutated(random, blocks, 3)))
	}
	messages := []any{obj{"role": "user", "content": "Why is pane A held?"},
		obj{"role": "assistant", "content": blocks},
		obj{"role": "user", "content": []any{toolResult("toolu_a", `{"health":"held"}`),
			obj{"type": "tool_result", "tool_use_id": "toolu_b", "content": "selected", "is_error": false}}},
		obj{"role": "assistant", "content": "It is held."},
		obj{"role": "user", "content": "Thanks."}}
	cases = append(cases, fnCase("messages-valid", "validate_assistant_messages", messages))
	for i := 0; i < 900; i++ {
		cases = append(cases, fnCase(fmt.Sprint("messages-random-", i), "validate_assistant_messages", mutated(random, messages, 3)))
	}
	many := []any{obj{"role": "user", "content": "go"}}
	for i := 0; i < 5; i++ {
		id1, id2 := fmt.Sprintf("t%da", i), fmt.Sprintf("t%db", i)
		many = append(many, obj{"role": "assistant", "content": []any{toolUse(id1, "list_panes", obj{}), toolUse(id2, "list_panes", obj{})}},
			obj{"role": "user", "content": []any{toolResult(id1, "r"), toolResult(id2, "r")}})
	}
	cases = append(cases, fnCase("messages-tool-limit", "validate_assistant_messages", many))

	binding := obj{"host_id": hostID, "operation_id": opID, "request_id": reqID}
	cases = append(cases, fnCase("binding-valid", "valid_assistant_binding", binding))
	for i := 0; i < 200; i++ {
		cases = append(cases, fnCase(fmt.Sprint("binding-random-", i), "valid_assistant_binding", mutated(random, binding, 2)))
	}
	evidence := obj{"context": "Here: pane A on dandy-07.", "messages": messages}
	cases = append(cases, fnCase("evidence-valid", "valid_assistant_evidence", compact(evidence)),
		fnCase("evidence-nonstring", "valid_assistant_evidence", evidence),
		fnCase("evidence-dup", "valid_assistant_evidence", `{"context":"a","context":"b","messages":[]}`))
	for i := 0; i < 400; i++ {
		value := mutated(random, evidence, 2)
		text := func() (text any) {
			defer func() {
				if recover() != nil {
					text = "{}"
				}
			}()
			return compact(value)
		}()
		cases = append(cases, fnCase(fmt.Sprint("evidence-random-", i), "valid_assistant_evidence", text))
	}
	compareOracle(t, cases)
}

func TestDifferentialSettingsAndDrafts(t *testing.T) {
	useLegacyAssistant(t)
	random := rand.New(rand.NewSource(45))
	cases := []oracleCase{}
	settings := enabledSettings(obj{"providers": []any{"anthropic_api", "claude_account"},
		"accounts": []any{apiAccount(nil), cliAccount(nil)}, "codex_model": "gpt-5.5", "claude_path": "/usr/local/bin/claude"})
	cases = append(cases, fnCase("settings-valid", "validated_settings", settings),
		fnCase("settings-default", "validated_settings", defaultSettings),
		fnCase("settings-secret", "validated_settings", enabledSettings(obj{"api_key": "secret-must-never-persist"})),
		fnCase("settings-duplicate-ref", "validated_settings", enabledSettings(obj{"accounts": []any{apiAccount(nil), apiAccount(obj{"id": acctCLI})}})),
		fnCase("settings-duplicate-login", "validated_settings", enabledSettings(obj{"providers": []any{"claude_account"},
			"accounts": []any{cliAccount(nil), cliAccount(obj{"id": acctAPI})}})),
		fnCase("settings-account-required", "validated_settings", enabledSettings(obj{"accounts": []any{apiAccount(obj{"enabled": false})}})),
		fnCase("settings-account-other-provider", "validated_settings", enabledSettings(obj{"accounts": []any{cliAccount(nil)}})))
	for i := 0; i < 1200; i++ {
		cases = append(cases, fnCase(fmt.Sprint("settings-random-", i), "validated_settings", mutated(random, settings, 3)))
	}
	for i, account := range []any{apiAccount(nil), cliAccount(nil), apiAccount(obj{"enabled": false, "billing_group": nil, "credential_ref": nil}),
		apiAccount(obj{"billing_group": int64(0), "enabled": false}), apiAccount(obj{"billing_group": []any{}}), apiAccount(obj{"billing_group": ""}),
		cliAccount(obj{"provider": "codex_account", "model": "gpt-5.5"}), cliAccount(obj{"name": " padded"}), cliAccount(obj{"name": "tab\tname"}),
		cliAccount(obj{"name": "key sk-ant-abcdefghijklmnopqrstuv"}), cliAccount(obj{"name": "ésk-ant-abcdefghijklmnopqrstuv"}),
		cliAccount(obj{"auth_directory": "/a\x00b"}), cliAccount(obj{"name": " nb"}), cliAccount(obj{"name": string(make([]rune, 65))})} {
		cases = append(cases, fnCase(fmt.Sprint("account-", i), "validated_account", account))
	}
	for i := 0; i < 900; i++ {
		base := apiAccount(nil)
		if i%2 == 0 {
			base = cliAccount(nil)
		}
		cases = append(cases, fnCase(fmt.Sprint("account-random-", i), "validated_account", mutated(random, base, 3)))
	}
	cases = append(cases, fnCase("draft-valid", "validate_draft", validDraft()))
	big6400 := make([]byte, 6401)
	for i := range big6400 {
		big6400[i] = 'z'
	}
	cases = append(cases, fnCase("draft-long", "validate_draft", func() obj { d := validDraft(); d["summary"] = string(big6400); return d }()),
		fnCase("draft-large", "validate_draft", func() obj {
			d := validDraft()
			items := []any{}
			for i := 0; i < 4; i++ {
				items = append(items, string(big6400[:5000]))
			}
			d["decisions"] = items
			return d
		}()))
	for i := 0; i < 900; i++ {
		cases = append(cases, fnCase(fmt.Sprint("draft-random-", i), "validate_draft", mutated(random, validDraft(), 3)))
	}
	usage := obj{"input_tokens": int64(10), "output_tokens": int64(5), "cache_read_input_tokens": int64(0),
		"cache_creation_input_tokens": int64(2), "cached_input_tokens": int64(1), "other": int64(9)}
	cases = append(cases, fnCase("usage-valid", "usage_fields", usage), fnCase("usage-list", "usage_fields", []any{}))
	for i := 0; i < 300; i++ {
		cases = append(cases, fnCase(fmt.Sprint("usage-random-", i), "usage_fields", mutated(random, usage, 2)))
	}
	for _, limit := range []any{int64(0), int64(1), int64(49), int64(50), int64(51), int64(99), int64(100), int64(101), int64(10000),
		new(big.Int).Lsh(big.NewInt(1), 80)} {
		cases = append(cases, fnCase("reserve", "assistant_health_reserve", limit))
	}
	for _, value := range weirdValues {
		cases = append(cases, fnCase("operation-id", "valid_operation_id", value))
	}
	cases = append(cases, fnCase("operation-id-ok", "valid_operation_id", opID), fnCase("operation-id-upper", "valid_operation_id", "0123456789ABCDEF0123456789abcdef"),
		fnCase("operation-id-newline", "valid_operation_id", opID+"\n"))
	compareOracle(t, cases)
}
