package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

// relay_new_local_tab anchors and relay_tab_action cross-session move:
// exact bodies forwarded, invalid shapes refused before any HTTP request.
func TestNewLocalTabAnchorAndTabMoveForwarding(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	const other = "22222222-2222-4222-8222-222222222222"
	var bodies []map[string]string
	var paths []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]string
		if json.Unmarshal(raw, &body) != nil {
			t.Errorf("non-string body %s", raw)
		}
		bodies, paths = append(bodies, body), append(paths, r.URL.Path)
		w.Write([]byte(`{"status":"applied"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	call := func(name string, args map[string]string) int {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return code
	}
	ok := []struct {
		name string
		args map[string]string
		path string
		body map[string]string
	}{
		{"relay_new_local_tab", map[string]string{"instance": id, "request_id": id},
			"/api/workspace/new-local-tab", map[string]string{"instance": id, "requestID": id}},
		{"relay_new_local_tab", map[string]string{"instance": id, "request_id": id, "anchor_pane_id": other},
			"/api/workspace/new-local-tab", map[string]string{"instance": id, "requestID": id, "anchorPaneID": other}},
		{"relay_new_local_tab", map[string]string{"instance": id, "request_id": id, "anchor_tab_id": other},
			"/api/workspace/new-local-tab", map[string]string{"instance": id, "requestID": id, "anchorTabID": other}},
		{"relay_tab_action", map[string]string{"instance": id, "request_id": id, "tab_id": id, "action": "move", "target_tab_id": other, "placement": "after"},
			"/api/workspace/tab-action", map[string]string{"instance": id, "requestID": id, "tabID": id, "action": "move", "targetTabID": other, "placement": "after"}},
	}
	for _, c := range ok {
		if code := call(c.name, c.args); code != 0 {
			t.Fatalf("%s %v refused: %d", c.name, c.args, code)
		}
		if paths[len(paths)-1] != c.path || !reflect.DeepEqual(bodies[len(bodies)-1], c.body) {
			t.Fatalf("%s forwarded %s %v, want %s %v", c.name, paths[len(paths)-1], bodies[len(bodies)-1], c.path, c.body)
		}
	}
	before := len(paths)
	twoAnchors, _ := json.Marshal(map[string]any{"name": "relay_new_local_tab", "arguments": map[string]string{
		"instance": id, "request_id": id, "anchor_pane_id": other, "anchor_tab_id": other}})
	if _, code, message := s.handle(request{Method: "tools/call", Params: twoAnchors}); code != -32602 || !strings.Contains(message, "at most one of anchor_pane_id or anchor_tab_id") {
		t.Fatalf("two anchors: %d %q", code, message)
	}
	for _, args := range []map[string]string{
		{"instance": id, "request_id": id, "anchor_pane_id": other, "anchor_tab_id": other}, // two anchors
		{"instance": id, "request_id": id, "anchor_pane_id": "../bad"},                      // not a UUID
		{"instance": id, "request_id": id, "anchor_tab_id": ""},                             // empty
		{"instance": id, "request_id": id, "anchor": other},                                 // unknown key
		{"instance": id, "request_id": id, "anchor_tab_id": other, "host": "dandy-07"},      // extra key
		{"instance": id, "anchor_tab_id": other},                                            // missing request_id
	} {
		if code := call("relay_new_local_tab", args); code != -32602 {
			t.Fatalf("relay_new_local_tab accepted %v", args)
		}
	}
	for _, args := range []map[string]string{
		{"instance": id, "request_id": id, "tab_id": id, "action": "move", "target_tab_id": other, "placement": "beside"},
		{"instance": id, "request_id": id, "tab_id": id, "action": "move", "target_tab_id": "../x", "placement": "after"},
		{"instance": id, "request_id": id, "tab_id": id, "action": "move", "placement": "after"},
	} {
		if code := call("relay_tab_action", args); code != -32602 {
			t.Fatalf("relay_tab_action accepted %v", args)
		}
	}
	if len(paths) != before {
		t.Fatal("invalid request reached Relay")
	}
}
