package main

import (
	"encoding/json"
	"testing"
)

func TestInstalledUpdatePlansAndRefusals(t *testing.T) {
	for _, name := range []string{"relay_apply_installed_update", "relay_installed_update_receipt"} {
		args := map[string]any{"pane_id": "00000000-0000-4000-8000-000000000001", "instance": "00000000-0000-4000-8000-000000000002", "request_id": "00000000-0000-4000-8000-000000000003"}
		planFor := func(a map[string]any) (*mikoPlan, error) {
			b, _ := json.Marshal(map[string]any{"tool_name": name, "arguments": a})
			return compileMikoPlan(b)
		}
		p, e := planFor(args)
		if e != nil {
			t.Fatal(e)
		}
		want := "/api/panes/00000000-0000-4000-8000-000000000001/installed-update"
		method := "POST"
		tier := "change"
		if name == "relay_installed_update_receipt" {
			want += "-receipt"
			method = "GET"
			tier = "read"
		}
		if p.Path != want || p.Method != method || p.Tier != tier {
			t.Fatalf("bad plan: %+v", p)
		}
		for _, key := range []string{"pane_id", "instance", "request_id"} {
			old := args[key]
			args[key] = "bad"
			if _, e = planFor(args); e == nil {
				t.Fatalf("accepted bad %s", key)
			}
			args[key] = old
		}
		args["command"] = "anything"
		if _, e = planFor(args); e == nil {
			t.Fatal("accepted arbitrary command")
		}
		delete(args, "command")
		delete(args, "request_id")
		if _, e = planFor(args); e == nil {
			t.Fatal("accepted missing request")
		}
	}
}
