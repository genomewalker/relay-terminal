package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestWorkspaceActions(t *testing.T) {
	id := "11111111-1111-4111-8111-111111111111"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("X-Relay-Token") != "secret" {
			t.Error("missing auth")
		}
		if r.Method == "POST" {
			var body map[string]string
			if json.NewDecoder(r.Body).Decode(&body) != nil || len(body) != 4 || body["paneID"] != id || body["requestID"] != id || body["instance"] != id || r.URL.Path != "/api/workspace/request" {
				t.Error("wrong proposal")
			}
		} else if r.URL.Path != "/api/workspace/receipts/"+id {
			t.Error("wrong receipt path")
		}
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	for _, action := range []string{"select", "splitRight", "splitDown", "zoom", "unzoom", "float", "dock", "balance", "close", "destroy", ""} {
		params, _ := json.Marshal(map[string]any{"name": "relay_request_workspace_action", "arguments": map[string]string{"instance": id, "request_id": id, "pane_id": id, "action": action}})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if (action == "destroy" || action == "") != (code == -32602) {
			t.Fatal(action, code)
		}
	}
	params, _ := json.Marshal(map[string]any{"name": "relay_workspace_receipt", "arguments": map[string]string{"request_id": id}})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || hits != 10 {
		t.Fatal(code, hits)
	}
	for _, args := range []map[string]string{
		{"instance": id, "request_id": id, "pane_id": "../bad", "action": "close"},
		{"instance": id, "request_id": id, "pane_id": id, "action": "close", "confirm": "true"},
	} {
		params, _ := json.Marshal(map[string]any{"name": "relay_request_workspace_action", "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if code != -32602 {
			t.Fatal("accepted unsafe args")
		}
	}
	if hits != 10 {
		t.Fatal("invalid request reached app")
	}
}

func TestGrantedWorkspaceToolsRouteWithoutPerActionApproval(t *testing.T) {
	id := "11111111-1111-4111-8111-111111111111"
	paths := []string{}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Token") != "secret" || r.Method != "POST" {
			t.Error("workspace tool lacked authenticated POST")
		}
		paths = append(paths, r.URL.Path)
		w.Write([]byte(`{"status":"applied"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	cases := []struct {
		name string
		args map[string]string
		path string
	}{
		{"relay_begin_terminal_control", map[string]string{}, "/api/workspace/grant"},
		{"relay_select_pane", map[string]string{"pane_id": id}, "/api/workspace/select/" + id},
		{"relay_workspace_action", map[string]string{"instance": id, "request_id": id, "pane_id": id, "action": "newTab"}, "/api/workspace/apply"},
		{"relay_new_local_tab", map[string]string{"instance": id, "request_id": id}, "/api/workspace/new-local-tab"},
		{"relay_send_command", map[string]string{"instance": id, "request_id": id, "pane_id": id, "text": "pwd"}, "/api/panes/" + id + "/input-direct"},
	}
	for _, c := range cases {
		params, _ := json.Marshal(map[string]any{"name": c.name, "arguments": c.args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if code != 0 || paths[len(paths)-1] != c.path {
			t.Fatalf("%s: code %d, paths %v", c.name, code, paths)
		}
	}
	before := len(paths)
	for _, c := range []struct {
		name string
		args map[string]string
	}{
		{"relay_begin_terminal_control", map[string]string{"unexpected": "true"}},
		{"relay_select_pane", map[string]string{"pane_id": "../bad"}},
		{"relay_workspace_action", map[string]string{"instance": id, "request_id": id, "pane_id": id, "action": "destroy"}},
		{"relay_new_local_tab", map[string]string{"instance": id, "request_id": "bad"}},
		{"relay_send_command", map[string]string{"instance": id, "request_id": id, "pane_id": id, "text": ""}},
	} {
		params, _ := json.Marshal(map[string]any{"name": c.name, "arguments": c.args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if code != -32602 {
			t.Fatalf("%s accepted invalid arguments", c.name)
		}
	}
	if len(paths) != before {
		t.Fatal("invalid request reached Relay")
	}
}

func TestTerminalControlToolListUsesSingleGrant(t *testing.T) {
	s := server{}
	result, code, _ := s.handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal(code)
	}
	tools := result.(map[string]any)["tools"].([]any)
	names := map[string]bool{}
	for _, entry := range tools {
		item := entry.(map[string]any)
		name := item["name"].(string)
		names[name] = true
		if name == "relay_begin_terminal_control" || name == "relay_select_pane" || name == "relay_workspace_action" || name == "relay_new_local_tab" || name == "relay_send_command" {
			annotation := item["annotations"].(map[string]any)
			if annotation["readOnlyHint"] != false {
				t.Fatalf("%s is incorrectly marked read-only", name)
			}
		}
	}
	for _, name := range []string{"relay_begin_terminal_control", "relay_select_pane", "relay_workspace_action", "relay_new_local_tab", "relay_send_command"} {
		if !names[name] {
			t.Fatalf("missing %s", name)
		}
	}
	for _, name := range []string{"relay_request_workspace_action", "relay_request_local_pane", "relay_request_input"} {
		if names[name] {
			t.Fatalf("legacy per-action approval tool %s is still advertised", name)
		}
	}
}
