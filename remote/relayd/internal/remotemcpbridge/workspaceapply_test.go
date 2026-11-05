package remotemcpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	wsInstance = "11111111-2222-3333-4444-555555555555"
	wsReq      = "AAAAAAAA-aaaa-AAAA-aaaa-AAAAAAAAAAAA"
)

type fwd struct {
	method, path string
	body         []byte
}

// wsBridge serves a state with: tab "tab" (session "session", host dandy-07
// panes sourcePane+targetPane), tab "mixed" (dandy-07 + This Mac panes) and
// tab "mac" (This Mac only, foreignPane).
func wsBridge(forwarded *[]fwd) *Bridge {
	state := map[string]any{"sessions": []any{map[string]any{"id": "Session", "tabs": []any{
		map[string]any{"id": "Tab", "panes": []any{
			map[string]any{"id": sourcePane, "host": "dandy-07", "contentKind": "terminal"},
			map[string]any{"id": targetPane, "host": "dandy-07", "contentKind": "editor"}}},
		map[string]any{"id": "mixed", "panes": []any{
			map[string]any{"id": "bbbbbbbb-0000-0000-0000-000000000001", "host": "dandy-07", "contentKind": "terminal"},
			map[string]any{"id": "bbbbbbbb-0000-0000-0000-000000000002", "host": "This Mac", "contentKind": "terminal"}}},
		map[string]any{"id": "mac", "panes": []any{
			map[string]any{"id": foreignPane, "host": "This Mac", "contentKind": "terminal"}}},
	}}}, "selectedPaneID": sourcePane}
	return New("dandy-07", "fixture", func(_ context.Context, m, p string, raw []byte, _ string) (int, []byte, error) {
		if p == "/api/state" {
			return 200, encode(state), nil
		}
		if m == "POST" && p != "/api/workspace/context" {
			*forwarded = append(*forwarded, fwd{m, p, raw})
		}
		return 200, []byte(`{"status":"ok"}`), nil
	})
}
func post(b *Bridge, path, body string) (int, string) {
	r := httptest.NewRequest("POST", path, bytes.NewReader([]byte(body)))
	r.Header.Set("x-relay-token", "fixture")
	s, out := b.Handle(r)
	return s, string(out)
}
func applyBody(req, pane, action string, extra string) string {
	return fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"action":%q%s}`, wsInstance, req, pane, action, extra)
}

func TestWorkspaceApplyPositive(t *testing.T) {
	for _, action := range []string{"newTab", "splitRight", "splitDown"} {
		for _, host := range []string{"", `,"connectionHost":"dandy-07"`} {
			var got []fwd
			b := wsBridge(&got)
			status, _ := post(b, "/api/workspace/apply", applyBody(wsReq, strings.ToUpper(sourcePane), action, host))
			if status != 200 || len(got) != 1 || got[0].path != "/api/workspace/apply" {
				t.Fatalf("%s %q: status %d forwarded %d", action, host, status, len(got))
			}
			// bridgeScope is injected with exact lowercase values and the bridge host.
			want := fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"action":%q,"connectionHost":"dandy-07","bridgeScope":{"host":"dandy-07","tabID":"tab","sessionID":"session"}}`,
				wsInstance, strings.ToLower(wsReq), sourcePane, action)
			if string(got[0].body) != want {
				t.Fatalf("%s forwarded body\n got %s\nwant %s", action, got[0].body, want)
			}
		}
	}
}

func TestWorkspaceApplyDenials(t *testing.T) {
	good := func(extra string) string { return applyBody(wsReq, sourcePane, "newTab", extra) }
	cases := []struct {
		name, body string
		want       int
	}{
		{"pane on another host/tab", applyBody(wsReq, foreignPane, "newTab", ""), 403},
		{"pane in a mixed-host tab", applyBody(wsReq, "bbbbbbbb-0000-0000-0000-000000000001", "newTab", ""), 403},
		{"pane in no tab", applyBody(wsReq, "cccccccc-0000-0000-0000-000000000001", "newTab", ""), 403},
		{"connectionHost This Mac", good(`,"connectionHost":"This Mac"`), 403},
		{"connectionHost other alias", good(`,"connectionHost":"dandy-08"`), 403},
		{"duplicate key", good(`,"action":"newTab"`), 403},
		{"duplicate connectionHost", good(`,"connectionHost":"dandy-07","connectionHost":"dandy-07"`), 403},
		{"unknown key", good(`,"directory":"/tmp"`), 403},
		{"bridgeScope from caller", good(`,"bridgeScope":{"host":"dandy-07"}`), 403},
		{"non-string value", good(`,"connectionHost":null`), 403},
		{"nested value", good(`,"connectionHost":{"a":1}`), 403},
		{"unknown action", applyBody(wsReq, sourcePane, "closeTab", ""), 403},
		{"action case", applyBody(wsReq, sourcePane, "newtab", ""), 403},
		{"short uuid", applyBody("1234", sourcePane, "newTab", ""), 403},
		{"braced uuid", applyBody("{"+wsReq+"}", sourcePane, "newTab", ""), 403},
		{"uuid without dashes", applyBody("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", sourcePane, "newTab", ""), 403},
		{"missing pane", fmt.Sprintf(`{"instance":%q,"requestID":%q,"action":"newTab"}`, wsInstance, wsReq), 403},
		{"not json", `nope`, 400},
		{"array", `[]`, 400},
		{"trailing data", good("") + `{}`, 400},
		{"truncated", good("")[:20], 400},
		{"too large", good(`,"connectionHost":"` + strings.Repeat("x", 5000) + `"`), 413},
	}
	for _, c := range cases {
		var got []fwd
		b := wsBridge(&got)
		status, _ := post(b, "/api/workspace/apply", c.body)
		if status != c.want || len(got) != 0 || len(b.workspaceReqs) != 0 {
			t.Errorf("%s: status %d want %d, forwarded %d, fingerprints %d", c.name, status, c.want, len(got), len(b.workspaceReqs))
		}
	}
	var got []fwd
	b := wsBridge(&got)
	if s, _ := post(b, "/api/workspace/apply", ""); s != 413 || len(got) != 0 {
		t.Fatalf("empty body status %d", s)
	}
}

func TestWorkspaceApplyRequestIDIdempotencyAndConflict(t *testing.T) {
	var got []fwd
	b := wsBridge(&got)
	first := applyBody(wsReq, sourcePane, "splitRight", "")
	for i := 0; i < 2; i++ {
		if s, _ := post(b, "/api/workspace/apply", first); s != 200 {
			t.Fatalf("replay %d status %d", i, s)
		}
	}
	if len(got) != 2 || !bytes.Equal(got[0].body, got[1].body) || len(b.workspaceReqs) != 1 {
		t.Fatalf("identical replay must forward identical bodies: %d %d", len(got), len(b.workspaceReqs))
	}
	// Case differences in the UUIDs are the same content.
	if s, _ := post(b, "/api/workspace/apply", applyBody(strings.ToLower(wsReq), strings.ToUpper(sourcePane), "splitRight", "")); s != 200 || len(got) != 3 {
		t.Fatalf("case-insensitive replay status %d forwarded %d", s, len(got))
	}
	for name, body := range map[string]string{
		"action":   applyBody(wsReq, sourcePane, "splitDown", ""),
		"pane":     applyBody(wsReq, targetPane, "splitRight", ""),
		"instance": strings.Replace(first, "11111111", "99999999", 1),
	} {
		if s, _ := post(b, "/api/workspace/apply", body); s != 409 {
			t.Errorf("%s change: status %d want 409", name, s)
		}
	}
	if len(got) != 3 {
		t.Fatalf("conflicts must not reach the desktop, forwarded %d", len(got))
	}
}

func TestWorkspaceApplyFingerprintBound(t *testing.T) {
	var got []fwd
	b := wsBridge(&got)
	id := func(i int) string { return fmt.Sprintf("00000000-0000-0000-0000-%012x", i) }
	for i := 0; i < 512; i++ {
		if s, _ := post(b, "/api/workspace/apply", applyBody(id(i), sourcePane, "newTab", "")); s != 200 {
			t.Fatalf("request %d status %d", i, s)
		}
	}
	if len(b.workspaceReqs) != 512 || len(got) != 512 {
		t.Fatalf("fingerprints %d forwarded %d", len(b.workspaceReqs), len(got))
	}
	if s, _ := post(b, "/api/workspace/apply", applyBody(id(512), sourcePane, "newTab", "")); s != 429 || len(got) != 512 || len(b.workspaceReqs) != 512 {
		t.Fatalf("513th new ID: status %d forwarded %d fingerprints %d", s, len(got), len(b.workspaceReqs))
	}
	// At capacity an existing ID still replays, and a changed one still conflicts.
	if s, _ := post(b, "/api/workspace/apply", applyBody(id(7), sourcePane, "newTab", "")); s != 200 || len(got) != 513 {
		t.Fatalf("replay at capacity: status %d", s)
	}
	if s, _ := post(b, "/api/workspace/apply", applyBody(id(7), sourcePane, "splitDown", "")); s != 409 {
		t.Fatalf("conflict at capacity: status %d", s)
	}
	// A rejected request does not consume a slot.
	if s, _ := post(b, "/api/workspace/apply", applyBody(id(600), foreignPane, "newTab", "")); s != 403 || len(b.workspaceReqs) != 512 {
		t.Fatalf("denied request at capacity: %d", s)
	}
}

func stackBody(pane, target, extra string) string {
	return fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"targetPaneID":%q%s}`, wsInstance, wsReq, pane, target, extra)
}
func newStackedBody(target, host, extra string) string {
	return fmt.Sprintf(`{"instance":%q,"requestID":%q,"targetPaneID":%q,"host":%q%s}`, wsInstance, wsReq, target, host, extra)
}

func TestStackRoutesForwardWithInjectedHostScope(t *testing.T) {
	var got []fwd
	b := wsBridge(&got)
	if s, _ := post(b, "/api/workspace/stack-pane", stackBody(sourcePane, targetPane, "")); s != 200 {
		t.Fatalf("stack-pane status %d", s)
	}
	if s, _ := post(b, "/api/workspace/new-stacked-pane", newStackedBody(targetPane, "dandy-07", "")); s != 200 {
		t.Fatalf("new-stacked-pane status %d", s)
	}
	want := []string{
		fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"targetPaneID":%q,"bridgeScope":{"host":"dandy-07"}}`, wsInstance, wsReq, sourcePane, targetPane),
		fmt.Sprintf(`{"instance":%q,"requestID":%q,"targetPaneID":%q,"host":"dandy-07","bridgeScope":{"host":"dandy-07"}}`, wsInstance, wsReq, targetPane),
	}
	if len(got) != 2 || got[0].path != "/api/workspace/stack-pane" || got[1].path != "/api/workspace/new-stacked-pane" {
		t.Fatalf("forwarded %+v", got)
	}
	for i := range want {
		if string(got[i].body) != want[i] {
			t.Errorf("body %d\n got %s\nwant %s", i, got[i].body, want[i])
		}
	}
}

func TestStackRoutesDenials(t *testing.T) {
	scopes := []string{`,"bridgeScope":{"host":"dandy-07"}`, `,"bridgeScope":null`, `,"bridgeScope":{}`, `,"bridgeScope":""`, `,"bridgeScope":{"host":"This Mac"}`}
	type c struct {
		name, path, body string
		want             int
	}
	cases := []c{
		{"stack: target on another host", "/api/workspace/stack-pane", stackBody(sourcePane, foreignPane, ""), 403},
		{"stack: moving pane on another host", "/api/workspace/stack-pane", stackBody(foreignPane, sourcePane, ""), 403},
		{"stack: both on another host", "/api/workspace/stack-pane", stackBody(foreignPane, foreignPane, ""), 403},
		{"stack: unknown pane", "/api/workspace/stack-pane", stackBody(sourcePane, "cccccccc-0000-0000-0000-000000000001", ""), 403},
		{"stack: duplicate key", "/api/workspace/stack-pane", stackBody(sourcePane, targetPane, `,"paneID":"`+sourcePane+`"`), 403},
		{"stack: unknown key", "/api/workspace/stack-pane", stackBody(sourcePane, targetPane, `,"host":"dandy-07"`), 403},
		{"stack: missing key", "/api/workspace/stack-pane", fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"x":"y"}`, wsInstance, wsReq, sourcePane), 403},
		{"stack: bad uuid", "/api/workspace/stack-pane", stackBody("nope", targetPane, ""), 403},
		{"stack: non-string", "/api/workspace/stack-pane", strings.Replace(stackBody(sourcePane, targetPane, ""), `"`+targetPane+`"`, `5`, 1), 403},
		{"stack: malformed", "/api/workspace/stack-pane", `{`, 400},
		{"stack: array", "/api/workspace/stack-pane", `[]`, 400},
		{"new: target on another host", "/api/workspace/new-stacked-pane", newStackedBody(foreignPane, "dandy-07", ""), 403},
		{"new: host This Mac", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "This Mac", ""), 403},
		{"new: other alias", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "dandy-08", ""), 403},
		{"new: host case", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "Dandy-07", ""), 403},
		{"new: empty host", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "", ""), 403},
		{"new: duplicate host", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "dandy-07", `,"host":"dandy-07"`), 403},
		{"new: unknown key", "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "dandy-07", `,"paneID":"`+sourcePane+`"`), 403},
		{"new: malformed", "/api/workspace/new-stacked-pane", `nope`, 400},
	}
	// A caller-supplied bridgeScope in any form is refused outright (400).
	for _, s := range scopes {
		cases = append(cases,
			c{"stack: forged bridgeScope " + s, "/api/workspace/stack-pane", stackBody(sourcePane, targetPane, s), 400},
			c{"new: forged bridgeScope " + s, "/api/workspace/new-stacked-pane", newStackedBody(sourcePane, "dandy-07", s), 400},
			c{"stack: forged bridgeScope on foreign pane " + s, "/api/workspace/stack-pane", stackBody(foreignPane, targetPane, s), 400})
	}
	for _, tc := range cases {
		var got []fwd
		b := wsBridge(&got)
		if s, _ := post(b, tc.path, tc.body); s != tc.want || len(got) != 0 {
			t.Errorf("%s: status %d want %d forwarded %d", tc.name, s, tc.want, len(got))
		}
	}
	// Whole-tab host purity for the stack routes is the desktop fence's job
	// (the bridge only checks each named pane's host); a host-A pane in a mixed
	// tab is forwarded with the host scope so the desktop can refuse it.
	var mixed []fwd
	if s, _ := post(wsBridge(&mixed), "/api/workspace/new-stacked-pane", newStackedBody("bbbbbbbb-0000-0000-0000-000000000001", "dandy-07", "")); s != 200 || len(mixed) != 1 {
		t.Fatalf("mixed-tab host-A pane: status %d forwarded %d", s, len(mixed))
	}
	// Valid payloads are untouched by the denials above.
	var raw []fwd
	b := wsBridge(&raw)
	if s, _ := post(b, "/api/workspace/stack-pane", stackBody(sourcePane, targetPane, "")); s != 200 || len(raw) != 1 {
		t.Fatalf("control case status %d", s)
	}
	var decoded map[string]any
	if json.Unmarshal(raw[0].body, &decoded) != nil || len(decoded) != 5 {
		t.Fatalf("forwarded body keys: %s", raw[0].body)
	}
}
