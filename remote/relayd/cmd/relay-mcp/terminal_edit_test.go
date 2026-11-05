package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTerminalEditingCompilerSeparatesReadsKeysAndPaste(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	for _, test := range []struct {
		name               string
		args               map[string]any
		method, path, tier string
	}{
		{"relay_terminal_edit_state", map[string]any{"pane_id": id}, "GET", "/api/panes/" + id + "/terminal-edit-state", "read"},
		{"relay_terminal_edit_receipt", map[string]any{"pane_id": id, "instance": id, "request_id": id}, "GET", "/api/terminal-edits/receipts/" + id + "/" + id + "/" + id, "read"},
		{"relay_terminal_edit", map[string]any{"pane_id": id, "instance": id, "request_id": id, "proof_id": id, "action": "key", "key": "escape"}, "POST", "/api/panes/" + id + "/terminal-edit", "change"},
		{"relay_terminal_edit", map[string]any{"pane_id": id, "instance": id, "request_id": id, "proof_id": id, "action": "insert_text", "text": "hello\nworld"}, "POST", "/api/panes/" + id + "/terminal-edit", "change"},
	} {
		b, _ := json.Marshal(map[string]any{"tool_name": test.name, "arguments": test.args})
		plan, err := compileMikoPlan(b)
		if err != nil {
			t.Fatal(test.name, err)
		}
		if plan.Method != test.method || plan.Path != test.path || plan.Tier != test.tier {
			t.Fatalf("wrong admission %+v", plan)
		}
		if test.name == "relay_terminal_edit" {
			var body map[string]any
			json.Unmarshal(plan.Body, &body)
			if body["requestID"] != id || body["proofID"] != id || body["action"] != test.args["action"] {
				t.Fatal("changed request", body)
			}
			if _, ok := body["return"]; ok {
				t.Fatal("implicit command submission")
			}
		}
	}
}

func TestTerminalEditingRejectsUnsafeOrMalformedInput(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	base := map[string]any{"pane_id": id, "instance": id, "request_id": id, "proof_id": id, "action": "key", "key": "escape"}
	for _, delta := range []map[string]any{
		{"instance": "stale"}, {"proof_id": "named-token"}, {"request_id": "readable-name"},
		{"key": "unknown"}, {"text": "hidden"}, {"modifiers": []string{"command"}},
		{"modifiers": []string{"control", "control"}}, {"modifiers": nil}, {"extra": true},
		{"action": "insert_text", "key": nil, "text": "hi\x1b[2J"},
		{"action": "insert_text", "key": nil, "text": strings.Repeat("x", 8193)},
	} {
		args := map[string]any{}
		for k, v := range base {
			args[k] = v
		}
		for k, v := range delta {
			args[k] = v
		}
		b, _ := json.Marshal(map[string]any{"tool_name": "relay_terminal_edit", "arguments": args})
		if _, err := compileMikoPlan(b); err == nil {
			t.Fatal("unsafe input accepted", delta)
		}
	}
}
