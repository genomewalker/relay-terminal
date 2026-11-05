package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRemoteInstallToolsPostOneExactProposal(t *testing.T) {
	id := "22222222-2222-4222-8222-222222222222"
	var bodies []map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/api/host/remote-install" || r.Header.Get("X-Relay-Token") != "secret" {
			t.Errorf("wrong remote install request: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			t.Error("unreadable body")
		}
		bodies = append(bodies, body)
		w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	call := func(name string, args map[string]any) int {
		params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return code
	}
	sha := "d94ca91731b69b4e1be9bd079e4e578a25ec9bd9588d0865c6a3f2508183d718"
	if code := call("relay_install_relayd", map[string]any{"host": "dandy-07", "request_id": id, "local_path": "/builds/relayd", "sha256": sha, "allow_shared_home": true}); code != 0 {
		t.Fatalf("install code %d", code)
	}
	if code := call("relay_upload_file", map[string]any{"host": "dandy-07", "request_id": id, "local_path": "/builds/a.txt", "remote_directory": "~/inbox"}); code != 0 {
		t.Fatalf("upload code %d", code)
	}
	if code := call("relay_rollback_relayd", map[string]any{"host": "dandy-07", "request_id": id, "install_id": "install-" + id}); code != 0 {
		t.Fatalf("rollback code %d", code)
	}
	if len(bodies) != 3 {
		t.Fatalf("posted %d proposals", len(bodies))
	}
	for index, action := range []string{"install", "upload", "rollback"} {
		if bodies[index]["action"] != action || bodies[index]["host"] != "dandy-07" || bodies[index]["request_id"] != id {
			t.Fatalf("proposal %d is %v", index, bodies[index])
		}
	}
	if bodies[0]["allow_shared_home"] != true || bodies[0]["sha256"] != sha || len(bodies[0]) != 6 {
		t.Fatalf("install proposal lost or added fields: %v", bodies[0])
	}
}

func TestRemoteInstallToolsRejectBeforePosting(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	id := "33333333-3333-4333-8333-333333333333"
	for _, args := range []map[string]any{
		{"host": "dandy-07", "request_id": "not-a-uuid", "local_path": "/a", "sha256": "x"},
		{"host": " dandy-07", "request_id": id, "local_path": "/a", "sha256": "x"},
		{"host": "", "request_id": id, "local_path": "/a", "sha256": "x"},
		{"host": "dandy-07", "request_id": id, "local_path": "/a", "sha256": "x", "remote_directory": "/tmp"},
		{"host": "dandy-07", "request_id": id, "local_path": "/a", "sha256": "x", "action": "rollback"},
	} {
		params, _ := json.Marshal(map[string]any{"name": "relay_install_relayd", "arguments": args})
		if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != -32602 {
			t.Fatalf("accepted %v with code %d", args, code)
		}
	}
	if hits != 0 {
		t.Fatalf("an invalid request reached Relay %d times", hits)
	}
}

func TestRemoteInstallReceiptIsReadOnlyAndExact(t *testing.T) {
	id := "44444444-4444-4444-8444-444444444444"
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "GET" || r.URL.Path != "/api/host/remote-install/"+id {
			t.Errorf("wrong receipt read: %s %s", r.Method, r.URL.Path)
		}
		w.Write([]byte(`{"status":"completed"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	params, _ := json.Marshal(map[string]any{"name": "relay_remote_install_receipt", "arguments": map[string]any{"request_id": id}})
	if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != 0 || hits != 1 {
		t.Fatalf("receipt code=%d hits=%d", code, hits)
	}
	listed, _, _ := s.handle(request{Method: "tools/list"})
	hints := map[string]map[string]any{}
	for _, item := range listed.(map[string]any)["tools"].([]any) {
		entry := item.(map[string]any)
		hints[entry["name"].(string)] = entry["annotations"].(map[string]any)
	}
	if hints["relay_remote_install_receipt"]["readOnlyHint"] != true {
		t.Fatal("receipt read is not read-only")
	}
	for _, name := range []string{"relay_upload_file", "relay_install_relayd", "relay_rollback_relayd"} {
		if hints[name]["destructiveHint"] != true {
			t.Fatalf("%s is not marked destructive", name)
		}
	}
}
