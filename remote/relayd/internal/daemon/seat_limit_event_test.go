package daemon

import (
	"encoding/json"
	"testing"
)

// The journal keeps a SeatLimit event's window, reset and row fields, and its
// lifecycle mapping keeps the binding's stored lifecycle.
func TestSeatLimitEventSurvivesCanonicalAndJournalFilters(t *testing.T) {
	raw := []byte(`{"hook_event_name":"SeatLimit","session_id":"s","message":"You've hit your weekly limit","limit_kind":"seven_day","limit_model":"Fable","resets_at":1793836800,"seat_limit_id":"row-1","account_scope":"scope","transcript_path":"/secret/path"}`)
	envelope, err := CanonicalAgentEnvelope("claude", raw, "hook")
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(indexedAgentPayload(envelope, 7), &decoded); err != nil {
		t.Fatal(err)
	}
	event := decoded["event"].(map[string]any)
	for _, key := range []string{"limit_kind", "limit_model", "resets_at", "seat_limit_id", "account_scope", "message", "session_id"} {
		if event[key] == nil {
			t.Fatalf("%s dropped: %+v", key, event)
		}
	}
	if event["transcript_path"] != nil {
		t.Fatal("transcript path kept")
	}
	if claudeHookLifecycle("SeatLimit", "") != "" {
		t.Fatal("SeatLimit must not change the binding lifecycle")
	}
}
