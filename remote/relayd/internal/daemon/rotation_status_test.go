package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRotationStatusRefusesMissingOrMismatchedEvidence(t *testing.T) {
	server := NewServer()
	server.stateDir = t.TempDir()
	pane := ClaudeRotationID("status-pane")
	if _, err := server.RotationStatus(pane); err == nil {
		t.Fatal("missing claim accepted")
	}
	claims := filepath.Join(server.stateDir, "rotation-launches")
	if err := os.MkdirAll(claims, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(claims, pane+".json")
	claim, _ := json.Marshal(claudeRotationClaim{PaneID: ClaudeRotationID("other"), SessionID: "session"})
	if err := os.WriteFile(path, claim, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := server.RotationStatus(pane); err == nil {
		t.Fatal("mismatched claim accepted")
	}
	claim, _ = json.Marshal(claudeRotationClaim{PaneID: pane, SessionID: "session"})
	if err := os.WriteFile(path, claim, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := server.RotationStatus(pane); err == nil {
		t.Fatal("missing worker accepted")
	}
}
