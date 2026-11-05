package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

const askInstance = "11111111-1111-4111-8111-111111111111"
const askRequest = "22222222-2222-4222-8222-222222222222"

func catalog(t *testing.T) map[string]map[string]any {
	t.Helper()
	result, code, _ := (&server{}).handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal(code)
	}
	tools := map[string]map[string]any{}
	for _, entry := range result.(map[string]any)["tools"].([]any) {
		item := entry.(map[string]any)
		tools[item["name"].(string)] = item
	}
	return tools
}

func TestMikoAgentToolsAreCatalogedWithSchemas(t *testing.T) {
	tools := catalog(t)
	for name, wantRequired := range map[string][]string{
		"relay_ask_miko":     {"instance", "request_id", "text"},
		"relay_miko_receipt": {"instance", "request_id"},
	} {
		item, ok := tools[name]
		if !ok {
			t.Fatalf("missing %s", name)
		}
		schema := item["inputSchema"].(map[string]any)
		if strings.Join(schema["required"].([]string), ",") != strings.Join(wantRequired, ",") || schema["additionalProperties"] != false {
			t.Fatal(name, schema)
		}
		readOnly := item["annotations"].(map[string]any)["readOnlyHint"].(bool)
		if readOnly != (name == "relay_miko_receipt") {
			t.Fatalf("%s readOnlyHint=%v", name, readOnly)
		}
	}
	text := tools["relay_ask_miko"]["inputSchema"].(map[string]any)["properties"].(map[string]any)["text"].(map[string]any)
	if text["maxLength"] != 4096 {
		t.Fatal(text)
	}
}

// Inventory: every Miko tool the channel treats as mutating is advertised as
// mutating by tool(); a name missing from main.go's mutation list would be
// listed read-only and silently lose the guard.
func TestMikoMutationInventoryMatchesTheCatalog(t *testing.T) {
	tools := catalog(t)
	if !mikoSupervisorMutations["relay_ask_miko"] {
		t.Fatal("relay_ask_miko is not in the Miko mutation inventory")
	}
	for _, raw := range append(mikoSupervisorTools(), mikoAgentTools()...) {
		name := raw.(map[string]any)["name"].(string)
		item, ok := tools[name]
		if !ok {
			t.Fatalf("%s is not advertised", name)
		}
		readOnly := item["annotations"].(map[string]any)["readOnlyHint"].(bool)
		if readOnly == mikoSupervisorMutations[name] {
			t.Fatalf("%s: readOnlyHint=%v but inventory mutation=%v", name, readOnly, mikoSupervisorMutations[name])
		}
	}
}

func TestMikoAskRefusesMalformedArgumentsBeforeAnyProof(t *testing.T) {
	helper, wire := mikoHelper(t, "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6")
	s := &server{daemonHelper: helper, token: "fixture-token", endpoint: "http://127.0.0.1:9"}
	for _, args := range []map[string]any{
		{"instance": askInstance, "request_id": askRequest},
		{"instance": askInstance, "request_id": "not-a-uuid", "text": "hi"},
		{"instance": askInstance, "request_id": askRequest, "text": "  "},
		{"instance": askInstance, "request_id": askRequest, "text": strings.Repeat("x", 4097)},
		{"instance": askInstance, "request_id": askRequest, "text": "hi", "pane_id": "x"},
		{"instance": askInstance, "request_id": askRequest, "text": "hi", "card_id": askRequest},
	} {
		params, _ := json.Marshal(map[string]any{"name": "relay_ask_miko", "arguments": args})
		if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != -32602 {
			t.Fatal("accepted", args, code)
		}
	}
	params, _ := json.Marshal(map[string]any{"name": "relay_miko_receipt", "arguments": map[string]any{"instance": askInstance, "request_id": askRequest, "text": "x"}})
	if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != -32602 {
		t.Fatal("receipt accepted extra argument")
	}
	if _, err := os.Stat(wire); err == nil {
		t.Fatal("a proof was minted for a malformed call")
	}
}

func TestMikoAskNeedsTheVerifiedPaneClient(t *testing.T) {
	params, _ := json.Marshal(map[string]any{"name": "relay_ask_miko", "arguments": map[string]any{"instance": askInstance, "request_id": askRequest, "text": "tidy my tabs"}})
	result, code, _ := (&server{}).handle(request{Method: "tools/call", Params: params})
	if code != 0 || result.(map[string]any)["isError"] != true || !strings.Contains(toolResultText(result), "daemon backend") {
		t.Fatal(result)
	}
}

func toolResultText(result any) string {
	encoded, _ := json.Marshal(result)
	return string(encoded)
}

// The ask is proven for exactly this pane and these argument bytes; the
// agent's request_id travels inside the proven arguments.
func TestMikoAskForwardsTheProvenArguments(t *testing.T) {
	pane := "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"
	for _, name := range []string{"relay_ask_miko", "relay_miko_receipt"} {
		helper, wire := mikoHelper(t, pane)
		var received map[string]string
		desktop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			if r.URL.Path != "/api/miko/supervisor" || r.Method != "POST" || json.Unmarshal(body, &received) != nil {
				w.WriteHeader(400)
				return
			}
			w.Write([]byte(`{"status":"accepted","state":"queued"}`))
		}))
		s := &server{daemonHelper: helper, token: "fixture-token", endpoint: desktop.URL, client: desktop.Client()}
		args := map[string]any{"instance": askInstance, "request_id": askRequest}
		if name == "relay_ask_miko" {
			args["text"] = "Open a tab on dandy-07"
		}
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		result, code, _ := s.handle(request{Method: "tools/call", Params: params})
		desktop.Close()
		if code != 0 || result.(map[string]any)["isError"] != false {
			t.Fatal(name, result)
		}
		data, err := os.ReadFile(wire)
		if err != nil {
			t.Fatal(err)
		}
		var attest map[string]any
		_ = json.Unmarshal(data, &attest)
		if received["tool"] != name || received["supervisor_pane_id"] != pane || attest["source_pane_id"] != pane ||
			attest["pane_id"] != mikoInboxID || received["request_id"] != attest["message_id"] {
			t.Fatal(name, received, attest)
		}
		if attest["text"] != mikoCanonicalText(name, received["arguments"]) ||
			!strings.Contains(received["arguments"], `"request_id":"`+askRequest+`"`) {
			t.Fatal("proof is not bound to the forwarded arguments", attest["text"], received["arguments"])
		}
	}
}
