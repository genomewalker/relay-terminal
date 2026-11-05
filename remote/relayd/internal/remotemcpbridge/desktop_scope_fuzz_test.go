package remotemcpbridge

import (
	"bytes"
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

func FuzzDesktopScopeNeverForwards(f *testing.F) {
	f.Add(byte(0), []byte(`{}`), "caller_a")
	f.Add(byte(3), []byte(`{"sourcePaneID":"5a30d83a-5222-48f3-93c7-42fa687d901b"}`), "caller_b")
	f.Fuzz(func(t *testing.T, selector byte, raw []byte, caller string) {
		if len(raw) > 70000 || len(caller) > 256 {
			return
		}
		endpoints := []struct{ method, path string }{
			{"GET", "/api/network/desktop-tasks"}, {"GET", "/api/network/desktop-routes"},
			{"POST", "/api/network/desktop-route/request"}, {"POST", "/api/network/desktop-route/create"},
			{"GET", "/api/network/desktop-route/receipts/" + requestID},
			{"POST", "/api/network/desktop-route/message-receipt"}, {"POST", "/api/network/desktop-route/send"},
		}
		e := endpoints[int(selector)%len(endpoints)]
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
		r := httptest.NewRequest(e.method, e.path, bytes.NewReader(raw))
		r.Header.Set("x-relay-token", "fixture")
		r.Header.Set("X-Relay-Caller-Token", caller)
		status, _ := b.Handle(r)
		if status != 403 || forwarded != 0 || len(b.receipts) != 0 {
			t.Fatalf("desktop scope escaped status=%d forwarded=%d", status, forwarded)
		}
	})
}
