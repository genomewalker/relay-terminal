package daemon

import (
	"encoding/json"
	"strings"
	"testing"
)

// Item 4 (0.5.113, pane 0173baf5): a Codex frontend bound directly to
// Codex's own app-server daemon, not through Relay's proxy, is refused by
// name for resume, restart and move instead of being relaunched.
func TestCodexOutsideProxyIsANamedRefusal(t *testing.T) {
	saved := codexOutsideProxy
	defer func() { codexOutsideProxy = saved }()
	pane := "0173baf5-977d-485c-af11-70e2f88632bc"

	codexOutsideProxy = func(got string) bool { return got == pane }
	refusal := codexManagedRouteRefusal(pane)
	if refusal == nil || refusal.Code != PaneRefusalOutsideProxy || refusal.HowToClear == "" ||
		!strings.Contains(refusal.Blocker, "outside Relay's proxy") {
		t.Fatalf("outside-proxy pane: %+v", refusal)
	}
	if code := classifyPaneRefusal(codexOutsideProxyMessage); code != PaneRefusalOutsideProxy {
		t.Fatalf("maintenance resume_error code = %q", code)
	}
	line := PaneRefusalLine(refusal)
	var decoded map[string]string
	if !strings.HasPrefix(line, "refusal: ") || json.Unmarshal([]byte(strings.TrimPrefix(line, "refusal: ")), &decoded) != nil ||
		decoded["reason_code"] != PaneRefusalOutsideProxy {
		t.Fatalf("refusal line: %q", line)
	}

	// A proxied or plain pane is not refused for this reason.
	codexOutsideProxy = func(string) bool { return false }
	if refusal := codexOutsideProxyRefusal(pane); refusal != nil {
		t.Fatalf("not outside proxy: %+v", refusal)
	}
}
