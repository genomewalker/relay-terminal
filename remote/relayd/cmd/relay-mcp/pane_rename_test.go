package main

import (
	"encoding/json"
	"testing"
)

func TestPaneRenameCompilerAndValidation(t *testing.T) {
	args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "22222222-2222-4222-8222-222222222222", "pane_id": "33333333-3333-4333-8333-333333333333", "name": "PanBarley · Damage model"}
	compile := func(a map[string]any) error {
		b, _ := json.Marshal(map[string]any{"tool_name": "relay_rename_pane", "arguments": a})
		p, e := compileMikoPlan(b)
		if e == nil {
			if p.Path != "/api/workspace/rename-pane" || p.Method != "POST" || p.Tier != "change" {
				t.Fatalf("wrong rename route: %#v", p)
			}
			var body map[string]any
			_ = json.Unmarshal(p.Body, &body)
			if body["paneID"] != a["pane_id"] || body["requestID"] != a["request_id"] || body["instance"] != a["instance"] || body["name"] != a["name"] {
				t.Fatal("rename target or identity changed")
			}
		}
		return e
	}
	if e := compile(args); e != nil {
		t.Fatal(e)
	}
	for _, patch := range []map[string]any{{"pane_id": "not-an-id"}, {"name": ""}, {"name": "bad\nname"}, {"extra": true}} {
		changed := map[string]any{}
		for k, v := range args {
			changed[k] = v
		}
		for k, v := range patch {
			changed[k] = v
		}
		if compile(changed) == nil {
			t.Fatal("accepted invalid rename", patch)
		}
	}
}
