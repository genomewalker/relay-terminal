package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPluginAndEditorReadOnlyRoutes(t *testing.T) {
	id := "11111111-1111-4111-8111-111111111111"
	path := ""
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.Header.Get("X-Relay-Token") != "secret" {
			t.Error("unsafe request")
		}
		path = r.URL.Path
		w.Write([]byte(`{}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	for _, tc := range []struct {
		name, want string
		args       map[string]string
	}{
		{"relay_list_plugins", "/api/plugins", map[string]string{}},
		{"relay_read_editor", "/api/panes/" + id + "/editor", map[string]string{"pane_id": id}},
	} {
		params, _ := json.Marshal(map[string]any{"name": tc.name, "arguments": tc.args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		if code != 0 || path != tc.want {
			t.Fatal(code, path)
		}
		tc.args["execute"] = "true"
		params, _ = json.Marshal(map[string]any{"name": tc.name, "arguments": tc.args})
		_, code, _ = s.handle(request{Method: "tools/call", Params: params})
		if code != -32602 {
			t.Fatal("accepted extra argument")
		}
	}
}
