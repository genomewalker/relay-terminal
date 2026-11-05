package remotemcpbridge

import (
	"context"
	"strings"
	"testing"
)

// The current host-wide bridge has no authenticated per-request pane or
// desktop pair grant. Until a real broker exists, none of these paths may
// reach the desktop, regardless of a claimed source or caller label.
func TestDesktopRoutesRequireMissingScopedBroker(t *testing.T) {
	endpoints := []struct{ method, path string }{
		{"GET", "/api/network/desktop-tasks"}, {"GET", "/api/network/desktop-routes"},
		{"POST", "/api/network/desktop-route/request"}, {"POST", "/api/network/desktop-route/create"},
		{"GET", "/api/network/desktop-route/receipts/" + requestID},
		{"POST", "/api/network/desktop-route/message-receipt"}, {"POST", "/api/network/desktop-route/send"},
	}
	count := 0
	for _, e := range endpoints {
		for _, caller := range []string{"caller_a", "caller_b"} {
			for _, source := range []string{sourcePane, foreignPane} {
				forwarded := 0
				b := New("dandy-07", "fixture", func(_ context.Context, method, path string, _ []byte, _ string) (int, []byte, error) {
					if path == "/api/state" {
						return 200, encode(baseState()), nil
					}
					if strings.HasPrefix(path, "/api/network/desktop") {
						forwarded++
					}
					return 200, []byte(`{"status":"fixture"}`), nil
				})
				payload := map[string]any{"sourcePaneID": source, "paneID": source, "requestID": requestID, "thread": "claimed-thread"}
				status, _ := request(b, e.method, e.path, payload, "fixture", caller)
				if status != 403 || forwarded != 0 || len(b.receipts) != 0 {
					t.Fatalf("%s %s caller=%s source=%s status=%d forwarded=%d", e.method, e.path, caller, source, status, forwarded)
				}
				count++
			}
		}
	}
	if count != 28 {
		t.Fatalf("unexpected bounded case count %d", count)
	}
	t.Logf("real Bridge.Handle: 7 endpoints x 2 caller labels x 2 claimed panes = %d cases; no desktop forward", count)
}
