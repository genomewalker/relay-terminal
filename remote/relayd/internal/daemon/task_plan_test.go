package daemon

import (
	"encoding/json"
	"testing"
)

func TestNativeTaskPlan(t *testing.T) {
	for _, plan := range []string{`[]`, `[{"step":"Inspect","status":"inProgress"}]`} {
		encoded, err := CanonicalAgentEnvelope("codex", []byte(`{"method":"turn/plan/updated","params":{"threadId":"t","plan":`+plan+`}}`), "codex-app-server")
		if err != nil {
			t.Fatal(err)
		}
		var e struct {
			Event struct {
				Name string         `json:"hook_event_name"`
				Plan []taskPlanStep `json:"plan"`
			} `json:"event"`
		}
		if json.Unmarshal(encoded, &e) != nil || e.Event.Name != "PlanUpdated" || e.Event.Plan == nil {
			t.Fatalf("%s", encoded)
		}
		if len(e.Event.Plan) > 0 && e.Event.Plan[0].Status != "in_progress" {
			t.Fatal("status not normalized")
		}
	}
}

func TestClaudeTodoHookPlan(t *testing.T) {
	encoded, err := CanonicalAgentEnvelope("claude", []byte(`{"hook_event_name":"PostToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Read data","status":"pending"}],"secret":"not retained"}}`), "hook")
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Event struct {
			Name string         `json:"hook_event_name"`
			Plan []taskPlanStep `json:"plan"`
		} `json:"event"`
	}
	if json.Unmarshal(encoded, &envelope) != nil || envelope.Event.Name != "PlanUpdated" || len(envelope.Event.Plan) != 1 {
		t.Fatalf("%s", encoded)
	}
}

func TestStructuredTaskPlan(t *testing.T) {
	events := codexTranscriptEvents([]byte(`{"type":"event_msg","timestamp":"2026-09-19T10:00:00Z","payload":{"type":"plan_update","plan":[{"step":"Inspect","status":"completed"}]}}`))
	if len(events) != 1 || events[0].Event.HookEventName != "PlanUpdated" || len(events[0].Event.Plan) != 1 {
		t.Fatalf("%+v", events)
	}
	if validTaskPlan([]taskPlanStep{{Step: "x", Status: "unknown"}}) {
		t.Fatal("invalid status accepted")
	}
	if codexTranscriptEvents([]byte(`{"type":"event_msg","payload":{"type":"agent_message","message":"plan completed"}}`)) != nil {
		t.Fatal("prose treated as plan")
	}
}

func TestClaudeTaskDeltas(t *testing.T) {
	for _, raw := range []string{
		`{"hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_response":{"task":{"id":"1","subject":"Read data","status":"pending"}}}`,
		`{"hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"completed"}}`,
	} {
		encoded, err := CanonicalAgentEnvelope("claude", []byte(raw), "hook")
		if err != nil {
			t.Fatal(err)
		}
		var e struct {
			Event map[string]any `json:"event"`
		}
		if json.Unmarshal(encoded, &e) != nil || e.Event["hook_event_name"] != "TaskChanged" || e.Event["task_id"] != "1" {
			t.Fatal(string(encoded))
		}
		if _, ok := e.Event["tool_input"]; ok {
			t.Fatal("unbounded tool arguments retained")
		}
	}
}
