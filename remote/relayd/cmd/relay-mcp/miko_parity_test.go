package main

import (
	"bytes"
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestMikoCatalogComplete(t *testing.T) {
	raw, _, _ := (&server{}).handle(request{Method: "tools/list"})
	expected := map[string]bool{}
	for _, x := range raw.(map[string]any)["tools"].([]any) {
		name := x.(map[string]any)["name"].(string)
		// Independent exclusion oracle, deliberately not mikoExcluded.
		if strings.HasPrefix(name, "relay_miko_") {
			continue
		}
		switch name {
		case "relay_ask_miko", "relay_register_caller", "relay_control_caller", "relay_begin_terminal_control", "relay_authorize_r_session", "relay_call_tool", "relay_available_tools", "relay_research_capability", "relay_prompt_provenance",
			"relay_broadcast_message": // not offered to Miko yet
			continue
		}
		expected[name] = true
	}
	actual := map[string]bool{}
	for _, entry := range mikoCatalog() {
		name := entry["name"].(string)
		actual[name] = true
		properties := entry["inputSchema"].(map[string]any)["properties"].(map[string]any)
		if _, ok := properties["caller_token"]; ok {
			t.Fatal("Miko can impersonate a caller")
		}
	}
	if !reflect.DeepEqual(actual, expected) || len(actual) != 97 {
		t.Fatalf("catalog omission or self/grant exposure: got %d expected %d", len(actual), len(expected))
	}
	file, e := os.ReadFile("../../../../Sources/Relay/Resources/Rotation/miko_tool_catalog.json")
	if e != nil {
		t.Fatal(e)
	}
	current, _ := json.Marshal(mikoCatalog())
	var a, b any
	if json.Unmarshal(current, &a) != nil || json.Unmarshal(file, &b) != nil || !reflect.DeepEqual(a, b) {
		t.Fatal("Swift catalog differs from production MCP catalog")
	}
}

func TestMikoCompilerRefusesSelfAndPermissions(t *testing.T) {
	for _, name := range []string{"relay_miko_set_capabilities", "relay_miko_turn", "relay_ask_miko", "relay_register_caller", "relay_control_caller", "relay_begin_terminal_control", "relay_authorize_r_session", "relay_call_tool", "relay_available_tools"} {
		b, _ := json.Marshal(map[string]any{"tool_name": name, "arguments": map[string]any{}})
		if _, e := compileMikoPlan(b); e == nil {
			t.Fatalf("%s exposed", name)
		}
	}
}

func TestMikoCannotChangeSecuritySettings(t *testing.T) {
	for _, key := range []string{"miko_autonomy", "miko_minute", "miko_hour", "miko_target_minute", "miko_repetitions", "miko_paused"} {
		args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "11111111-1111-4111-8111-111111111111", "expected_revision": strings.Repeat("a", 64), "changes": map[string]any{key: "autonomous"}}
		wire, _ := json.Marshal(map[string]any{"tool_name": "relay_update_settings", "arguments": args})
		if _, e := compileMikoPlan(wire); e == nil {
			t.Fatalf("compiler lets Miko change %s", key)
		}
		params, _ := json.Marshal(map[string]any{"name": "relay_update_settings", "arguments": args})
		// No client configured. A security-setting request must be rejected before HTTP.
		_, code, _ := (&server{}).handle(request{Method: "tools/call", Params: params})
		if code != -32602 {
			t.Fatalf("MCP settings policy admitted %s: %d", key, code)
		}
	}
}

func TestMikoCompilerPreservesIDsAndRevision(t *testing.T) {
	args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "expected_revision": strings.Repeat("b", 64), "changes": map[string]any{"font_size": 14}}
	wire, _ := json.Marshal(map[string]any{"tool_name": "relay_update_settings", "arguments": args})
	plan, e := compileMikoPlan(wire)
	if e != nil {
		t.Fatal(e)
	}
	var body map[string]any
	_ = json.Unmarshal(plan.Body, &body)
	for _, k := range []string{"instance", "request_id", "expected_revision"} {
		if !reflect.DeepEqual(args[k], body[k]) {
			t.Fatalf("%s changed", k)
		}
	}
	if plan.Path != "/api/settings" || plan.Method != "POST" {
		t.Fatalf("wrong dispatch %v", plan)
	}
}

func TestMikoHostNamespaceAndKeys(t *testing.T) {
	for _, operation := range []string{"caller_register", "agent_accounts", "host_rotation", "screen_capture", "file_delete"} {
		if mikoHostArguments(map[string]any{"operation": operation}) == nil {
			t.Fatal("hidden authority exposed", operation)
		}
	}
	for _, operation := range []string{"exec", "status", "input", "cancel", "process_list", "process_signal", "capabilities", "file_stat", "file_list", "file_read", "file_write", "file_verify"} {
		if e := mikoHostArguments(map[string]any{"operation": operation}); e != nil {
			t.Fatal("cataloged operation dropped", e)
		}
		if mikoHostArguments(map[string]any{"operation": operation, "extra": true}) == nil {
			t.Fatal("extra host key accepted", operation)
		}
	}
}

func FuzzMikoJSON(f *testing.F) {
	for _, seed := range []string{`{}`, `{"x":"exact-UUID"}`, `{"x":1,"x":2}`, `{"a":[true,null,1]}`, `{"truncated":`, "\xff"} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		value, e := mikoJSON(b)
		if e != nil {
			return
		}
		if len(b) > 65536 {
			t.Fatal("allocation bound accepted")
		}
		encoded, e := json.Marshal(value)
		if e != nil {
			t.Fatal(e)
		}
		round, e := mikoJSON(encoded)
		if e != nil || !reflect.DeepEqual(round, value) {
			t.Fatal("JSON round trip changed IDs/values")
		}
		if _, e := mikoJSON(append(append([]byte{}, b...), []byte(" false")...)); e == nil {
			t.Fatal("trailing value accepted")
		}
		if _, e := mikoJSON([]byte(`{"value":` + string(encoded) + `,"value":null}`)); e == nil {
			t.Fatal("duplicate key accepted")
		}
	})
}

func FuzzMikoCompiler(f *testing.F) {
	for _, seed := range []string{`{"tool_name":"relay_list_panes","arguments":{}}`, `{"tool_name":"relay_get_settings","arguments":{}}`, `{"tool_name":"relay_miko_set_capabilities","arguments":{}}`, `{"tool_name":"relay_workspace_request","arguments":{"tab_id":"11111111-1111-4111-8111-111111111111","request":{"operation":"capabilities"}}}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		plan, e := compileMikoPlan(b)
		var output bytes.Buffer
		cliError := mikoCLI("--miko-plan", bytes.NewReader(b), &output)
		if (e == nil) != (cliError == nil) {
			t.Fatal("CLI and compiler disagree on input acceptance")
		}
		if e != nil {
			return
		}
		var wire map[string]any
		if output.Len() > 300_000 || json.Unmarshal(output.Bytes(), &wire) != nil || len(wire) != 5 || wire["tool"] != plan.Tool || wire["method"] != plan.Method || wire["path"] != plan.Path {
			t.Fatal("CLI changed the bounded compiler envelope or exact tool/route")
		}
		if mikoExcluded(plan.Tool) || !strings.HasPrefix(plan.Path, "/api/") || strings.Contains(plan.Path, "..") || len(plan.Body) > 262144 {
			t.Fatal("compiled outside bounded exposed route")
		}
		var envelope map[string]any
		_ = json.Unmarshal(b, &envelope)
		if envelope["tool_name"] != plan.Tool {
			t.Fatal("tool identity changed")
		}
		envelope["extra"] = true
		extra, _ := json.Marshal(envelope)
		if _, e := compileMikoPlan(extra); e == nil {
			t.Fatal("extra envelope key accepted")
		}
		// A complete object ends in }; every proper byte prefix must fail.
		trimmed := bytes.TrimSpace(b)
		if len(trimmed) > 0 {
			if _, e := compileMikoPlan(trimmed[:len(trimmed)-1]); e == nil {
				t.Fatal("truncated JSON compiled")
			}
		}
		args, _ := envelope["arguments"].(map[string]any)
		args["miko_unknown_argument"] = true
		delete(envelope, "extra")
		bad, _ := json.Marshal(envelope)
		if _, e := compileMikoPlan(bad); e == nil {
			t.Fatal("unknown tool argument accepted")
		}
	})
}

func FuzzMikoHostArguments(f *testing.F) {
	f.Add([]byte(`{"operation":"exec","command":"printf test","job_id":"test"}`))
	f.Add([]byte(`{"operation":"process_signal","process_pid":42,"process_start":"123","signal":"terminate"}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		value, e := mikoJSON(b)
		if e != nil {
			return
		}
		r, ok := value.(map[string]any)
		if !ok {
			return
		}
		if mikoHostArguments(r) != nil {
			return
		}
		keys := make([]string, 0, len(r))
		for k := range r {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		r["grant_self"] = true
		if mikoHostArguments(r) == nil {
			t.Fatal("unfiltered operation field accepted", keys)
		}
	})
}

func TestAccountMoveReceiptCompilesReadOnlyWithExactOriginalIDs(t *testing.T) {
	const instance = "3473935d-01c1-45d7-9e51-0399a97b2e1f"
	const id = "8b6fdc5b-25df-468c-933b-4162aacb4aa1"
	args := map[string]any{"instance": instance, "request_id": id}
	wire, _ := json.Marshal(map[string]any{"tool_name": "relay_account_move_receipt", "arguments": args})
	plan, err := compileMikoPlan(wire)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Method != "GET" || plan.Tier != "read" || plan.Path != "/api/agent-accounts/move-receipts/"+instance+"/"+id {
		t.Fatalf("receipt can dispatch a mutation or changed IDs: %+v", plan)
	}
	for _, bad := range []map[string]any{
		{"instance": instance, "request_id": "descriptive-non-uuid"},
		{"instance": "stale", "request_id": id},
		{"instance": instance, "request_id": id, "account": "business"},
	} {
		b, _ := json.Marshal(map[string]any{"tool_name": "relay_account_move_receipt", "arguments": bad})
		if _, err := compileMikoPlan(b); err == nil {
			t.Fatal("invalid receipt accepted", bad)
		}
	}
}
