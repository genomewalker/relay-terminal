package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func surfaceArgs() map[string]json.RawMessage {
	return map[string]json.RawMessage{"pane_id": json.RawMessage(`"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"`), "surface_id": json.RawMessage(`"11111111-2222-3333-4444-555555555555"`), "generation": json.RawMessage(`"66666666-7777-8888-9999-aaaaaaaaaaaa"`), "revision": json.RawMessage(`1`), "expected_revision": json.RawMessage(`0`), "operation": json.RawMessage(`"snapshot"`), "content": json.RawMessage(`{"kind":"status","text":"fixture"}`)}
}
func TestSurfaceRouteExactRevisionsAndContentDefaults(t *testing.T) {
	path, body, err := surfaceRoute("relay_publish_surface", surfaceArgs(), "scoped")
	if err != nil || path != "/api/surfaces/publish" {
		t.Fatalf("route failed: %v", err)
	}
	var value map[string]json.RawMessage
	json.Unmarshal(body, &value)
	if string(value["revision"]) != "1" || string(value["expectedRevision"]) != "0" || value["owner"] != nil {
		t.Fatalf("wrong authority/revision mapping: %s", body)
	}
	var content map[string]json.RawMessage
	json.Unmarshal(value["content"], &content)
	for _, field := range []string{"title", "status", "columns", "rows"} {
		if content[field] == nil {
			t.Fatal("missing content default", field)
		}
	}
	for _, patch := range []map[string]json.RawMessage{
		{"revision": json.RawMessage(`1.0`)}, {"expected_revision": json.RawMessage(`null`)}, {"revision": json.RawMessage(`2`)},
		{"generation": json.RawMessage(`"wrong"`)}, {"owner": json.RawMessage(`{}`)},
		{"content": json.RawMessage(`{"kind":"status","owner":"forged"}`)},
		{"expected_revision": json.RawMessage(`18446744073709551615`)},
	} {
		args := surfaceArgs()
		for k, v := range patch {
			args[k] = v
		}
		if _, _, err := surfaceRoute("relay_publish_surface", args, "scoped"); err == nil {
			t.Fatal("invalid mutation accepted", patch)
		}
	}
	args := surfaceArgs()
	args["operation"] = json.RawMessage(`"close"`)
	args["content"] = json.RawMessage(`null`)
	if _, _, err := surfaceRoute("relay_publish_surface", args, "scoped"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := surfaceRoute("relay_publish_surface", surfaceArgs(), ""); err == nil {
		t.Fatal("anonymous admitted")
	}
}
func TestSurfaceMCPScopedHeaderRoutesAndBoundedRecovery(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "POST" || r.Header.Get("x-relay-token") != "install" || r.Header.Get("x-relay-caller-token") != "scoped" {
			t.Error("wrong method/credentials")
		}
		if r.URL.Path == "/api/surfaces/content" {
			_, _ = w.Write([]byte(`["` + strings.Repeat("x", (1<<20)+10) + `"]`))
			return
		}
		if r.URL.Path != "/api/surfaces/publish" && r.URL.Path != "/api/surfaces/status" {
			t.Error("wrong path")
		}
		_, _ = w.Write([]byte(`{"status":"committed"}`))
	}))
	defer ts.Close()
	s := server{token: "install", callerToken: "scoped", endpoint: ts.URL, client: ts.Client()}
	call := func(name string, args map[string]json.RawMessage) (any, int, string) {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		return s.handle(request{Method: "tools/call", Params: params})
	}
	result, code, _ := call("relay_publish_surface", surfaceArgs())
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatal("publish failed", code, result)
	}
	query := map[string]json.RawMessage{"pane_id": surfaceArgs()["pane_id"], "include_content": json.RawMessage(`true`)}
	result, code, _ = call("relay_read_surfaces", query)
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatal("bounded >1MB recovery failed")
	}
	query["include_content"] = json.RawMessage(`false`)
	_, code, _ = call("relay_read_surfaces", query)
	if code != 0 {
		t.Fatal(code)
	}
	query["owner"] = json.RawMessage(`{}`)
	_, code, _ = call("relay_read_surfaces", query)
	if code != -32602 || hits != 3 {
		t.Fatal("invalid query reached transport")
	}
	catalog, _, _ := s.handle(request{Method: "tools/list"})
	found := map[string]bool{}
	for _, item := range catalog.(map[string]any)["tools"].([]any) {
		entry := item.(map[string]any)
		name := entry["name"].(string)
		if name == "relay_publish_surface" || name == "relay_read_surfaces" {
			found[name] = true
			if entry["annotations"].(map[string]any)["readOnlyHint"] != (name == "relay_read_surfaces") {
				t.Fatal("wrong metadata")
			}
		}
	}
	if len(found) != 2 {
		t.Fatal("surface tools missing")
	}
}

func TestOwnedSurfaceBindingRejectsOtherPaneBeforeTransport(t *testing.T) {
	args := surfaceArgs()
	bound := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	if _, _, err := surfaceRoute("relay_publish_surface", args, "scoped", bound); err != nil {
		t.Fatal(err)
	}
	args["pane_id"] = json.RawMessage(`"11111111-2222-3333-4444-555555555555"`)
	if _, _, err := surfaceRoute("relay_publish_surface", args, "scoped", bound); err == nil {
		t.Fatal("foreign pane accepted")
	}
	for _, item := range surfaceTools(bound) {
		entry := item.(map[string]any)
		properties := entry["inputSchema"].(map[string]any)["properties"].(map[string]any)
		if properties["pane_id"].(map[string]any)["const"] != bound {
			t.Fatal("catalog omitted pane binding")
		}
	}
}
