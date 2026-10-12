package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSettingsToolsReadAndApplyTypedPreferences(t *testing.T) {
	var method, path string
	var body map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method, path = r.Method, r.URL.Path
		if r.Header.Get("X-Relay-Token") != "secret" {
			t.Fatal("missing token")
		}
		if r.Method == "POST" {
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
		}
		w.Write([]byte(`{}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	params, _ := json.Marshal(map[string]any{"name": "relay_get_settings", "arguments": map[string]any{}})
	_, code, detail := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || method != "GET" || path != "/api/settings" {
		t.Fatal(code, detail, method, path)
	}
	args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "22222222-2222-4222-8222-222222222222", "expected_revision": strings.Repeat("a", 64), "changes": map[string]any{"intelligence_enabled": true, "font_size": 13.5}}
	params, _ = json.Marshal(map[string]any{"name": "relay_update_settings", "arguments": args})
	_, code, detail = s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || method != "POST" || path != "/api/settings" {
		t.Fatal(code, detail, method, path)
	}
	if body["changes"].(map[string]any)["intelligence_enabled"] != true {
		t.Fatal("lost typed boolean")
	}
	args["changes"] = map[string]any{}
	params, _ = json.Marshal(map[string]any{"name": "relay_update_settings", "arguments": args})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 {
		t.Fatal("accepted empty update")
	}
}
