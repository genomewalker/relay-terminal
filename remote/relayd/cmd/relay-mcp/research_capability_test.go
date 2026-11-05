package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const researchContract = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func researchArgs(overrides map[string]any, drop ...string) map[string]any {
	args := map[string]any{
		"request_id":      "6f1d2c3b-4a59-4e7d-8c1b-2a3f4e5d6c7b",
		"target":          map[string]any{"pane_id": "4fbb85dc-d72a-4af3-a5de-fa569b899b58", "host": "dandy-07", "cwd": "/projects/caeg/people/kbd606/project", "session_id": "019ed12d-session"},
		"provider":        "claude",
		"model":           "claude-opus-5-5",
		"account":         "business",
		"effort":          "high",
		"contract_sha256": researchContract,
		"tools_policy":    map[string]any{"allow": []string{"evidence_read", "evidence_search"}, "deny": []string{"Bash", "WebFetch"}},
		"budget":          map[string]any{"passes": 1, "retries": 0, "wall_seconds": 180, "usd": 3},
	}
	for key, value := range overrides {
		args[key] = value
	}
	for _, key := range drop {
		delete(args, key)
	}
	return args
}

func callResearch(t *testing.T, s *server, name string, args map[string]any) (map[string]any, int) {
	t.Helper()
	encoded, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
	result, code, _ := s.handle(request{Method: "tools/call", Params: encoded})
	if code != 0 {
		return nil, code
	}
	envelope := result.(map[string]any)
	if envelope["isError"] != false {
		t.Fatalf("%s returned an error result: %v", name, envelope)
	}
	content := envelope["content"].([]any)
	var answer map[string]any
	if len(content) != 1 || json.Unmarshal([]byte(content[0].(map[string]string)["text"]), &answer) != nil {
		t.Fatalf("unparseable answer: %v", envelope)
	}
	return answer, 0
}

// A server whose Relay endpoint and daemon helper both record any use. The
// installed-catalog lookup (a pure read relay_call_tool may make) is stubbed out.
func sideEffectServer(t *testing.T) (*server, func() int) {
	var hits atomic.Int32
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusTeapot)
	}))
	t.Cleanup(relay.Close)
	dir := t.TempDir()
	marker := filepath.Join(dir, "daemon-called")
	helper := filepath.Join(dir, "relayd")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\ntouch '"+marker+"'\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	s := &server{endpoint: relay.URL, token: "test-token", daemonHelper: helper,
		catalogRunner: func(string, []byte) ([]byte, error) { return nil, os.ErrNotExist }}
	return s, func() int {
		n := int(hits.Load())
		if _, err := os.Stat(marker); err == nil {
			n++
		}
		return n
	}
}

func TestResearchCapabilityIsListedReadOnlyAndStrict(t *testing.T) {
	raw, code, _ := (&server{}).handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatalf("tools/list failed: %d", code)
	}
	var found map[string]any
	count := 0
	for _, x := range raw.(map[string]any)["tools"].([]any) {
		if entry := x.(map[string]any); entry["name"] == "relay_research_capability" {
			found, count = entry, count+1
		}
	}
	if count != 1 {
		t.Fatalf("listed %d times", count)
	}
	annotations := found["annotations"].(map[string]any)
	if annotations["readOnlyHint"] != true || annotations["destructiveHint"] != false || annotations["openWorldHint"] != false {
		t.Fatalf("not advertised as read-only: %v", annotations)
	}
	schema := found["inputSchema"].(map[string]any)
	if schema["additionalProperties"] != false || strings.Join(schema["required"].([]string), ",") != "request_id,target,provider,contract_sha256" {
		t.Fatalf("schema is not strict: %v", schema)
	}
	if !strings.Contains(found["description"].(string), "supported:false") {
		t.Fatal("description does not state the refusal")
	}
	for _, entry := range mikoCatalog() {
		if entry["name"] == "relay_research_capability" {
			t.Fatal("offered to Miko")
		}
	}
}

func TestResearchCapabilityRefusesEveryValidRequest(t *testing.T) {
	cases := map[string]map[string]any{
		"claude full":      researchArgs(nil),
		"codex full":       researchArgs(map[string]any{"provider": "codex", "model": "gpt-6", "effort": "xhigh"}),
		"minimal":          researchArgs(nil, "model", "account", "effort", "tools_policy", "budget"),
		"target pane only": researchArgs(map[string]any{"target": map[string]any{"pane_id": "57C1DD5B-F283-4933-834B-D01625280261"}}),
		"empty policy":     researchArgs(map[string]any{"tools_policy": map[string]any{}, "budget": map[string]any{}}),
		"caller token":     researchArgs(map[string]any{"caller_token": "registered-client"}),
	}
	for name, args := range cases {
		s, uses := sideEffectServer(t)
		for _, via := range []string{"direct", "relay_call_tool"} {
			var answer map[string]any
			var code int
			if via == "direct" {
				answer, code = callResearch(t, s, "relay_research_capability", args)
			} else {
				inner := map[string]any{}
				for k, v := range args {
					if k != "caller_token" {
						inner[k] = v
					}
				}
				answer, code = callResearch(t, s, "relay_call_tool", map[string]any{"tool_name": "relay_research_capability", "arguments": inner})
			}
			if code != 0 {
				t.Fatalf("%s/%s: valid request refused with %d", name, via, code)
			}
			for _, key := range []string{"supported", "execution_ready", "scope_enforcement", "lifecycle_support", "usage_support"} {
				if answer[key] != false {
					t.Fatalf("%s/%s: %s = %v, must be false until P2", name, via, key, answer[key])
				}
			}
			if answer["request_id"] != args["request_id"] || answer["contract_sha256"] != researchContract ||
				answer["effective_settings"] != nil || answer["version"] != researchCapabilityVersion {
				t.Fatalf("%s/%s: wrong binding: %v", name, via, answer)
			}
			if reasons, ok := answer["unsupported_reasons"].([]any); !ok || len(reasons) == 0 ||
				!strings.HasPrefix(reasons[0].(string), "enforced_native_worker_turn_unavailable") {
				t.Fatalf("%s/%s: reasons missing: %v", name, via, answer["unsupported_reasons"])
			}
		}
		if n := uses(); n != 0 {
			t.Fatalf("%s: preflight touched Relay or the daemon %d times", name, n)
		}
	}
}

func TestResearchCapabilityRejectsMalformedRequests(t *testing.T) {
	long := strings.Repeat("a", 129)
	cases := map[string]map[string]any{
		"no request_id":        researchArgs(nil, "request_id"),
		"no target":            researchArgs(nil, "target"),
		"no provider":          researchArgs(nil, "provider"),
		"no contract":          researchArgs(nil, "contract_sha256"),
		"bad request_id":       researchArgs(map[string]any{"request_id": "not-a-uuid"}),
		"numeric request_id":   researchArgs(map[string]any{"request_id": 7}),
		"null request_id":      researchArgs(map[string]any{"request_id": nil}),
		"unknown provider":     researchArgs(map[string]any{"provider": "gemini"}),
		"provider case":        researchArgs(map[string]any{"provider": "Claude"}),
		"short contract":       researchArgs(map[string]any{"contract_sha256": researchContract[:63]}),
		"uppercase contract":   researchArgs(map[string]any{"contract_sha256": strings.ToUpper(researchContract)}),
		"extra field":          researchArgs(map[string]any{"execute": true}),
		"supported injected":   researchArgs(map[string]any{"supported": true}),
		"target string":        researchArgs(map[string]any{"target": "4fbb85dc-d72a-4af3-a5de-fa569b899b58"}),
		"target no pane":       researchArgs(map[string]any{"target": map[string]any{"host": "dandy-07"}}),
		"target bad pane":      researchArgs(map[string]any{"target": map[string]any{"pane_id": "4fbb85dc"}}),
		"target extra key":     researchArgs(map[string]any{"target": map[string]any{"pane_id": "4fbb85dc-d72a-4af3-a5de-fa569b899b58", "shell": "bash"}}),
		"target null host":     researchArgs(map[string]any{"target": map[string]any{"pane_id": "4fbb85dc-d72a-4af3-a5de-fa569b899b58", "host": nil}}),
		"target relative cwd":  researchArgs(map[string]any{"target": map[string]any{"pane_id": "4fbb85dc-d72a-4af3-a5de-fa569b899b58", "cwd": "project"}}),
		"target bad host":      researchArgs(map[string]any{"target": map[string]any{"pane_id": "4fbb85dc-d72a-4af3-a5de-fa569b899b58", "host": "dandy 07;rm"}}),
		"long model":           researchArgs(map[string]any{"model": long}),
		"empty account":        researchArgs(map[string]any{"account": ""}),
		"unknown effort":       researchArgs(map[string]any{"effort": "ultra"}),
		"policy array":         researchArgs(map[string]any{"tools_policy": []string{"evidence_read"}}),
		"policy unknown key":   researchArgs(map[string]any{"tools_policy": map[string]any{"allow": []string{"evidence_read"}, "sandbox": "off"}}),
		"policy bad tool name": researchArgs(map[string]any{"tools_policy": map[string]any{"allow": []string{"rm -rf /"}}}),
		"policy too many":      researchArgs(map[string]any{"tools_policy": map[string]any{"deny": make([]string, 33)}}),
		"budget negative usd":  researchArgs(map[string]any{"budget": map[string]any{"usd": -1}}),
		"budget zero passes":   researchArgs(map[string]any{"budget": map[string]any{"passes": 0}}),
		"budget float passes":  researchArgs(map[string]any{"budget": map[string]any{"passes": 1.5}}),
		"budget string wall":   researchArgs(map[string]any{"budget": map[string]any{"wall_seconds": "180"}}),
		"budget huge wall":     researchArgs(map[string]any{"budget": map[string]any{"wall_seconds": 86400}}),
		"budget unknown key":   researchArgs(map[string]any{"budget": map[string]any{"tokens": 1000}}),
	}
	for name, args := range cases {
		s, uses := sideEffectServer(t)
		if _, code := callResearch(t, s, "relay_research_capability", args); code != -32602 {
			t.Fatalf("%s: got code %d, want -32602", name, code)
		}
		if n := uses(); n != 0 {
			t.Fatalf("%s: rejection touched Relay or the daemon %d times", name, n)
		}
	}
}
