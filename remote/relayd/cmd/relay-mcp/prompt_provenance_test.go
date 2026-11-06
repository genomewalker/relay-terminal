package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestPromptProvenanceIsReadOnlyPaneRoute(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	var hits atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Method != "GET" || r.URL.Path != "/api/panes/"+id+"/prompt-provenance" {
			t.Error("wrong prompt provenance request", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"pane_id":"` + id + `","content_stored":false,"latest":{"class":"suggestion_likely","intent":"weak"}}`))
	}))
	defer ts.Close()
	s := server{token: "test", client: ts.Client(), endpoint: ts.URL}
	result, code, _ := s.handle(request{Method: "tools/call", Params: json.RawMessage(`{"name":"relay_prompt_provenance","arguments":{"pane_id":"` + id + `"}}`)})
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatalf("%v %d", result, code)
	}
	// Negatives: no pane, a malformed pane, an extra argument. None reach Relay.
	for _, args := range []string{`{}`, `{"pane_id":"../state"}`, `{"pane_id":"` + id + `","text":"yes"}`} {
		_, code, _ := s.handle(request{Method: "tools/call", Params: json.RawMessage(`{"name":"relay_prompt_provenance","arguments":` + args + `}`)})
		if code != -32602 {
			t.Fatalf("accepted %s: %d", args, code)
		}
	}
	if hits.Load() != 1 {
		t.Fatalf("Relay contacted %d times", hits.Load())
	}
}

func TestPromptProvenanceToolStatesWeakIntentRule(t *testing.T) {
	s := server{token: "test"}
	result, _, _ := s.handle(request{Method: "tools/list"})
	for _, entry := range result.(map[string]any)["tools"].([]any) {
		item := entry.(map[string]any)
		if item["name"] != "relay_prompt_provenance" {
			continue
		}
		description := item["description"].(string)
		for _, want := range []string{"suggestion_likely", "programmatic", "pasted", "weak intent", "newly typed text",
			"install", "delete", "kill", "restart", "relaying an approval", "stores no keystrokes", "Read-only", "computer use", "synthesized_keys", "never read as typed", "does not prove a person pressed the keys"} {
			if !strings.Contains(description, want) {
				t.Errorf("description lacks %q", want)
			}
		}
		schema := item["inputSchema"].(map[string]any)
		if props := schema["properties"].(map[string]any); len(props) != 2 || props["pane_id"] == nil || props["caller_token"] == nil {
			t.Fatalf("schema %v", schema)
		}
		if item["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Fatal("not marked read-only")
		}
		return
	}
	t.Fatal("relay_prompt_provenance not listed")
}
