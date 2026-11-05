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
