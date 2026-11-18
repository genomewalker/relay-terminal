package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A structured pane-operation refusal from Relay (a JSON 409 body) reaches the
// MCP tool result with its reason code, blocker and clearing advice intact.
func TestPaneOperationRefusalReachesTheToolResult(t *testing.T) {
	refusal := `{"blocker":"Pane is no longer a running Relay terminal on this host","how_to_clear":"List the host's managed panes again; the pane is gone or no longer running.","reason_code":"not_recoverable","status":"refused"}`
	serverHTTP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(refusal))
	}))
	defer serverHTTP.Close()
	s := server{token: "test", endpoint: serverHTTP.URL, client: serverHTTP.Client()}
	args := map[string]any{"instance": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "request_id": "11111111-2222-3333-4444-555555555555",
		"pane_id": "99999999-8888-7777-6666-555555555555", "host": "fixture-host"}
	params, _ := json.Marshal(map[string]any{"name": "relay_terminate_managed_pane", "arguments": args})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	m, ok := result.(map[string]any)
	if code != 0 || !ok || m["isError"] != true {
		t.Fatalf("result=%v code=%d", result, code)
	}
	text := m["content"].([]any)[0].(map[string]string)["text"]
	if !strings.Contains(text, refusal) {
		t.Fatalf("refusal not passed through intact: %q", text)
	}
}
