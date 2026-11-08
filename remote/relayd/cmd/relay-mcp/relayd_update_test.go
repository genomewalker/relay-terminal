package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

func TestUpdateHostRelaydIsAnExactChangeTool(t *testing.T) {
	listed, _, _ := (&server{}).handle(request{Method: "tools/list"})
	var entry map[string]any
	for _, item := range listed.(map[string]any)["tools"].([]any) {
		if x := item.(map[string]any); x["name"] == "relay_update_host_relayd" {
			entry = x
		}
	}
	if entry == nil {
		t.Fatal("relay_update_host_relayd is not offered")
	}
	schema := entry["inputSchema"].(map[string]any)
	properties := schema["properties"].(map[string]any)
	if _, ok := properties["host"]; !ok {
		t.Fatal("host missing")
	}
	if _, ok := properties["request_id"]; !ok {
		t.Fatal("request_id missing")
	}
	if len(properties) != 3 { // host, request_id, caller_token
		t.Fatalf("unexpected fields %v", properties)
	}
	if !reflect.DeepEqual(schema["required"], []string{"host", "request_id"}) || schema["additionalProperties"] != false {
		t.Fatalf("schema %v", schema)
	}
	if entry["annotations"].(map[string]any)["readOnlyHint"] != false {
		t.Fatal("update is marked read-only")
	}
	found := false
	for _, x := range mikoCatalog() {
		if x["name"] == "relay_update_host_relayd" {
			found = true
			if x["tier"] != "change" {
				t.Fatalf("Miko tier %v", x["tier"])
			}
		}
	}
	if !found {
		t.Fatal("Miko catalog lacks relay_update_host_relayd")
	}
}

func TestUpdateHostRelaydPostsOneExactRequest(t *testing.T) {
	id := "55555555-5555-4555-8555-555555555555"
	var bodies []map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/api/host/relayd-update" || r.Header.Get("X-Relay-Token") != "secret" {
			t.Errorf("wrong update request: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			t.Error("unreadable body")
		}
		bodies = append(bodies, body)
		w.Write([]byte(`{"status":"in_progress"}`))
	}))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	params, _ := json.Marshal(map[string]any{"name": "relay_update_host_relayd", "arguments": map[string]any{"host": "dandy-07", "request_id": id}})
	if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != 0 {
		t.Fatalf("update code %d", code)
	}
	if len(bodies) != 1 || !reflect.DeepEqual(bodies[0], map[string]any{"host": "dandy-07", "request_id": id}) {
		t.Fatalf("posted %v", bodies)
	}
}

func TestUpdateHostRelaydRejectsBeforePosting(t *testing.T) {
	hits := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer ts.Close()
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	id := "66666666-6666-4666-8666-666666666666"
	for _, args := range []map[string]any{
		{"host": "dandy-07", "request_id": "not-a-uuid"},
		{"host": " dandy-07", "request_id": id},
		{"host": "", "request_id": id},
		{"host": "dandy-07"},
		{"request_id": id},
		{"host": "dandy-07", "request_id": id, "local_path": "/a"},
		{"host": 7, "request_id": id},
	} {
		params, _ := json.Marshal(map[string]any{"name": "relay_update_host_relayd", "arguments": args})
		if _, code, _ := s.handle(request{Method: "tools/call", Params: params}); code != -32602 {
			t.Fatalf("accepted %v with code %d", args, code)
		}
	}
	if hits != 0 {
		t.Fatalf("an invalid request reached Relay %d times", hits)
	}
}
