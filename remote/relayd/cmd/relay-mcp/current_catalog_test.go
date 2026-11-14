package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCurrentCatalogDispatchesNewToolOnceAndPreservesCredential(t *testing.T) {
	calls := 0
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/api/new-tool" || r.Header.Get("x-relay-caller-token") != "scoped-test" {
			t.Error("route or caller changed")
		}
		w.Write([]byte(`{"state":"checking"}`))
	}))
	defer host.Close()
	s := server{token: "test", callerToken: "scoped-test", endpoint: host.URL, client: host.Client()}
	s.catalogRunner = func(mode string, _ []byte) ([]byte, error) {
		if mode == "--miko-catalog" {
			return []byte(`[{"name":"relay_new_tool"}]`), nil
		}
		return []byte(`{"tool":"relay_new_tool","tier":"change","method":"POST","path":"/api/new-tool","body":{"requestID":"original"}}`), nil
	}
	params := json.RawMessage(`{"name":"relay_call_tool","arguments":{"tool_name":"relay_new_tool","arguments":{}}}`)
	value, code, detail := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || detail != "" || value.(map[string]any)["isError"] != false || calls != 1 {
		t.Fatalf("%v %d %s calls=%d", value, code, detail, calls)
	}
	s.catalogRunner = func(mode string, _ []byte) ([]byte, error) {
		if mode == "--miko-catalog" {
			return []byte(`[{"name":"relay_new_tool"}]`), nil
		}
		return nil, errors.New("schema refused")
	}
	value, _, _ = s.handle(request{Method: "tools/call", Params: params})
	if value.(map[string]any)["isError"] != true || calls != 1 {
		t.Fatal("schema refusal fell through or submitted")
	}
}

func TestCurrentCatalogRefreshIncludesNewTools(t *testing.T) {
	s := server{catalogRunner: func(string, []byte) ([]byte, error) {
		return []byte(`[{"name":"relay_future_tool","description":"new"}]`), nil
	}}
	params := json.RawMessage(`{"name":"relay_available_tools","arguments":{}}`)
	value, code, detail := s.handle(request{Method: "tools/call", Params: params})
	encoded, _ := json.Marshal(value)
	if code != 0 || detail != "" || !strings.Contains(string(encoded), "relay_future_tool") {
		t.Fatalf("missing new tool %d %s", code, detail)
	}
}

func TestAgentCatalogKeepsToolsMikoLeavesOut(t *testing.T) {
	names := func(c []map[string]any) map[string]bool {
		out := map[string]bool{}
		for _, d := range c {
			out[d["name"].(string)] = true
		}
		return out
	}
	agent, miko := names(agentCatalog()), names(mikoCatalog())
	if !agent["relay_show"] || miko["relay_show"] {
		t.Fatal("relay_show must reach agents through relay_call_tool but stay out of Miko")
	}
	if agent["relay_call_tool"] || agent["relay_available_tools"] {
		t.Fatal("the generic helpers must not be callable through themselves")
	}
	for name := range miko {
		if !agent[name] {
			t.Fatal("agent catalog lost a Miko tool", name)
		}
	}
	args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "22222222-2222-4222-8222-222222222222",
		"pane_id": "33333333-3333-4333-8333-333333333333", "items": []string{"/tmp/a.txt"}}
	raw, _ := json.Marshal(map[string]any{"tool_name": "relay_show", "arguments": args})
	if p, e := compileAgentPlan(raw); e != nil || p.Path != "/api/workspace/show" || p.Method != "POST" {
		t.Fatalf("relay_show did not compile for agents: %v %#v", e, p)
	}
	if _, e := compileMikoPlan(raw); e == nil {
		t.Fatal("Miko compiled an excluded tool")
	}
	bad, _ := json.Marshal(map[string]any{"tool_name": "relay_show", "arguments": map[string]any{"items": []string{"/a"}}})
	if _, e := compileAgentPlan(bad); e == nil {
		t.Fatal("agent plan accepted arguments its schema refuses")
	}
}

// A long-running connector reaches a tool only its newer installed image
// knows, compiled with the agent plan; an older image falls back to Miko's.
func TestRelayCallToolUsesTheInstalledAgentCatalog(t *testing.T) {
	var paths []string
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Write([]byte(`{"status":"shown"}`))
	}))
	defer host.Close()
	var modes []string
	s := server{token: "test", callerToken: "scoped-test", endpoint: host.URL, client: host.Client()}
	s.catalogRunner = func(mode string, _ []byte) ([]byte, error) {
		modes = append(modes, mode)
		switch mode {
		case "--agent-catalog":
			return []byte(`[{"name":"relay_future_show"}]`), nil
		case "--agent-plan":
			return []byte(`{"tool":"relay_future_show","tier":"change","method":"POST","path":"/api/workspace/future-show","body":{}}`), nil
		}
		return nil, errors.New("unexpected mode " + mode)
	}
	params := json.RawMessage(`{"name":"relay_call_tool","arguments":{"tool_name":"relay_future_show","arguments":{}}}`)
	value, code, detail := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || detail != "" || value.(map[string]any)["isError"] != false || len(paths) != 1 || paths[0] != "/api/workspace/future-show" {
		t.Fatalf("%v %d %s %v", value, code, detail, paths)
	}
	if strings.Join(modes, ",") != "--agent-catalog,--agent-plan" {
		t.Fatalf("wrong helper modes: %v", modes)
	}
	// An installed image from before --agent-catalog: Miko's subset and plan.
	modes = nil
	s.catalogRunner = func(mode string, _ []byte) ([]byte, error) {
		modes = append(modes, mode)
		switch mode {
		case "--miko-catalog":
			return []byte(`[{"name":"relay_future_show"}]`), nil
		case "--miko-plan":
			return []byte(`{"tool":"relay_future_show","tier":"change","method":"POST","path":"/api/workspace/future-show","body":{}}`), nil
		}
		return nil, errors.New("unknown mode")
	}
	value, _, _ = s.handle(request{Method: "tools/call", Params: params})
	if value.(map[string]any)["isError"] != false || len(paths) != 2 || strings.Join(modes, ",") != "--agent-catalog,--miko-catalog,--miko-plan" {
		t.Fatalf("fallback failed: %v %v", modes, paths)
	}
}
