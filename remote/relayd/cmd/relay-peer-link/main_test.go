package main

import (
	"encoding/json"
	"github.com/relay-terminal/relayd/internal/peernet"
	"os"
	"testing"
	"time"
)

func TestBackoff(t *testing.T) {
	for i, want := range []time.Duration{1, 2, 4, 8, 16, 30, 30} {
		if got := retryDelay(i); got != want*time.Second {
			t.Fatalf("attempt %d: %s", i, got)
		}
	}
}
func TestStatus(t *testing.T) {
	s, e := newStatus(t.TempDir(), "host", "local", "session-a", "remote", "session-b")
	if e != nil {
		t.Fatal(e)
	}
	s.set("connecting", "", 1)
	s.observe(peernet.Event{State: "online", MessageID: "msg-1", Receipt: "socket-written", RTTMillis: 12})
	b, e := os.ReadFile(s.path)
	if e != nil {
		t.Fatal(e)
	}
	var got statusFile
	if e = json.Unmarshal(b, &got); e != nil {
		t.Fatal(e)
	}
	if got.State != "online" || got.LastReceipt != "socket-written" || got.LocalSession != "session-a" || got.Attempt != 1 || got.RTTMillis != 12 {
		t.Fatalf("bad snapshot: %s", b)
	}
	st, e := os.Stat(s.path)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("snapshot not private")
	}
}
