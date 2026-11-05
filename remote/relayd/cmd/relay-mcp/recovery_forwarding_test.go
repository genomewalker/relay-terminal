package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRecoveryForwardsExactRequestAndOutcomes(t *testing.T) {
	const instance = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	const requestID = "11111111-2222-3333-4444-555555555555"
	const pane = "99999999-8888-7777-6666-555555555555"
	hits := 0
	serverHTTP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != http.MethodPost || r.URL.Path != "/api/recovery/attach" || r.Header.Get("x-relay-token") != "test" {
			t.Errorf("incorrect recovery route, method, or token")
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if len(body) != 4 || body["instance"] != instance || body["requestID"] != requestID || body["paneID"] != pane || body["host"] != "fixture-host" {
			t.Errorf("incorrect forwarded identity: %v", body)
		}
		switch hits {
		case 1:
			fmt.Fprint(w, `{"status":"pending"}`)
		case 2:
			fmt.Fprint(w, `{"status":"attached","paneID":"`+pane+`"}`)
		default:
			http.Error(w, "Conflicting recovery request ID", http.StatusConflict)
		}
	}))
	defer serverHTTP.Close()
	s := server{token: "test", endpoint: serverHTTP.URL, client: serverHTTP.Client()}
	args := map[string]any{"instance": instance, "request_id": requestID, "pane_id": pane, "host": "fixture-host"}
	params, err := json.Marshal(map[string]any{"name": "relay_recover_pane", "arguments": args})
	if err != nil {
		t.Fatal(err)
	}
	for i, expected := range []string{"pending", "attached", "Conflicting recovery request ID"} {
		result, code, message := s.handle(request{Method: "tools/call", Params: params})
		encoded, err := json.Marshal(result)
		if err != nil || code != 0 || hits != i+1 || !strings.Contains(string(encoded), expected) {
			t.Fatalf("call %d: result=%s code=%d message=%q hits=%d error=%v", i, encoded, code, message, hits, err)
		}
		m := result.(map[string]any)
		if m["isError"] != (i == 2) {
			t.Fatalf("call %d: wrong error status %v", i, m["isError"])
		}
	}
	args["pane_id"] = "not-a-uuid"
	params, _ = json.Marshal(map[string]any{"name": "relay_recover_pane", "arguments": args})
	_, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 || hits != 3 {
		t.Fatalf("invalid target forwarded: code=%d hits=%d", code, hits)
	}
}
