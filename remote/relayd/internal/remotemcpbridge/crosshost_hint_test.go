package remotemcpbridge

import (
	"strings"
	"testing"
)

// A remote pane whose relay-mcp started before relay_call_tool learned to go
// to relayd sends a reply to a linked desktop session through this bridge,
// which has no saved pane pair for it. On 2026-11-07 the reply from dandy-07
// pane 767dc718 to desktop session 7194df15 got a bare 403 and the agent had no
// way to know the direct tool works. The refusal stays a refusal, but it names
// the tool that does reach relayd.
func TestCrossHostRefusalNamesTheDirectTool(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	s, v := request(b, "POST", "/api/panes/"+macPane+"/message", map[string]any{"sourcePaneID": paneA}, "fixture", "caller_a")
	if s != 403 {
		t.Fatalf("unsaved cross-host message %d", s)
	}
	body, _ := v.(map[string]any)
	msg, _ := body["error"].(string)
	if !strings.Contains(msg, "explicitly saved pane pair") || !strings.Contains(msg, "call `relay_message_pane` directly, not through `relay_call_tool`") {
		t.Fatalf("refusal does not name the direct tool: %q", msg)
	}
	if m.paneLinks != 0 {
		t.Fatal("refusal created a link")
	}
}
