package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"regexp"
	"testing"
)

// The tool schemas' UUID form, written here independently of main.go's
// paneID pattern so the oracle cannot drift with production.
var fuzzSchemaUUID = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// fuzzSpecBody returns the body Relay must receive for these arguments, or
// false when the specification requires refusal before any HTTP request.
// Every key must be known, every value a JSON string, and the result has
// exactly the required keys plus the optional ones the tool allows.
func fuzzSpecBody(args map[string]json.RawMessage, keys map[string]string, required []string) (map[string]string, bool) {
	body := map[string]string{}
	for key, raw := range args {
		field, known := keys[key]
		var value string
		if !known || json.Unmarshal(raw, &value) != nil {
			return nil, false
		}
		body[field] = value
	}
	for _, field := range required {
		if _, present := body[field]; !present {
			return nil, false
		}
	}
	return body, true
}

// relay_new_local_tab: instance and request_id, plus at most one anchor
// (pane XOR tab, or none for today's default). All four are exact UUIDs.
func fuzzNewLocalTabSpec(args map[string]json.RawMessage) (map[string]string, bool) {
	body, ok := fuzzSpecBody(args, map[string]string{"instance": "instance", "request_id": "requestID",
		"anchor_pane_id": "anchorPaneID", "anchor_tab_id": "anchorTabID"}, []string{"instance", "requestID"})
	if !ok {
		return nil, false
	}
	_, pane := body["anchorPaneID"]
	_, tab := body["anchorTabID"]
	if pane && tab {
		return nil, false
	}
	for _, value := range body {
		if !fuzzSchemaUUID.MatchString(value) {
			return nil, false
		}
	}
	return body, true
}

// relay_tab_action move: exactly the six move keys, four exact UUIDs and a
// before/after placement.
func fuzzTabMoveSpec(args map[string]json.RawMessage) (map[string]string, bool) {
	body, ok := fuzzSpecBody(args, map[string]string{"instance": "instance", "request_id": "requestID", "tab_id": "tabID",
		"action": "action", "target_tab_id": "targetTabID", "placement": "placement"},
		[]string{"instance", "requestID", "tabID", "action", "targetTabID", "placement"})
	if !ok || body["action"] != "move" || (body["placement"] != "before" && body["placement"] != "after") {
		return nil, false
	}
	for _, field := range []string{"instance", "requestID", "tabID", "targetTabID"} {
		if !fuzzSchemaUUID.MatchString(body[field]) {
			return nil, false
		}
	}
	return body, true
}

// FuzzTabAnchorAndMoveArguments drives the real tools/call handler with
// arbitrary argument objects for relay_new_local_tab and relay_tab_action.
// Properties, beyond "no panic":
//   - accepted exactly when the specification above accepts;
//   - an accepted call sends exactly one request, to the tool's path, whose
//     body is a string-only JSON object equal to the specified fields (round
//     trip: every forwarded value is the caller's exact string);
//   - a refused call sends nothing.
//
// For relay_tab_action only "move" is specified here; other actions are run
// for panics only.
func FuzzTabAnchorAndMoveArguments(f *testing.F) {
	const a = "11111111-1111-4111-8111-111111111111"
	const b = "22222222-2222-4222-8222-222222222222"
	for _, seed := range []struct {
		move bool
		args string
	}{
		{false, `{"instance":"` + a + `","request_id":"` + a + `"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_pane_id":"` + b + `"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"` + b + `"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_pane_id":"` + b + `","anchor_tab_id":"` + b + `"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"../../../../../../../../../etc/passwd"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"` + b + `\n"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"2` + b[1:] + `"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":` + `1}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":null}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor_tab_id":"` + b + `","anchor_tab_id":"x"}`},
		{false, `{"instance":"` + a + `","request_id":"` + a + `","anchor":"` + b + `"}`},
		{false, `{"instance":"` + a + `","anchor_tab_id":"` + b + `"}`},
		{false, `null`},
		{false, `[]`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"move","target_tab_id":"` + b + `","placement":"after"}`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"move","target_tab_id":"` + b + `","placement":"before"}`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"move","target_tab_id":"` + b + `","placement":"beside"}`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"move","target_tab_id":"zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz","placement":"after"}`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"move","placement":"after","name":"x"}`},
		{true, `{"instance":"` + a + `","request_id":"` + a + `","tab_id":"` + a + `","action":"close"}`},
	} {
		f.Add(seed.move, []byte(seed.args))
	}

	var paths []string
	var bodies [][]byte
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		paths, bodies = append(paths, r.URL.Path), append(bodies, raw)
		w.Write([]byte(`{"status":"applied"}`))
	}))
	f.Cleanup(ts.Close)
	s := server{token: "secret", client: ts.Client(), endpoint: ts.URL}

	f.Fuzz(func(t *testing.T, move bool, raw []byte) {
		name, path, spec := "relay_new_local_tab", "/api/workspace/new-local-tab", fuzzNewLocalTabSpec
		if move {
			name, path, spec = "relay_tab_action", "/api/workspace/tab-action", fuzzTabMoveSpec
		}
		params, err := json.Marshal(map[string]any{"name": name, "arguments": json.RawMessage(raw)})
		if err != nil {
			return // Not one JSON value; no tools/call can carry it.
		}
		var args map[string]json.RawMessage
		decoded := json.Unmarshal(raw, &args) == nil
		var action string
		if move && decoded {
			_ = json.Unmarshal(args["action"], &action)
		}
		before := len(paths)
		_, code, message := s.handle(request{Method: "tools/call", Params: params})
		sent := len(paths) - before
		if move && action != "move" {
			return // Other tab actions are not specified by this target.
		}
		want, accept := map[string]string(nil), false
		if decoded {
			want, accept = spec(args)
		}
		if !accept {
			if code == 0 || sent != 0 {
				t.Fatalf("%s accepted %s (code %d, %d requests sent)", name, raw, code, sent)
			}
			return
		}
		if code != 0 || sent != 1 {
			t.Fatalf("%s refused valid %s: %d %q (%d requests sent)", name, raw, code, message, sent)
		}
		var got map[string]string
		if paths[len(paths)-1] != path || json.Unmarshal(bodies[len(bodies)-1], &got) != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("%s %s forwarded %s %s, want %s %v", name, raw, paths[len(paths)-1], bodies[len(bodies)-1], path, want)
		}
	})
}
