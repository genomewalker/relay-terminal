package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestHTTPConflictIncludesBoundedRedactedReason(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		w.Write([]byte("R console is not idle secret-token " + strings.Repeat("x", 2048)))
	}))
	defer ts.Close()
	s := server{token: "secret-token", endpoint: ts.URL, client: ts.Client()}
	_, err := s.fetch("/api/state")
	if err == nil || !strings.Contains(err.Error(), "R console is not idle") ||
		strings.Contains(err.Error(), "secret-token") || len(err.Error()) > 1100 {
		t.Fatalf("unexpected diagnostic: %v", err)
	}
}

func TestDiscoveryAndContext(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "GET" || r.Header.Get("x-relay-token") != "test-secret" {
			t.Error("wrong authentication or method")
		}
		if r.URL.Path != "/api/state" {
			t.Error(r.URL.Path)
		}
		w.Write([]byte(`{"sessions":[]}`))
	}))
	defer ts.Close()
	s := server{token: "test-secret", client: ts.Client(), endpoint: ts.URL}
	var out bytes.Buffer
	err := s.run(strings.NewReader("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"+`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"relay_list_panes","arguments":{}}}`+"\n"), &out)
	if err != nil || hits != 1 {
		t.Fatalf("%v hits=%d", err, hits)
	}
	var response map[string]any
	if json.Unmarshal(out.Bytes(), &response) != nil || response["result"] == nil {
		t.Fatal(out.String())
	}
	if strings.Contains(out.String(), "test-secret") {
		t.Fatal("secret leaked")
	}
}

func TestRejectsUnsafeCalls(t *testing.T) {
	s := server{}
	for _, params := range []string{
		`{"name":"relay_read_agent_context","arguments":{"pane_id":"../../state"}}`,
		`{"name":"relay_list_panes","arguments":{"execute":"bad"}}`,
		`{"name":"relay_send_input","arguments":{}}`,
		`{"name":"relay_network_status","arguments":{"host":"injected"}}`,
		`{"name":"relay_discover_local_peers","arguments":{"execute":true}}`,
		`{"name":"relay_request_local_pane","arguments":{"instance":"bad","request_id":"bad"}}`,
		`{"name":"relay_local_pane_receipt","arguments":{"request_id":"../../state"}}`,
	} {
		_, code, _ := s.handle(request{Method: "tools/call", Params: json.RawMessage(params)})
		if code != -32602 {
			t.Fatal(params, code)
		}
	}
}

func TestLocalPaneProposalRouting(t *testing.T) {
	id := "11111111-1111-4111-8111-111111111111"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("X-Relay-Token") != "secret" {
			t.Error("missing authentication")
		}
		if r.Method != "POST" || r.URL.Path != "/api/local-pane/request" {
			t.Error("wrong proposal route")
		}
		var body map[string]string
		if json.NewDecoder(r.Body).Decode(&body) != nil || len(body) != 2 || body["instance"] != id || body["requestID"] != id {
			t.Error("wrong proposal identity")
		}
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	args := map[string]string{"instance": id, "request_id": id}
	for _, extra := range []bool{false, true} {
		if extra {
			args["command"] = "unexpected"
		}
		params, _ := json.Marshal(map[string]any{"name": "relay_request_local_pane", "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if (!extra && code != 0) || (extra && code != -32602) {
			t.Fatalf("unexpected code %d", code)
		}
	}
	if hits != 1 {
		t.Fatalf("unexpected requests %d", hits)
	}
}

func TestNetworkReadTools(t *testing.T) {
	for name, path := range map[string]string{"relay_network_status": "/api/network/status", "relay_discover_local_peers": "/api/network/local-peers"} {
		t.Run(name, func(t *testing.T) {
			hits := 0
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits++
				if r.Method != "GET" || r.URL.Path != path || r.Header.Get("x-relay-token") != "secret" {
					t.Error("incorrect read-only routing")
				}
				w.Write([]byte(`{"peers":[]}`))
			}))
			defer ts.Close()
			s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
			params, _ := json.Marshal(map[string]any{"name": name, "arguments": map[string]any{}})
			result, code, _ := s.handle(request{Method: "tools/call", Params: params})
			if code != 0 || hits != 1 || result.(map[string]any)["isError"] != false {
				t.Fatalf("result=%v code=%d hits=%d", result, code, hits)
			}
		})
	}
}

func TestProtocolErrors(t *testing.T) {
	s := server{}
	var out bytes.Buffer
	if err := s.run(strings.NewReader("not json\n"), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "-32700") {
		t.Fatal(out.String())
	}
	out.Reset()
	if err := s.run(strings.NewReader(strings.Repeat("x", (1<<20)+(64<<10)+1)), &out); err == nil {
		t.Fatal("unbounded input")
	}
}

func TestResponseBound(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(strings.Repeat(" ", (1<<20)+1))) }))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	if _, err := s.fetch("/api/state"); err == nil {
		t.Fatal("oversized response accepted")
	}
}

func TestViewportUsesReadOnlyPaneRoute(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/api/panes/"+id+"/viewport" {
			t.Error("wrong viewport request", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"text":"R prompt","scope":"visible_viewport_only"}`))
	}))
	defer ts.Close()
	s := server{token: "test", client: ts.Client(), endpoint: ts.URL}
	result, code, _ := s.handle(request{Method: "tools/call", Params: json.RawMessage(`{"name":"relay_read_viewport","arguments":{"pane_id":"` + id + `"}}`)})
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatalf("%v %d", result, code)
	}
}

func TestRProposalRequiresNativeApprovalRoute(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/api/panes/"+id+"/input-request" {
			t.Error("bypassed approval endpoint")
		}
		var proposal map[string]string
		if json.NewDecoder(r.Body).Decode(&proposal) != nil {
			t.Fatal("bad body")
		}
		if proposal["instance"] != id || proposal["requestID"] != id || !strings.HasPrefix(proposal["text"], "relay_r_evaluate(code=") || !strings.Contains(proposal["text"], "plot(cars)") {
			t.Errorf("bad proposal: %v", proposal)
		}
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "test", client: ts.Client(), endpoint: ts.URL}
	params, _ := json.Marshal(map[string]any{"name": "relay_request_r_evaluation", "arguments": map[string]string{"pane_id": id, "instance": id, "request_id": id, "code": "plot(cars)", "artifact_root": "/tmp/results", "expected_session": "r-session"}})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatalf("%v", result)
	}
}

func TestBundledRSetupFitsProposalBudget(t *testing.T) {
	source, err := os.ReadFile("../../../r/relay-r.R")
	if err != nil {
		t.Fatal(err)
	}
	command := rSetupCommand(string(source), ".relay-r")
	if len(command) > 65536 {
		t.Fatalf("setup proposal too large: %d", len(command))
	}
	for _, line := range strings.Split(command, "\n") {
		if len(line) > 4096 {
			t.Fatal("setup exceeds interactive line budget")
		}
	}
	if !strings.HasPrefix(command, "local({\n") || !strings.HasSuffix(command, "\n})") {
		t.Fatal("setup must be one outer expression")
	}
	if !strings.Contains(command, "relay_r_httpgd_start") || !strings.Contains(command, "relay_r_console_start") {
		t.Fatal("plot capture missing")
	}
}

func TestRSetupChunksPreserveSource(t *testing.T) {
	for _, source := range []string{"", strings.Repeat("λ\n\\\"😀", 300)} {
		command := rSetupCommand(source, "/tmp/results")
		start := strings.Index(command, "paste0(\n") + len("paste0(\n")
		end := strings.Index(command[start:], "\n)), envir=.GlobalEnv)") + start
		var decoded strings.Builder
		for _, chunk := range strings.Split(command[start:end], ",\n") {
			var value string
			if err := json.Unmarshal([]byte(chunk), &value); err != nil {
				t.Fatal(err)
			}
			decoded.WriteString(value)
		}
		if decoded.String() != source {
			t.Fatal("source changed in chunking")
		}
	}
}

func TestNetworkActionRequiresApproval(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "POST" || r.URL.Path != "/api/network/request" || r.Header.Get("X-Relay-Token") != "test" {
			t.Error("wrong approval route")
		}
		var body map[string]string
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["linkID"] != id || body["instance"] != id || body["requestID"] != id {
			t.Error("identity lost")
		}
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	for _, action := range []string{"connect", "disconnect", "kill", "", "connect;exec"} {
		params, _ := json.Marshal(map[string]any{"name": "relay_request_network_action", "arguments": map[string]string{"instance": id, "request_id": id, "link_id": id, "action": action}})
		result, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if action == "connect" || action == "disconnect" {
			if code != 0 || result.(map[string]any)["isError"] != false {
				t.Fatal("valid approval rejected")
			}
		} else if code != -32602 {
			t.Fatal("invalid action accepted")
		}
	}
	if hits != 2 {
		t.Fatalf("unexpected mutations: %d", hits)
	}
}

func TestDesktopRouteProposalUsesExactApprovedIdentity(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "POST" || r.URL.Path != "/api/network/desktop-route/request" || r.Header.Get("X-Relay-Token") != "test" {
			t.Error("wrong route")
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["thread"] != id || body["remoteSession"] != id || body["remotePID"] != float64(1234) || body["remoteStart"] != "123456" {
			t.Error("identity lost")
		}
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	args := map[string]any{"instance": id, "request_id": id, "thread": id, "host": "dandy-07", "remote_name": "claude", "remote_session": id, "remote_pid": 1234, "remote_start": "123456"}
	for _, bad := range []string{"", "host;echo bad"} {
		args["host"] = bad
		params, _ := json.Marshal(map[string]any{"name": "relay_request_desktop_route", "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if code != -32602 {
			t.Fatalf("unsafe host accepted: %q", bad)
		}
	}
	args["host"] = "dandy-07"
	params, _ := json.Marshal(map[string]any{"name": "relay_request_desktop_route", "arguments": args})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || result.(map[string]any)["isError"] != false || hits != 1 {
		t.Fatalf("valid proposal failed: %v %d %d", result, code, hits)
	}
}

func TestDirectDesktopRouteAndReadReceiptRouting(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	paths := []string{}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.Method != "POST" {
			t.Error("expected POST")
		}
		w.Write([]byte(`{"status":"launch_requested"}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	args := map[string]any{"instance": id, "request_id": id, "thread": id, "host": "dandy-07", "remote_name": "claude", "remote_session": id, "remote_pid": 1234, "remote_start": "123456"}
	params, _ := json.Marshal(map[string]any{"name": "relay_create_desktop_route", "arguments": args})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 {
		t.Fatal(code)
	}
	params, _ = json.Marshal(map[string]any{"name": "relay_message_read_receipt", "arguments": map[string]string{"reply_name": "relay-test", "message_id": "message-1"}})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || len(paths) != 2 || paths[0] != "/api/network/desktop-route/create" || paths[1] != "/api/network/desktop-route/message-receipt" {
		t.Fatalf("routes: %v code: %d", paths, code)
	}
}

func TestSendDesktopMessageUsesExactSavedRoute(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	var got map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/api/network/desktop-route/send" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Error(err)
		}
		w.Write([]byte(`{"id":"message-1","status":"written_to_socket","updatedAt":1}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	args := map[string]any{"reply_name": "relay-test", "thread": id, "host": "dandy-07", "remote_session": id, "remote_pid": 1234, "remote_start": "123456", "message_id": "message-1", "content": "Hello"}
	params, _ := json.Marshal(map[string]any{"name": "relay_send_desktop_message", "arguments": args})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || got["replyName"] != "relay-test" || got["content"] != "Hello" {
		t.Fatalf("code=%d body=%v", code, got)
	}
	args["content"] = strings.Repeat("x", 60001)
	params, _ = json.Marshal(map[string]any{"name": "relay_send_desktop_message", "arguments": args})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 {
		t.Fatalf("oversized message accepted: %d", code)
	}
}

func TestLocalTokenAndMutationMetadata(t *testing.T) {
	for _, token := range []string{"", "secret", strings.Repeat("a", 63), strings.Repeat("a", 65), strings.Repeat("g", 64), strings.Repeat("a", 64) + "\n"} {
		if validLocalToken(token) {
			t.Fatal("invalid local token accepted")
		}
	}
	if !validLocalToken(strings.Repeat("aB", 32)) {
		t.Fatal("valid token rejected")
	}
	s := server{}
	result, code, _ := s.handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal(code)
	}
	for _, item := range result.(map[string]any)["tools"].([]any) {
		entry := item.(map[string]any)
		name := entry["name"].(string)
		mutation := strings.HasPrefix(name, "relay_request_") || strings.HasPrefix(name, "relay_create_") || strings.HasPrefix(name, "relay_send_")
		switch name {
		case "relay_begin_terminal_control", "relay_select_pane", "relay_workspace_action", "relay_new_local_tab", "relay_recover_pane", "relay_terminate_managed_pane", "relay_call_tool", "relay_tab_action", "relay_exec", "relay_exec_cancel", "relay_host_request", "relay_workspace_request", "relay_bind_workspace_context", "relay_update_settings", "relay_check_host_installation", "relay_message_pane", "relay_link_panes", "relay_unlink_panes", "relay_check_intelligence", "relay_register_caller", "relay_control_caller", "relay_render_content", "relay_publish_surface":
			mutation = true
		}
		if entry["annotations"].(map[string]any)["readOnlyHint"] != !mutation {
			t.Fatalf("wrong mutation metadata: %s", entry["name"])
		}
	}
}

func TestRSessionStatusIsReadOnlyAndScoped(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "GET" || r.URL.Path != "/api/panes/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/r-status" || r.Header.Get("x-relay-token") != "test" {
			t.Errorf("wrong status request: %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"status":"paused","paused":true,"active_request_id":null}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	params, _ := json.Marshal(map[string]any{"name": "relay_r_session_status", "arguments": map[string]any{"pane_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || hits != 1 {
		t.Fatalf("status code %d, hits %d", code, hits)
	}
	params, _ = json.Marshal(map[string]any{"name": "relay_r_session_status", "arguments": map[string]any{"pane_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "resume": true}})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 || hits != 1 {
		t.Fatalf("status accepted mutation: %d", code)
	}
}

func TestScopedCallerHeaderAndErrorRedaction(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-relay-caller-token") != "scoped-secret" {
			t.Error("missing scoped caller header")
		}
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte("paused install-secret scoped-secret"))
	}))
	defer ts.Close()
	s := server{token: "install-secret", callerToken: "scoped-secret", endpoint: ts.URL, client: ts.Client()}
	_, err := s.exchange("POST", "/api/test", []byte(`{}`))
	if err == nil || !strings.Contains(err.Error(), "paused") || strings.Contains(err.Error(), "install-secret") || strings.Contains(err.Error(), "scoped-secret") {
		t.Fatalf("unredacted error: %v", err)
	}
}

func TestHostInstallationCheckMutationHintsAndExactPost(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "POST" || r.URL.Path != "/api/hosts/check" || r.Header.Get("x-relay-token") != "test" {
			t.Errorf("wrong host check request: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body) != 1 || body["host"] != "fixture-host" {
			t.Errorf("wrong host check body: %v %v", body, err)
		}
		w.Write([]byte(`{"state":"checked","installationAttempted":false}`))
	}))
	defer ts.Close()
	s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
	listed, code, _ := s.handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal(code)
	}
	found := false
	for _, item := range listed.(map[string]any)["tools"].([]any) {
		entry := item.(map[string]any)
		if entry["name"] != "relay_check_host_installation" {
			continue
		}
		found = true
		hints := entry["annotations"].(map[string]any)
		if hints["readOnlyHint"] != false || hints["destructiveHint"] != true || hints["openWorldHint"] != true {
			t.Fatalf("persisted manager probe has wrong mutation hints: %v", hints)
		}
	}
	if !found {
		t.Fatal("host check missing")
	}
	params, _ := json.Marshal(map[string]any{"name": "relay_check_host_installation", "arguments": map[string]any{"host": "fixture-host"}})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || hits != 1 {
		t.Fatalf("exact check: code=%d hits=%d", code, hits)
	}
	for _, host := range []string{"", " fixture-host", "fixture-host ", strings.Repeat("x", 257)} {
		params, _ = json.Marshal(map[string]any{"name": "relay_check_host_installation", "arguments": map[string]any{"host": host}})
		_, code, _ = s.handle(request{Method: "tools/call", Params: params})
		if code != -32602 || hits != 1 {
			t.Fatalf("invalid host was forwarded: code=%d hits=%d", code, hits)
		}
	}
}
