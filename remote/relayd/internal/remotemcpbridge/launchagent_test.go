package remotemcpbridge

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
)

// 2026-11-19: dandy-07 agents could not use relay_launch_agent at all; the
// bridge denied it. It now passes, scoped like the other workspace writes:
// the request runs on this bridge's host, the calling pane is on that host
// in a tab wholly on it, and any placement stays in the caller's session.
const (
	laCaller  = "c0000000-0000-4000-8000-000000000001"
	laSibling = "c0000000-0000-4000-8000-000000000002"
	laOther   = "c0000000-0000-4000-8000-000000000003" // dandy-07, other session
	laMixed   = "c0000000-0000-4000-8000-000000000004" // dandy-07 pane in a mixed tab
	laMac     = "c0000000-0000-4000-8000-000000000005"
)

func laBridge(forwarded *[]fwd) *Bridge {
	pane := func(id, host string) map[string]any { return map[string]any{"id": id, "host": host, "contentKind": "terminal"} }
	state := map[string]any{"sessions": []any{
		map[string]any{"id": "S1", "tabs": []any{
			map[string]any{"id": "T1", "panes": []any{pane(laCaller, "dandy-07")}},
			map[string]any{"id": "T2", "panes": []any{pane(laSibling, "dandy-07")}},
			map[string]any{"id": "TM", "panes": []any{pane(laMixed, "dandy-07"), pane(laMac, "This Mac")}},
		}},
		map[string]any{"id": "S2", "tabs": []any{
			map[string]any{"id": "T3", "panes": []any{pane(laOther, "dandy-07")}},
		}},
	}}
	return New("dandy-07", "fixture", func(_ context.Context, m, p string, raw []byte, _ string) (int, []byte, error) {
		if p == "/api/state" {
			return 200, encode(state), nil
		}
		if m == "POST" {
			*forwarded = append(*forwarded, fwd{m, p, raw})
		}
		return 200, []byte(`{"status":"ok"}`), nil
	})
}

func laBody(host string, extra map[string]string) string {
	body := map[string]string{"instance": wsInstance, "requestID": wsReq, "host": host, "cwd": "/home/u/p",
		"provider": "codex", "model": "gpt-6", "account": "business", "briefPath": "/home/u/brief.md"}
	for k, v := range extra {
		body[k] = v
	}
	raw, _ := json.Marshal(body)
	return string(raw)
}

func TestLaunchAgentPassesWithinTheCallersOwnScope(t *testing.T) {
	cases := map[string]map[string]string{
		"beside the caller":          {"callerPaneID": laCaller},
		"anchored on a sibling tab":  {"callerPaneID": laCaller, "anchorTabID": "T2"},
		"anchored on a sibling pane": {"callerPaneID": laCaller, "anchorPaneID": laSibling},
		"stacked on the caller":      {"callerPaneID": laCaller, "targetPaneID": laCaller},
	}
	for name, extra := range cases {
		var got []fwd
		b := laBridge(&got)
		if s, out := post(b, "/api/workspace/launch-agent", laBody("dandy-07", extra)); s != 200 {
			t.Fatalf("%s: status %d %s", name, s, out)
		}
		if len(got) != 1 || got[0].path != "/api/workspace/launch-agent" {
			t.Fatalf("%s: forwarded %+v", name, got)
		}
		var sent map[string]any
		if json.Unmarshal(got[0].body, &sent) != nil || fmt.Sprint(sent["bridgeScope"]) != "map[host:dandy-07]" ||
			sent["callerPaneID"] != laCaller || sent["host"] != "dandy-07" {
			t.Fatalf("%s: forwarded body %s", name, got[0].body)
		}
	}
}

func TestLaunchAgentOutsideTheCallersScopeIsDenied(t *testing.T) {
	cases := map[string]string{
		"no caller pane":              laBody("dandy-07", nil),
		"caller on the Mac":           laBody("dandy-07", map[string]string{"callerPaneID": laMac}),
		"caller in a mixed tab":       laBody("dandy-07", map[string]string{"callerPaneID": laMixed}),
		"caller not a pane":           laBody("dandy-07", map[string]string{"callerPaneID": "c0000000-0000-4000-8000-0000000000ff"}),
		"launch on the Mac":           laBody("This Mac", map[string]string{"callerPaneID": laCaller}),
		"launch on another host":      laBody("dandy-08", map[string]string{"callerPaneID": laCaller}),
		"anchor in another session":   laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "anchorPaneID": laOther}),
		"anchor tab in other session": laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "anchorTabID": "T3"}),
		"anchor on a mixed tab":       laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "anchorTabID": "TM"}),
		"stack onto a Mac pane":       laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "targetPaneID": laMac}),
		"client-set bridgeScope":      `{"instance":"` + wsInstance + `","requestID":"` + wsReq + `","host":"dandy-07","cwd":"/a","provider":"codex","model":"m","account":"a","briefPath":"/b","callerPaneID":"` + laCaller + `","bridgeScope":{"host":"dandy-07"}}`,
		"unknown key":                 laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "command": "rm -rf ~"}),
		"two placements":              laBody("dandy-07", map[string]string{"callerPaneID": laCaller, "anchorTabID": "T1", "targetPaneID": laCaller}),
	}
	for name, body := range cases {
		var got []fwd
		b := laBridge(&got)
		if s, _ := post(b, "/api/workspace/launch-agent", body); s == 200 || len(got) != 0 {
			t.Fatalf("%s: status %d forwarded %+v", name, s, got)
		}
	}
}
