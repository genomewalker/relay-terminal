package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func waitCall(s *server, arguments map[string]any) (map[string]any, int) {
	params, _ := json.Marshal(map[string]any{"name": "relay_wait_for_command", "arguments": arguments})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if result == nil {
		return nil, code
	}
	return result.(map[string]any), code
}

func TestWaitForCommandIsListedReadOnly(t *testing.T) {
	raw, _, _ := (&server{}).handle(request{Method: "tools/list"})
	for _, entry := range raw.(map[string]any)["tools"].([]any) {
		definition := entry.(map[string]any)
		if definition["name"] != "relay_wait_for_command" {
			continue
		}
		if definition["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Fatal("wait must be read-only")
		}
		description := definition["description"].(string)
		for _, phrase := range []string{"shell-reported", "not verified", "never authorization", "Never writes to the pane"} {
			if !strings.Contains(description, phrase) {
				t.Fatalf("description lacks %q", phrase)
			}
		}
		if mikoExcluded("relay_wait_for_command") != true {
			t.Fatal("a blocking wait is not offered to Miko")
		}
		return
	}
	t.Fatal("relay_wait_for_command not listed")
}

func TestWaitForCommandUsesReadOnlyRouteAndKeepsHandle(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	var bodies []map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/api/panes/"+id+"/command-wait" {
			t.Error("wait must use only the read-only command-wait route", r.Method, r.URL.Path)
		}
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		if json.Unmarshal(data, &body) != nil {
			t.Error("bad body")
		}
		bodies = append(bodies, body)
		if len(bodies) == 1 {
			// No handle supplied: Relay chose 7; the next round must keep it.
			w.Write([]byte(`{"state":"running","after":7,"generation":8,"source":"shell_reported_osc133"}`))
			return
		}
		w.Write([]byte(`{"state":"returned","after":7,"generation":8,"exit_status":3,"source":"shell_reported_osc133"}`))
	}))
	defer ts.Close()
	s := &server{token: "test", endpoint: ts.URL, client: ts.Client()}
	result, code := waitCall(s, map[string]any{"pane_id": id, "timeout_ms": 120000})
	if code != 0 || result["isError"] != false {
		t.Fatalf("%v %d", result, code)
	}
	if len(bodies) != 2 || bodies[0]["after"] != nil || bodies[1]["after"] != float64(7) {
		t.Fatalf("handle not kept across rounds: %v", bodies)
	}
	if bodies[0]["timeout_ms"] != float64(waitForCommandRequestMS) {
		t.Fatalf("one request must fit the HTTP client timeout: %v", bodies[0])
	}
	text := result["content"].([]any)[0].(map[string]string)["text"]
	if !strings.Contains(text, `"state":"returned"`) || !strings.Contains(text, `"exit_status":3`) {
		t.Fatal(text)
	}
}

func TestWaitForCommandReturnsRunningAtDeadline(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(data, &body)
		timeout, _ := body["timeout_ms"].(float64)
		if body["after"] != float64(4) || timeout < 1 || timeout > 5 {
			t.Error("handle or bounded timeout lost", body)
		}
		w.Write([]byte(`{"state":"running","after":4,"generation":5}`))
	}))
	defer ts.Close()
	s := &server{token: "test", endpoint: ts.URL, client: ts.Client()}
	// relay_send_command reports the handle as a decimal string.
	result, code := waitCall(s, map[string]any{"pane_id": id, "after": "4", "timeout_ms": 5})
	if code != 0 || result["isError"] != false || hits < 1 {
		t.Fatalf("%v %d", result, code)
	}
	if !strings.Contains(result["content"].([]any)[0].(map[string]string)["text"], `"state":"running"`) {
		t.Fatal("running not reported")
	}
}

func TestWaitForCommandRejectsInvalidArguments(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("invalid arguments reached Relay")
	}))
	defer ts.Close()
	s := &server{token: "test", endpoint: ts.URL, client: ts.Client()}
	for _, arguments := range []map[string]any{
		{},
		{"pane_id": "not-a-pane"},
		{"pane_id": id, "after": -1},
		{"pane_id": id, "after": "-1"},
		{"pane_id": id, "after": 1.5},
		{"pane_id": id, "timeout_ms": 0},
		{"pane_id": id, "timeout_ms": 600001},
		{"pane_id": id, "text": "echo $?"},
	} {
		if _, code := waitCall(s, arguments); code != -32602 {
			t.Fatalf("accepted %v", arguments)
		}
	}
}

// A stdio wait in flight must not block the client's other tools; cancelling
// it (or closing stdin) stops its polling and it sends no response.
func TestStdioWaitRunsBesideOtherCallsAndCancels(t *testing.T) {
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	started := make(chan struct{}, 4)
	stopped := make(chan struct{}, 4)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/panes/"+id+"/command-wait" {
			// Consume the body so the server watches for the client hanging up.
			_, _ = io.ReadAll(r.Body)
			started <- struct{}{}
			<-r.Context().Done() // Relay is still waiting until the client gives up.
			stopped <- struct{}{}
			return
		}
		w.Write([]byte(`{"text":"prompt","scope":"visible_viewport_only"}`))
	}))
	defer ts.Close()
	s := &server{token: "test", endpoint: ts.URL, client: ts.Client()}
	inReader, inWriter := io.Pipe()
	outReader, outWriter := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- s.run(inReader, outWriter); outWriter.Close() }()
	responses := make(chan map[string]any, 8)
	go func() {
		decoder := json.NewDecoder(outReader)
		for {
			var response map[string]any
			if decoder.Decode(&response) != nil {
				close(responses)
				return
			}
			responses <- response
		}
	}()
	send := func(line string) {
		if _, err := inWriter.Write([]byte(line + "\n")); err != nil {
			t.Fatal(err)
		}
	}
	timeout := time.After(10 * time.Second)
	send(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"relay_wait_for_command","arguments":{"pane_id":"` + id + `","timeout_ms":600000}}}`)
	select {
	case <-started:
	case <-timeout:
		t.Fatal("wait never reached Relay")
	}
	send(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"relay_read_viewport","arguments":{"pane_id":"` + id + `"}}}`)
	select {
	case response := <-responses:
		if response["id"] != float64(2) {
			t.Fatalf("expected the viewport answer while the wait runs, got %v", response)
		}
	case <-timeout:
		t.Fatal("an in-flight wait blocked another tool call")
	}
	send(`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"user"}}`)
	select {
	case <-stopped:
	case <-timeout:
		t.Fatal("cancel did not stop the wait")
	}
	// A second wait is stopped by stdin EOF.
	send(`{"jsonrpc":"2.0","id":"w2","method":"tools/call","params":{"name":"relay_wait_for_command","arguments":{"pane_id":"` + id + `"}}}`)
	select {
	case <-started:
	case <-timeout:
		t.Fatal("second wait never reached Relay")
	}
	inWriter.Close()
	select {
	case <-stopped:
	case <-timeout:
		t.Fatal("stdin EOF did not stop the wait")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-timeout:
		t.Fatal("run did not return after EOF")
	}
	for response := range responses {
		t.Fatalf("a cancelled wait must not answer: %v", response)
	}
}
