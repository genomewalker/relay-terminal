package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestConfigureContextRotationForwardsExactPaneRequest(t *testing.T) {
	id := "11111111-2222-4333-8444-555555555555"
	var path string
	var body map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Token") != "secret" || r.Method != "POST" {
			t.Error("context rotation lacked authenticated POST")
		}
		path = r.URL.Path
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		w.Write([]byte(`{"status":"applied","enabled":"true","state":"monitoring"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	params, _ := json.Marshal(map[string]any{"name": "relay_configure_context_rotation",
		"arguments": map[string]any{"pane_id": id, "instance": id, "request_id": id, "enabled": true}})
	if _, code, msg := s.handle(request{Method: "tools/call", Params: params}); code != 0 {
		t.Fatalf("code %d %s", code, msg)
	}
	if path != "/api/panes/"+id+"/context-rotation" || body["enabled"] != true || body["requestID"] != id || body["instance"] != id {
		t.Fatalf("forwarded %s %v", path, body)
	}
	for _, args := range []map[string]any{
		{"pane_id": "../bad", "instance": id, "request_id": id, "enabled": true},
		{"pane_id": id, "instance": id, "request_id": id, "enabled": "yes"},
		{"pane_id": id, "instance": id, "request_id": id},
		{"pane_id": id, "instance": id, "request_id": id, "enabled": false, "extra": 1},
	} {
		path = ""
		params, _ := json.Marshal(map[string]any{"name": "relay_configure_context_rotation", "arguments": args})
		if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != -32602 || path != "" {
			t.Fatalf("accepted invalid arguments %v (code %d, path %q)", args, code, path)
		}
	}
}
