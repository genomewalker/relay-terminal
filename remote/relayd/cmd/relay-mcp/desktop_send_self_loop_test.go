package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// relay_send_desktop_message carries a Codex thread's message to the route's
// Claude owner. The owner calling it got its own message back (bc08, route
// c69609, 0.5.25 XL test). Only that exact owner incarnation is refused; Codex
// senders (desktop app or terminal pane) and other callers still send.
func TestSendDesktopMessageRefusesOnlyTheRoutesOwnOwner(t *testing.T) {
	const start = "Sun Nov  8 00:06:40 2026"
	codexDesktop := []processIdentity{{34506, "Sat Nov 7 12:00:00 2026"}, {34056, "Sat Nov 7 11:59:00 2026"}}
	codexPane := []processIdentity{{44086, "Sat Nov 7 13:00:00 2026"}, {43555, "Sat Nov 7 12:59:00 2026"}, {43553, "Sat Nov 7 12:58:00 2026"}}
	owner := []processIdentity{{30989, "Sun Nov 8 00:06:40 2026"}, {54027, "Sat Nov 7 10:00:00 2026"}}
	reusedPID := []processIdentity{{30989, "Sun Nov 8 09:00:00 2026"}}
	for _, c := range []struct {
		name  string
		host  string
		chain []processIdentity
		sent  bool
	}{
		{"codex_desktop_sends", "laptop", codexDesktop, true},
		{"codex_pane_sends", "laptop", codexPane, true},
		{"route_owner_refused", "laptop", owner, false},
		{"reused_pid_sends", "laptop", reusedPID, true},
		{"remote_host_pid_not_compared", "dandy-07", owner, true},
		{"unreadable_chain_sends", "laptop", nil, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			saved := desktopSendAncestors
			desktopSendAncestors = func() []processIdentity { return c.chain }
			defer func() { desktopSendAncestors = saved }()
			sent := false
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				sent = true
				w.Write([]byte(`{"id":"message-1","status":"written_to_socket","updatedAt":1}`))
			}))
			defer ts.Close()
			s := server{token: "test", endpoint: ts.URL, client: ts.Client()}
			id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
			remoteStart := start
			if c.host != "laptop" {
				remoteStart = "123456"
			}
			args := map[string]any{"reply_name": "relay-test", "thread": id, "host": c.host, "remote_session": id, "remote_pid": 30989, "remote_start": remoteStart, "message_id": "message-1", "content": "Hello"}
			params, _ := json.Marshal(map[string]any{"name": "relay_send_desktop_message", "arguments": args})
			_, code, message := s.handle(request{Method: "tools/call", Params: params})
			if sent != c.sent {
				t.Fatalf("sent=%v want %v (code=%d %q)", sent, c.sent, code, message)
			}
			if !c.sent && (code != -32602 || !strings.Contains(message, "SendMessage") || !strings.Contains(message, "peer.sock")) {
				t.Fatalf("refusal does not name the reply path: code=%d %q", code, message)
			}
		})
	}
}

// The real ancestry reader sees this test process's parent with its start.
func TestDesktopSendAncestorsReadsTheLiveChain(t *testing.T) {
	chain := desktopSendAncestors()
	if len(chain) == 0 || chain[0].pid != os.Getppid() || chain[0].start == "" {
		t.Fatalf("ancestry = %+v, parent %d", chain, os.Getppid())
	}
}
