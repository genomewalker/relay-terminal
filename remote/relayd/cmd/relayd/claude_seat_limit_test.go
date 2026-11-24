package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// The status line reads the transcript tail and sends one SeatLimit event per
// refusal row on the pane's unbound event channel. A row is recorded in the
// status only after it was sent; an old row (a resumed conversation's
// history) is never reported.
func TestClaudeStatusSendsSeatLimitOncePerRefusal(t *testing.T) {
	const pane = "12345678-1234-4234-8234-123456789abc"
	t.Setenv("RELAY_SESSION", pane)
	runtime, err := os.MkdirTemp("/tmp", "sl")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(runtime)
	t.Setenv("XDG_RUNTIME_DIR", runtime)
	home := t.TempDir()
	transcript := filepath.Join(home, "t.jsonl")
	input := []byte(`{"session_id":"aaaaaaaa-1234-4234-8234-123456789abc","transcript_path":"` + transcript + `","model":{"id":"claude-opus-5"},"cwd":"/work","workspace":{"project_dir":"/work"}}`)
	statusFile := filepath.Join(home, ".local", "share", "relay", "claude-status", pane+".json")
	writeRow := func(at time.Time) {
		row := `{"isSidechain":false,"type":"assistant","uuid":"row-1","timestamp":"` + at.UTC().Format(time.RFC3339Nano) +
			`","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your weekly limit · resets Nov 5 at 1am (Europe/Copenhagen)"}]},` +
			`"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1793836800,"rateLimitType":"seven_day"}},` +
			`"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}` + "\n"
		if err := os.WriteFile(transcript, []byte(row), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	named := func() string { return previousSeatLimitID(statusFile) }

	writeRow(time.Now().Add(-time.Hour))
	if err := captureClaudeStatus(pane, input, home); err != nil || named() != "" {
		t.Fatalf("old refusal reported: %v %q", err, named())
	}
	// No supervisor listening: the send fails and the status does not name it.
	writeRow(time.Now())
	if err := captureClaudeStatus(pane, input, home); err != nil || named() != "" {
		t.Fatalf("unsent refusal recorded: %v %q", err, named())
	}

	listener, err := net.Listen("unix", filepath.Join(runtime, "relayd.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	events := make(chan map[string]any, 4)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
			hello, err := protocol.ReadFrame(connection)
			var payload protocol.HelloPayload
			if err != nil || hello.Type != protocol.Hello || protocol.DecodeJSON(hello, &payload) != nil ||
				!payload.EventOnly || payload.BindAgent || payload.SessionID != pane {
				events <- map[string]any{"error": "bad hello"}
				connection.Close()
				continue
			}
			frame, err := protocol.ReadFrame(connection)
			var envelope map[string]any
			if err == nil && frame.Type == protocol.AgentEvent && json.Unmarshal(frame.Payload, &envelope) == nil {
				event, _ := envelope["event"].(map[string]any)
				events <- event
			}
			connection.Close()
		}
	}()
	for range 2 {
		if err := captureClaudeStatus(pane, input, home); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case event := <-events:
		if event["hook_event_name"] != "SeatLimit" || event["limit_kind"] != "seven_day" || event["resets_at"] != float64(1793836800) ||
			event["seat_limit_id"] != "row-1" || event["session_id"] != "aaaaaaaa-1234-4234-8234-123456789abc" {
			t.Fatalf("wrong event: %+v", event)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no SeatLimit event")
	}
	select {
	case event := <-events:
		t.Fatalf("repeated event for the same refusal: %+v", event)
	case <-time.After(300 * time.Millisecond):
	}
	if named() != "row-1" {
		t.Fatalf("status does not name the sent refusal: %q", named())
	}
}
