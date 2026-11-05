package main

import (
	"encoding/json"
	"testing"
)

func TestExplicitManagementResumeFlagIsPublishedAndCompiled(t *testing.T) {
	var definition map[string]any
	for _, tool := range mikoCatalog() {
		if tool["name"] == "relay_configure_context_rotation" {
			definition = tool
		}
	}
	if definition == nil {
		t.Fatal("missing management tool")
	}
	raw, err := json.Marshal(definition["inputSchema"])
	if err != nil {
		t.Fatal(err)
	}
	var schema struct {
		Properties map[string]struct {
			Type string `json:"type"`
		} `json:"properties"`
	}
	if json.Unmarshal(raw, &schema) != nil || schema.Properties["resume_human_takeover"].Type != "boolean" {
		t.Fatal("explicit resume flag absent from schema")
	}
	args := map[string]any{"pane_id": "00000000-0000-4000-8000-000000000001", "instance": "00000000-0000-4000-8000-000000000002", "request_id": "00000000-0000-4000-8000-000000000003", "enabled": true, "resume_human_takeover": true}
	payload, _ := json.Marshal(map[string]any{"tool_name": "relay_configure_context_rotation", "arguments": args})
	plan, err := compileMikoPlan(payload)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(plan)
	var parsed map[string]any
	if json.Unmarshal(encoded, &parsed) != nil {
		t.Fatal("plan invalid")
	}
	body, ok := parsed["body"].(map[string]any)
	if !ok || body["resumeHumanTakeover"] != true {
		t.Fatalf("resume lost: %s", encoded)
	}
}
