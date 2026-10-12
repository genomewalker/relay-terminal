package main

import (
	"encoding/json"
	"testing"
)

func TestEditorOpenInvocationsHaveIndependentIdentities(t *testing.T) {
	ids := make(map[string]bool)
	for i := 0; i < 20; i++ {
		payload, err := editorOpenEvent([]string{"/tmp/a # λ.txt"}, false)
		if err != nil {
			t.Fatal(err)
		}
		var event struct {
			Type      string   `json:"type"`
			RequestID string   `json:"request_id"`
			Paths     []string `json:"paths"`
		}
		if err := json.Unmarshal(payload, &event); err != nil {
			t.Fatal(err)
		}
		if event.Type != "open_file" || len(event.Paths) != 1 || event.Paths[0] != "/tmp/a # λ.txt" {
			t.Fatalf("incorrect event: %s", payload)
		}
		if len(event.RequestID) != 32 || ids[event.RequestID] {
			t.Fatalf("reused or invalid request identity: %q", event.RequestID)
		}
		ids[event.RequestID] = true
	}
}
