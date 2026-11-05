package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWorkspaceMigrationPreviewIsReadOnly(t *testing.T) {
	var routes []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		routes = append(routes, r.Method+" "+r.URL.Path)
		_, _ = w.Write([]byte(`{"schema_version":1,"apply":"preview_checksum"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	catalog, _, _ := s.handle(request{Method: "tools/list"})
	encoded, _ := json.Marshal(catalog)
	var listed struct {
		Tools []struct {
			Name        string `json:"name"`
			Annotations struct {
				ReadOnly bool `json:"readOnlyHint"`
			} `json:"annotations"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(encoded, &listed); err != nil {
		t.Fatal(err)
	}
	var migration []string
	for _, tool := range listed.Tools {
		if strings.Contains(tool.Name, "migration") {
			migration = append(migration, tool.Name)
			if tool.Annotations.ReadOnly != (tool.Name == "relay_workspace_migration_preview") {
				t.Fatalf("wrong read-only hint for %s", tool.Name)
			}
		}
	}
	if strings.Join(migration, ",") != "relay_workspace_migration_preview,relay_workspace_migration_stage_plan,relay_workspace_migration_apply,relay_workspace_migration_undo" {
		t.Fatalf("unexpected migration tools: %v", migration)
	}
	call := func(name string, args map[string]any) int {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return code
	}
	if code := call("relay_workspace_migration_preview", map[string]any{}); code != 0 {
		t.Fatalf("preview read failed: %d", code)
	}
	for _, args := range []map[string]any{{"apply": true}, {"undo": "id"}, {"plan": "{}"}} {
		if code := call("relay_workspace_migration_preview", args); code != -32602 {
			t.Fatalf("preview accepted arguments %v: %d", args, code)
		}
	}
	if len(routes) != 1 || routes[0] != "GET /api/workspace/migration-preview" {
		t.Fatalf("unexpected routes: %v", routes)
	}
}

// Staging never applies: it only reaches the stage route, whatever its
// arguments. Apply needs the open preview's exact ID and checksum, and undo
// an exact migration ID; each reaches only its own route.
func TestWorkspaceMigrationStageDoesNotApplyAndApplyRequiresChecksum(t *testing.T) {
	var routes []string
	var bodies []map[string]json.RawMessage
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		routes = append(routes, r.Method+" "+r.URL.Path)
		var body map[string]json.RawMessage
		_ = json.NewDecoder(r.Body).Decode(&body)
		bodies = append(bodies, body)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	call := func(name string, args map[string]any) int {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return code
	}
	plan := map[string]any{"description": "d", "overrides": map[string]string{}, "keepEmptyGroups": false}
	id := "0f1e2d3c-4b5a-4968-8776-655443322110"
	checksum := strings.Repeat("ab", 32)
	for _, args := range []map[string]any{
		{}, {"plan": "{}"}, {"plan": []any{}}, {"plan": plan, "apply": true}, {"plan": plan, "undo": "id"},
		{"plan": plan, "preview_id": id, "checksum": checksum}, {"plan": plan, "path": "/tmp/plan.json"},
		{"path": "relative.json"}, {"path": "/tmp/plan.txt"}, {"path": "/tmp/a\nb.json"},
		{"plan": plan, "name": "../escape"}, {"plan": plan, "name": ".hidden"}, {"plan": plan, "replace": "yes"},
		{"plan": map[string]any{"pad": strings.Repeat("x", 1<<20)}},
	} {
		if code := call("relay_workspace_migration_stage_plan", args); code != -32602 {
			t.Fatalf("stage accepted %v: %d", args, code)
		}
	}
	for _, args := range []map[string]any{
		{}, {"preview_id": id}, {"checksum": checksum}, {"preview_id": "x", "checksum": checksum},
		{"preview_id": id, "checksum": "abc"}, {"preview_id": id, "checksum": strings.ToUpper(checksum)},
		{"preview_id": id, "checksum": checksum, "plan": plan},
	} {
		if code := call("relay_workspace_migration_apply", args); code != -32602 {
			t.Fatalf("apply accepted %v: %d", args, code)
		}
	}
	for _, args := range []map[string]any{{}, {"migration_id": "x"}, {"migration_id": id, "preview_id": id}} {
		if code := call("relay_workspace_migration_undo", args); code != -32602 {
			t.Fatalf("undo accepted %v: %d", args, code)
		}
	}
	if len(routes) != 0 {
		t.Fatalf("invalid calls reached Relay: %v", routes)
	}
	for _, step := range []struct {
		name string
		args map[string]any
	}{
		{"relay_workspace_migration_stage_plan", map[string]any{"plan": plan, "name": "plan-20261017", "replace": true}},
		{"relay_workspace_migration_stage_plan", map[string]any{"path": "/Users/me/work/workspace-migration-plan-20261017.json"}},
		{"relay_workspace_migration_apply", map[string]any{"preview_id": strings.ToUpper(id), "checksum": checksum}},
		{"relay_workspace_migration_undo", map[string]any{"migration_id": id}},
	} {
		if code := call(step.name, step.args); code != 0 {
			t.Fatalf("%s failed: %d", step.name, code)
		}
	}
	want := "POST /api/workspace/migration-stage,POST /api/workspace/migration-stage,POST /api/workspace/migration-apply,POST /api/workspace/migration-undo"
	if strings.Join(routes, ",") != want {
		t.Fatalf("unexpected routes: %v", routes)
	}
	if string(bodies[0]["name"]) != `"plan-20261017"` || string(bodies[0]["replace"]) != "true" || len(bodies[0]) != 3 {
		t.Fatalf("unexpected stage body: %v", bodies[0])
	}
	var forwarded map[string]any
	if json.Unmarshal(bodies[0]["plan"], &forwarded) != nil || forwarded["description"] != "d" || forwarded["keepEmptyGroups"] != false {
		t.Fatalf("plan not forwarded intact: %s", bodies[0]["plan"])
	}
	if string(bodies[1]["path"]) != `"/Users/me/work/workspace-migration-plan-20261017.json"` || string(bodies[1]["replace"]) != "false" || len(bodies[1]) != 2 {
		t.Fatalf("unexpected path stage body: %v", bodies[1])
	}
	for _, key := range []string{"preview_id", "checksum", "apply", "undo"} {
		if _, ok := bodies[0][key]; ok {
			t.Fatalf("stage forwarded %s", key)
		}
	}
	if string(bodies[2]["preview_id"]) != `"`+id+`"` || string(bodies[2]["checksum"]) != `"`+checksum+`"` || len(bodies[2]) != 2 {
		t.Fatalf("unexpected apply body: %v", bodies[2])
	}
	if string(bodies[3]["migration_id"]) != `"`+id+`"` || len(bodies[3]) != 1 {
		t.Fatalf("unexpected undo body: %v", bodies[3])
	}
}
