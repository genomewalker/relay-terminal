package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

// stackServer records every request relay-mcp forwards to Relay.
func stackServer(t testing.TB) (*server, *[]string, *[]map[string]string, func()) {
	var paths []string
	var bodies []map[string]string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Token") != "secret" || r.Method != "POST" {
			t.Error("stack tool lacked authenticated POST")
		}
		raw, _ := io.ReadAll(r.Body)
		var body map[string]string
		if json.Unmarshal(raw, &body) != nil {
			t.Error("stack tool forwarded a non-string object")
		}
		paths = append(paths, r.URL.Path)
		bodies = append(bodies, body)
		w.Write([]byte(`{"status":"stacked"}`))
	}))
	return &server{token: "secret", client: ts.Client(), endpoint: ts.URL}, &paths, &bodies, ts.Close
}

func callTool(s *server, name string, args map[string]any) int {
	params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	return code
}

func TestStackPaneToolsForwardExactRequests(t *testing.T) {
	s, paths, bodies, done := stackServer(t)
	defer done()
	id, other := "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
	if code := callTool(s, "relay_stack_pane", map[string]any{"instance": id, "request_id": id, "pane_id": other, "target_pane_id": id}); code != 0 {
		t.Fatal(code)
	}
	if (*paths)[0] != "/api/workspace/stack-pane" || !reflect.DeepEqual((*bodies)[0], map[string]string{"instance": id, "requestID": id, "paneID": other, "targetPaneID": id}) {
		t.Fatalf("stack forwarded %v %v", *paths, *bodies)
	}
	for _, host := range []string{"This Mac", "dandy-07", "user@login.example.org"} {
		if code := callTool(s, "relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": other, "host": host}); code != 0 {
			t.Fatal(host, code)
		}
		last := len(*paths) - 1
		if (*paths)[last] != "/api/workspace/new-stacked-pane" || !reflect.DeepEqual((*bodies)[last], map[string]string{"instance": id, "requestID": id, "targetPaneID": other, "host": host}) {
			t.Fatalf("new stacked pane forwarded %v %v", *paths, *bodies)
		}
	}
	before := len(*paths)
	for _, c := range []struct {
		name string
		args map[string]any
	}{
		{"relay_stack_pane", map[string]any{"instance": id, "request_id": id, "pane_id": other}},
		{"relay_stack_pane", map[string]any{"instance": id, "request_id": id, "pane_id": "../x", "target_pane_id": id}},
		{"relay_stack_pane", map[string]any{"instance": id, "request_id": id, "pane_id": other, "target_pane_id": id, "split": "right"}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id, "host": ""}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id, "host": "host; rm -rf ~"}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id, "host": " dandy-07"}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id, "host": "-oProxyCommand=x"}},
		{"relay_new_stacked_pane", map[string]any{"instance": id, "request_id": id, "target_pane_id": id, "host": "a", "command": "top"}},
	} {
		if code := callTool(s, c.name, c.args); code != -32602 {
			t.Fatalf("%s accepted %v", c.name, c.args)
		}
	}
	if len(*paths) != before {
		t.Fatal("an invalid stack request reached Relay")
	}
}

// Property: a request reaches Relay only with exactly the four validated
// fields, copied verbatim; the host is "This Mac" or one bare alias token.
func FuzzStackPaneArguments(f *testing.F) {
	id := "11111111-1111-4111-8111-111111111111"
	for _, seed := range []string{"This Mac", "dandy-07", "", " x", "a b", "-o", "x;y", "user@host", "../x", "h\x00", "日本"} {
		f.Add(id, id, id, seed, "")
	}
	f.Add(id, "bad", id, "h", "")
	f.Add(id, id, id, "h", "extra")
	f.Fuzz(func(t *testing.T, instance, requestID, target, host, extra string) {
		s, paths, bodies, done := stackServer(t)
		defer done()
		args := map[string]any{"instance": instance, "request_id": requestID, "target_pane_id": target, "host": host}
		if extra != "" {
			args["command"] = extra
		}
		code := callTool(s, "relay_new_stacked_pane", args)
		if code != 0 {
			if len(*paths) != 0 {
				t.Fatal("a refused request reached Relay")
			}
			return
		}
		if extra != "" || !paneID.MatchString(instance) || !paneID.MatchString(requestID) || !paneID.MatchString(target) {
			t.Fatalf("accepted invalid arguments %v", args)
		}
		if host != "This Mac" && (len(host) == 0 || len(host) > 256 || host[0] == '-') {
			t.Fatalf("accepted host %q", host)
		}
		for _, r := range host {
			if host != "This Mac" && (r <= ' ' || r >= 0x7f || r == ';' || r == '/' || r == '$') {
				t.Fatalf("accepted host %q", host)
			}
		}
		want := map[string]string{"instance": instance, "requestID": requestID, "targetPaneID": target, "host": host}
		if len(*paths) != 1 || (*paths)[0] != "/api/workspace/new-stacked-pane" || !reflect.DeepEqual((*bodies)[0], want) {
			t.Fatalf("forwarded %v %v", *paths, *bodies)
		}
	})
}
