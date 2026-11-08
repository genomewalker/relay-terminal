package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"slices"
	"strings"
	"testing"
)

var uuidV4 = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// messageIDServer records the messageID each send reached the app with.
func messageIDServer(t *testing.T, path string) (*server, *[]string, func()) {
	t.Helper()
	var seen []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != path {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		id, _ := body["messageID"].(string)
		seen = append(seen, id)
		w.Write([]byte(`{"id":"` + id + `","status":"written_to_socket","updatedAt":1}`))
	}))
	return &server{token: "test", endpoint: ts.URL, client: ts.Client()}, &seen, ts.Close
}

func encodedText(t *testing.T, result any) string {
	t.Helper()
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func generatedID(t *testing.T, result any) string {
	t.Helper()
	value, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("result is not an object: %T", result)
	}
	id, _ := value["message_id"].(string)
	return id
}

func TestMessagePaneGeneratesAMessageIDWhenOmitted(t *testing.T) {
	s, seen, done := messageIDServer(t, "/api/panes/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/message")
	defer done()
	call := func(args map[string]any) (any, int) {
		params, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": args})
		result, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return result, code
	}
	base := func() map[string]any {
		return map[string]any{"source_pane_id": "11111111-2222-3333-4444-555555555555", "pane_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "text": "hello"}
	}
	first, code := call(base())
	if code != 0 || len(*seen) != 1 {
		t.Fatalf("omitted id refused: code=%d seen=%v", code, *seen)
	}
	id := generatedID(t, first)
	if !uuidV4.MatchString(id) || (*seen)[0] != id {
		t.Fatalf("generated id %q not a UUIDv4 sent as %q", id, (*seen)[0])
	}
	if text := encodedText(t, first); !strings.Contains(text, "relay_pane_message_receipt") {
		t.Fatalf("result does not say how to read the receipt: %s", text)
	}
	second, code := call(base())
	if code != 0 || generatedID(t, second) == id || !uuidV4.MatchString(generatedID(t, second)) {
		t.Fatalf("second generated id not fresh: %q vs %q", generatedID(t, second), id)
	}
	// A supplied ID is sent unchanged and nothing is generated.
	supplied := base()
	supplied["message_id"] = "5e0b6a12-3c4d-4e8f-9a1b-2c3d4e5f6071"
	result, code := call(supplied)
	if code != 0 || (*seen)[2] != "5e0b6a12-3c4d-4e8f-9a1b-2c3d4e5f6071" || generatedID(t, result) != "" {
		t.Fatalf("supplied id changed: code=%d seen=%v result=%v", code, *seen, result)
	}
	// An invalid supplied ID is still refused before any send.
	for _, bad := range []any{"not-a-uuid", "", 7} {
		args := base()
		args["message_id"] = bad
		if _, code := call(args); code != -32602 || len(*seen) != 3 {
			t.Fatalf("invalid id %v accepted: code=%d", bad, code)
		}
	}
}

func TestDesktopMessageGeneratesAMessageIDWhenOmitted(t *testing.T) {
	s, seen, done := messageIDServer(t, "/api/network/desktop-route/send")
	defer done()
	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	base := func() map[string]any {
		return map[string]any{"reply_name": "relay-test", "thread": id, "host": "dandy-07", "remote_session": id, "remote_pid": 1234, "remote_start": "123456", "content": "Hello"}
	}
	call := func(args map[string]any) (any, int) {
		params, _ := json.Marshal(map[string]any{"name": "relay_send_desktop_message", "arguments": args})
		result, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return result, code
	}
	first, code := call(base())
	generated := generatedID(t, first)
	if code != 0 || !uuidV4.MatchString(generated) || len(*seen) != 1 || (*seen)[0] != generated {
		t.Fatalf("omitted id: code=%d generated=%q seen=%v", code, generated, *seen)
	}
	if text := encodedText(t, first); !strings.Contains(text, "relay_message_read_receipt") {
		t.Fatalf("result does not say how to read the receipt: %s", text)
	}
	second, _ := call(base())
	if generatedID(t, second) == generated {
		t.Fatal("generated id repeated")
	}
	supplied := base()
	supplied["message_id"] = "message-1"
	if result, code := call(supplied); code != 0 || (*seen)[2] != "message-1" || generatedID(t, result) != "" {
		t.Fatalf("supplied id changed: code=%d seen=%v", code, *seen)
	}
	supplied["message_id"] = "bad id with spaces"
	if _, code := call(supplied); code != -32602 || len(*seen) != 3 {
		t.Fatalf("invalid id accepted: %d", code)
	}
}

func TestSendToolSchemasMakeMessageIDOptional(t *testing.T) {
	s := server{}
	listed, code, _ := s.handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatal(code)
	}
	found := 0
	for _, item := range listed.(map[string]any)["tools"].([]any) {
		entry := item.(map[string]any)
		name := entry["name"].(string)
		if name != "relay_message_pane" && name != "relay_send_desktop_message" {
			continue
		}
		found++
		schema := entry["inputSchema"].(map[string]any)
		required, _ := schema["required"].([]string)
		if slices.Contains(required, "message_id") {
			t.Fatalf("%s still requires message_id", name)
		}
		if _, ok := schema["properties"].(map[string]any)["message_id"]; !ok {
			t.Fatalf("%s lost its message_id property", name)
		}
		if !strings.Contains(encodedText(t, entry), "omit to let Relay generate one; reuse only to retry the same message") {
			t.Fatalf("%s description does not explain the optional message_id", name)
		}
	}
	if found != 2 {
		t.Fatalf("found %d send tools", found)
	}
}
