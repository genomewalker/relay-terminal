package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestWorkspaceOrganizationDiscoveryAndNavigation(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("x-relay-token") != "test" {
			t.Error("missing authentication")
		}
		if r.Method == "GET" && r.URL.Path == "/api/workspace/organization" {
			_, _ = w.Write([]byte(`{"schema_version":2,"navigation":{"kind":"all"}}`))
			return
		}
		if r.Method != "POST" || r.URL.Path != "/api/workspace/apply" {
			t.Errorf("unexpected route: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		switch body["action"] {
		case "overview", "back", "forward", "up":
		default:
			t.Errorf("unexpected action: %q", body["action"])
		}
		_, _ = w.Write([]byte(`{"status":"applied"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	call := func(name string, args map[string]any) int {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return code
	}
	if code := call("relay_workspace_organization", map[string]any{}); code != 0 {
		t.Fatalf("organization discovery failed: %d", code)
	}
	for _, action := range []string{"overview", "back", "forward", "up"} {
		args := map[string]any{"instance": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "request_id": "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee", "pane_id": "cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee", "action": action}
		if code := call("relay_workspace_action", args); code != 0 {
			t.Fatalf("navigation %s failed: %d", action, code)
		}
		args["host"] = "another-host"
		if code := call("relay_workspace_action", args); code != -32602 {
			t.Fatalf("navigation accepted a host change: %d", code)
		}
	}
	if code := call("relay_workspace_organization", map[string]any{"navigate": true}); code != -32602 {
		t.Fatalf("read-only discovery accepted a mutation: %d", code)
	}
	if hits != 5 {
		t.Fatalf("invalid requests reached Relay: %d hits", hits)
	}
}
