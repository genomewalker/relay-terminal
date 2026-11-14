package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type showCapture struct {
	path, method string
	body         []byte
}

func (c *showCapture) RoundTrip(r *http.Request) (*http.Response, error) {
	c.path, c.method = r.URL.Path, r.Method
	if r.Body != nil {
		c.body, _ = io.ReadAll(r.Body)
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"status":"shown"}`)), Header: http.Header{}}, nil
}

func TestRelayShowRoutesBoundedItems(t *testing.T) {
	call := func(args map[string]any) (*showCapture, int) {
		c := &showCapture{}
		s := &server{token: "t", endpoint: "http://relay.invalid", client: &http.Client{Transport: c}}
		params, _ := json.Marshal(map[string]any{"name": "relay_show", "arguments": args})
		_, code, _ := s.handle(request{Method: "tools/call", Params: params})
		return c, code
	}
	args := map[string]any{"instance": "11111111-1111-4111-8111-111111111111", "request_id": "22222222-2222-4222-8222-222222222222",
		"pane_id": "33333333-3333-4333-8333-333333333333", "items": []string{"~/run/plot.png", "https://example.org/x"}}
	c, code := call(args)
	if code != 0 || c.path != "/api/workspace/show" || c.method != "POST" {
		t.Fatalf("wrong route: %d %#v", code, c)
	}
	var body map[string]any
	_ = json.Unmarshal(c.body, &body)
	if body["paneID"] != args["pane_id"] || body["requestID"] != args["request_id"] || body["instance"] != args["instance"] ||
		len(body["items"].([]any)) != 2 || body["items"].([]any)[0] != "~/run/plot.png" {
		t.Fatalf("show target or items changed: %s", c.body)
	}
	many := make([]string, 17)
	for i := range many {
		many[i] = "/a"
	}
	for _, patch := range []map[string]any{{"items": []string{}}, {"items": many}, {"items": []string{"a\nb"}},
		{"items": []string{strings.Repeat("x", 2049)}}, {"items": "/one"}, {"pane_id": "nope"}, {"extra": true}} {
		changed := map[string]any{}
		for k, v := range args {
			changed[k] = v
		}
		for k, v := range patch {
			changed[k] = v
		}
		if c, code := call(changed); code == 0 || c.path != "" {
			t.Fatal("accepted invalid show request", patch)
		}
	}
}

func TestRelayShowIsAMutationOutsideMiko(t *testing.T) {
	if !mikoExcluded("relay_show") {
		t.Fatal("relay_show must stay out of Miko's catalog")
	}
}
