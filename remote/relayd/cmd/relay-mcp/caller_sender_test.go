package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	callerSenderTarget  = "129286a2-6e69-4d1a-9c83-91a0a2dec1e9"
	callerSenderMessage = "5c1f3f0e-0000-4000-8000-000000000002"
	callerSenderPane    = "800c06ef-203f-4401-bf7a-c67b15985f33"
)

func callerSenderParams(withSource bool) json.RawMessage {
	args := map[string]string{"pane_id": callerSenderTarget, "message_id": callerSenderMessage, "text": "hello"}
	if withSource {
		args["source_pane_id"] = callerSenderPane
	}
	params, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": args})
	return params
}

func TestMessagePaneSchemaMakesSourceOptionalAndSaysWhen(t *testing.T) {
	result, code, _ := (&server{}).handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal("tools/list failed", code)
	}
	for _, entry := range result.(map[string]any)["tools"].([]any) {
		definition := entry.(map[string]any)
		if definition["name"] != "relay_message_pane" {
			continue
		}
		schema := definition["inputSchema"].(map[string]any)
		required, _ := json.Marshal(schema["required"])
		if string(required) != `["pane_id","text"]` {
			t.Fatal("source_pane_id is still required:", string(required))
		}
		if _, ok := schema["properties"].(map[string]any)["source_pane_id"]; !ok {
			t.Fatal("source_pane_id was removed from the schema")
		}
		if !strings.Contains(definition["description"].(string), "Omit source_pane_id only when this helper has a registered caller token; the sender is then shown as the caller label") {
			t.Fatal("description does not state when to omit source_pane_id")
		}
		return
	}
	t.Fatal("relay_message_pane missing from catalog")
}

func TestMessagePaneWithoutSourceOrCallerTokenIsRefusedLocally(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hits++ }))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	_, code, detail := s.handle(request{Method: "tools/call", Params: callerSenderParams(false)})
	if code != -32602 || detail != noSenderRefusal || hits != 0 {
		t.Fatalf("code=%d detail=%q hits=%d", code, detail, hits)
	}
}

func TestMessagePaneCallerSendOmitsSourcePaneAndForwardsToken(t *testing.T) {
	var body map[string]string
	var header string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header = r.Header.Get("x-relay-caller-token")
		if r.Method != "POST" || r.URL.Path != "/api/panes/"+callerSenderTarget+"/message" {
			t.Error("wrong route", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		w.Write([]byte(`{"status":"written_to_socket"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", callerToken: "registered-caller-token", client: ts.Client(), endpoint: ts.URL}
	_, code, detail := s.handle(request{Method: "tools/call", Params: callerSenderParams(false)})
	if code != 0 {
		t.Fatal(code, detail)
	}
	if header != "registered-caller-token" {
		t.Fatal("caller token was not forwarded")
	}
	if _, invented := body["sourcePaneID"]; invented || len(body) != 2 || body["messageID"] != callerSenderMessage || body["text"] != "hello" {
		t.Fatalf("a pane-less send must carry only messageID and text: %v", body)
	}
}

func TestMessagePaneWithSourceKeepsPaneBody(t *testing.T) {
	var body map[string]string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		w.Write([]byte(`{}`))
	}))
	defer ts.Close()
	s := server{token: "secret", callerToken: "registered-caller-token", client: ts.Client(), endpoint: ts.URL}
	if _, code, detail := s.handle(request{Method: "tools/call", Params: callerSenderParams(true)}); code != 0 {
		t.Fatal(code, detail)
	}
	if body["sourcePaneID"] != callerSenderPane {
		t.Fatalf("a named source pane must still be sent unchanged: %v", body)
	}
	// A malformed source is still refused, never treated as an omitted one.
	bad, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"source_pane_id": "not-a-pane", "pane_id": callerSenderTarget, "message_id": callerSenderMessage, "text": "x"}})
	if _, code, _ := s.handle(request{Method: "tools/call", Params: bad}); code != -32602 {
		t.Fatal("malformed source_pane_id was accepted", code)
	}
}

func TestDaemonCommunicationPaneLessSendNeverReachesRelayd(t *testing.T) {
	t.Setenv("RELAY_SESSION", "")
	args := func() map[string]json.RawMessage {
		out := map[string]json.RawMessage{}
		for k, v := range map[string]string{"pane_id": callerSenderTarget, "message_id": callerSenderMessage, "text": "hello"} {
			out[k], _ = json.Marshal(v)
		}
		return out
	}
	// The helper path is a missing file on purpose: reaching relayd would error differently.
	noToken := server{daemonHelper: "/nonexistent/relayd-communication"}
	value, handled := noToken.daemonCommunication("relay_message_pane", args())
	if !handled || value.(map[string]any)["isError"] != true || !strings.Contains(value.(map[string]any)["content"].([]map[string]any)[0]["text"].(string), "Nothing was sent") {
		t.Fatalf("no caller and no pane must be a clear local error: %v handled=%v", value, handled)
	}
	withToken := server{daemonHelper: "/nonexistent/relayd-communication", callerToken: "registered-caller-token", token: "secret"}
	if value, handled := withToken.daemonCommunication("relay_message_pane", args()); handled {
		t.Fatalf("a caller send must fall through to the desktop route: %v", value)
	}
	noDesktop := server{daemonHelper: "/nonexistent/relayd-communication", callerToken: "registered-caller-token"}
	if value, handled := noDesktop.daemonCommunication("relay_message_pane", args()); !handled || value.(map[string]any)["isError"] != true {
		t.Fatalf("without a desktop route a caller send must be refused: %v handled=%v", value, handled)
	}
}

func TestPaneLessSendNamingASessionGetsAClearError(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hits++ }))
	defer ts.Close()
	params, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"pane_id": callerSenderTarget, "message_id": callerSenderMessage, "text": "x",
		"target_session_id": "5c1f3f0e-0000-4000-8000-000000000003"}})
	s := server{token: "secret", callerToken: "registered-caller-token", client: ts.Client(), endpoint: ts.URL}
	_, code, detail := s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 || detail != "a registered caller cannot address a session; omit target_session_id" || hits != 0 {
		t.Fatalf("code=%d detail=%q hits=%d", code, detail, hits)
	}
	// The daemon-helper path says the same and never reaches relayd.
	t.Setenv("RELAY_SESSION", "")
	args := map[string]json.RawMessage{}
	for k, v := range map[string]string{"pane_id": callerSenderTarget, "message_id": callerSenderMessage, "text": "x", "target_session_id": "5c1f3f0e-0000-4000-8000-000000000003"} {
		args[k], _ = json.Marshal(v)
	}
	d := server{daemonHelper: "/nonexistent/relayd-communication", callerToken: "registered-caller-token", token: "secret"}
	value, handled := d.daemonCommunication("relay_message_pane", args)
	if !handled || !strings.Contains(value.(map[string]any)["content"].([]map[string]any)[0]["text"].(string), "cannot address a session; omit target_session_id") {
		t.Fatalf("daemon path: %v handled=%v", value, handled)
	}
}
