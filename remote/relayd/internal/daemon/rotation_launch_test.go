package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestClaudeRotationPlanBindsCapturedArgsAndNarrowReceiptRule(t *testing.T) {
	fresh := []string{"--model", "haiku", "--permission-mode", "default"}
	session := ClaudeRotationID("intent-one")
	rule := "Bash(python3 /maps/relay/rotation-decision/claude_backend.py receipt *)"
	planned := append(append([]string{}, fresh...), "--session-id", session, "--allowedTools", rule)
	if err := validateClaudeRotationArgs(fresh, planned, session); err != nil {
		t.Fatal(err)
	}
	withPriorAllow := []string{"--model", "haiku", "--allowedTools=Bash(*)"}
	withPriorAllow = append(withPriorAllow, "--session-id", session, "--allowedTools", rule)
	if err := validateClaudeRotationArgs(withPriorAllow[:3], withPriorAllow, session); err == nil {
		t.Fatal("captured allow rule accepted")
	}
	for name, changed := range map[string][]string{
		"configuration": {"--model", "sonnet", "--permission-mode", "default", "--session-id", session, "--allowedTools", rule},
		"session":       {"--model", "haiku", "--permission-mode", "default", "--session-id", ClaudeRotationID("other"), "--allowedTools", rule},
		"broad rule":    {"--model", "haiku", "--permission-mode", "default", "--session-id", session, "--allowedTools", "Bash(*)"},
		"shell syntax":  {"--model", "haiku", "--permission-mode", "default", "--session-id", session, "--allowedTools", "Bash(python3 /maps/relay/rotation-decision/claude_backend.py;evil receipt *)"},
		"duplicate":     append(append([]string{}, planned...), "--allowedTools", rule),
	} {
		if err := validateClaudeRotationArgs(fresh, changed, session); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	path := filepath.Join(t.TempDir(), "claim.json")
	claim := claudeRotationClaim{IntentID: "intent-one", PaneID: "pane-one", SessionID: session,
		SourceSessionID: "source-one", SnapshotSHA256: "digest-one", Arguments: planned}
	data, err := json.Marshal(claim)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadClaudeRotationClaim(path, "intent-one", "pane-one", session, "source-one", "digest-one", fresh); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadClaudeRotationClaim(path, "intent-one", "pane-other", session, "source-one", "digest-one", fresh); err == nil {
		t.Fatal("claim crossed pane identity")
	}
	if _, err := ReadClaudeRotationClaim(path, "intent-one", "pane-one", session, "source-other", "digest-one", fresh); err == nil {
		t.Fatal("claim crossed source session identity")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadClaudeRotationClaim(path, "intent-one", "pane-one", session, "source-one", "digest-one", fresh); err == nil {
		t.Fatal("public claim accepted")
	}
}
