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
// refusal row on the pane's unbound event channel; repeated status updates
// for the same row send nothing more.
func TestClaudeStatusSendsSeatLimitOncePerRefusal(t *testing.T) {
	const pane = "12345678-1234-4234-8234-123456789abc"
	t.Setenv("RELAY_SESSION", pane)
	runtime, err := os.MkdirTemp("/tmp", "sl")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(runtime)
	t.Setenv("XDG_RUNTIME_DIR", runtime)
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
	home := t.TempDir()
	transcript := filepath.Join(home, "t.jsonl")
	row := `{"isSidechain":false,"type":"assistant","uuid":"row-1","timestamp":"2026-11-03T21:05:15.651Z","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your weekly limit · resets Nov 5 at 1am (Europe/Copenhagen)"}]},"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1793836800,"rateLimitType":"seven_day"}},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}` + "\n"
	if err := os.WriteFile(transcript, []byte(row), 0o600); err != nil {
		t.Fatal(err)
	}
	input := []byte(`{"session_id":"aaaaaaaa-1234-4234-8234-123456789abc","transcript_path":"` + transcript + `","model":{"id":"claude-opus-5"},"cwd":"/work","workspace":{"project_dir":"/work"}}`)
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
	data, _ := os.ReadFile(filepath.Join(home, ".local", "share", "relay", "claude-status", pane+".json"))
	var status claudeLiveStatus
	if json.Unmarshal(data, &status) != nil || status.SeatLimit == nil || status.SeatLimit.ID != "row-1" {
		t.Fatalf("status does not name the refusal: %s", data)
	}
}
