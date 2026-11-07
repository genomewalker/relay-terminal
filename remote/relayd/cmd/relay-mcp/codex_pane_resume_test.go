package main

import (
	"encoding/json"
	"testing"
)

func TestCodexPaneResumeCompilerAndReceipt(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	for _, test := range []struct {
		name, path, tier string
		args             map[string]any
	}{
		{"relay_monitoring_usage", "monitoring-usage", "read", map[string]any{"pane_id": id}},
		{"relay_codex_resume_pane", "codex-resume", "change", map[string]any{"instance": id, "request_id": id, "pane_id": id, "expected_session": id, "target_session": id}},
		{"relay_codex_resume_receipt", "codex-resume-receipt", "read", map[string]any{"request_id": id, "pane_id": id}},
	} {
		raw, _ := json.Marshal(map[string]any{"tool_name": test.name, "arguments": test.args})
		plan, err := compileMikoPlan(raw)
		if err != nil {
			t.Fatal(err)
		}
		expectedMethod := "POST"
		if test.name == "relay_monitoring_usage" {
			expectedMethod = "GET"
		}
		if plan.Path != "/api/panes/"+id+"/"+test.path || plan.Method != expectedMethod || plan.Tier != test.tier {
			t.Fatalf("wrong admission %+v", plan)
		}
		var body map[string]string
		if test.name == "relay_monitoring_usage" {
			continue
		}
		if json.Unmarshal(plan.Body, &body) != nil || body["requestID"] != id {
			t.Fatal("lost request ID")
		}
		if test.tier == "change" && (body["expectedSession"] != id || body["targetSession"] != id) {
			t.Fatal("lost session fence")
		}
	}
}

func TestCodexPaneResumeCompilerRejectsMissingOrInjectedSession(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	for _, target := range []any{nil, "", "latest", id + "; rm", 123} {
		args := map[string]any{"instance": id, "request_id": id, "pane_id": id, "expected_session": id, "target_session": target}
		raw, _ := json.Marshal(map[string]any{"tool_name": "relay_codex_resume_pane", "arguments": args})
		if _, err := compileMikoPlan(raw); err == nil {
			t.Fatalf("accepted target %v", target)
		}
	}
}

func TestPaneResumeCompilerCarriesOnlyAKnownProvider(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	compile := func(extra map[string]any) (*mikoPlan, error) {
		args := map[string]any{"instance": id, "request_id": id, "pane_id": id, "expected_session": id, "target_session": id}
		for key, value := range extra {
			args[key] = value
		}
		raw, _ := json.Marshal(map[string]any{"tool_name": "relay_codex_resume_pane", "arguments": args})
		return compileMikoPlan(raw)
	}
	legacy, err := compile(nil)
	var body map[string]string
	if err != nil || json.Unmarshal(legacy.Body, &body) != nil {
		t.Fatal("legacy Codex request no longer compiles", err)
	}
	if _, ok := body["provider"]; ok {
		t.Fatal("legacy request gained a provider")
	}
	for _, provider := range []string{"codex", "claude"} {
		plan, err := compile(map[string]any{"provider": provider})
		body = nil
		if err != nil || json.Unmarshal(plan.Body, &body) != nil || body["provider"] != provider ||
			plan.Path != "/api/panes/"+id+"/codex-resume" || plan.Tier != "change" {
			t.Fatalf("%s: %+v %v", provider, plan, err)
		}
	}
	for _, provider := range []any{"gemini", "Claude", "claude; rm", "", nil, 1} {
		if _, err := compile(map[string]any{"provider": provider}); err == nil {
			t.Fatalf("accepted provider %v", provider)
		}
	}
	if _, err := compile(map[string]any{"provider": "claude", "target_session": "22222222-2222-4222-8222-222222222222"}); err == nil {
		t.Fatal("Claude resume accepted another session")
	}
	if _, err := compile(map[string]any{"provider": "codex", "extra": "x"}); err == nil {
		t.Fatal("accepted an unknown argument")
	}
}
