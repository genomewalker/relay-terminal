package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCodexConversationContext(t *testing.T) {
	const measurement = `{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999333},"last_token_usage":{"total_tokens":128,"input_tokens":121},"model_context_window":272000}}}` + "\n"
	const rateOnly = `{"type":"event_msg","payload":{"type":"token_count","info":null}}` + "\n"
	cases := []struct {
		name, tail  string
		partial     bool
		used, limit int64 // -1 means unknown.
	}{
		{"current, excluding cumulative and rate-only", measurement + rateOnly, false, 128, 272000},
		{"missing last", measurement + `{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":272000}}}` + "\n", false, -1, 272000},
		{"malformed latest", measurement + `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":true},"model_context_window":272000}}}` + "\n", false, -1, 272000},
		{"missing limit and valid zero", `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}}}}` + "\n", false, 0, -1},
		{"compacted", measurement + `{"type":"compacted","payload":{}}` + "\n", false, -1, -1},
		{"partial tail", measurement + `{"type":"event_msg","payload":{"type":"context_compacted"}}`, false, 128, 272000},
		{"partial first line", measurement, true, -1, -1},
	}
	value := func(n *int64) int64 {
		if n == nil {
			return -1
		}
		return *n
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := codexConversationContext([]byte(tc.tail), tc.partial)
			if value(got.Used) != tc.used || value(got.Limit) != tc.limit {
				t.Fatalf("got %d / %d, want %d / %d", value(got.Used), value(got.Limit), tc.used, tc.limit)
			}
		})
	}
}

func TestClaudeConversationContextSessionAndProcessBirth(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".local", "share", "relay", "claude-status")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	const status = `{"pane_id":"exact-pane","session_id":"exact-session","captured_at":"2026-11-20T12:00:00Z","context_usage":{"used_tokens":12634,"limit_tokens":1000000}}`
	path := filepath.Join(dir, "exact-pane.json")
	if err := os.WriteFile(path, []byte(status), 0600); err != nil {
		t.Fatal(err)
	}
	r := phReader{uid: os.Getuid()}
	r.privateFile = r.ownerPrivateFile
	capture, _ := time.Parse(time.RFC3339, "2026-11-20T12:00:00Z")
	now := capture.Add(time.Hour)
	exact := r.claudeConversationContext(home, "exact-pane", "exact-session", capture.Add(-time.Second), now)
	if exact.Used == nil || *exact.Used != 12634 || exact.Limit == nil || *exact.Limit != 1000000 {
		t.Fatalf("exact session unavailable after idle: %#v", exact)
	}
	for _, tc := range []struct {
		session string
		start   time.Time
	}{
		{"other-session", capture.Add(-time.Second)},
		{"exact-session", capture.Add(time.Second)},
	} {
		got := r.claudeConversationContext(home, "exact-pane", tc.session, tc.start, now)
		if got.Used != nil || got.Limit != nil {
			t.Fatalf("stale observation returned for %s, process born %s", tc.session, tc.start)
		}
	}
}
