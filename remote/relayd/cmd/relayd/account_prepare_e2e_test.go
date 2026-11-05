package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// A launch in an account that never completed Claude's first run gets the
// main account's answers before Claude starts; its own identity is kept.
func TestClaudeLaunchCopiesFirstRunAnswersBeforeExec(t *testing.T) {
	home := t.TempDir()
	if _, err := agentaccounts.Save(home, agentaccounts.DefaultRegistry()); err != nil {
		t.Fatal(err)
	}
	account := filepath.Join(home, ".claude-personal")
	if err := os.MkdirAll(account, 0o700); err != nil {
		t.Fatal(err)
	}
	main := `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.0", "userID": "main",
  "projects": {"` + home + `": {"hasTrustDialogAccepted": true, "history": []}}}`
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(main), 0o600); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(account, ".claude.json")
	if err := os.WriteFile(state, []byte(`{"userID": "account"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(home, "seen")
	fake := filepath.Join(home, "fake-claude")
	// The fake records the account file as Claude would find it at start.
	if err := os.WriteFile(fake, []byte("#!/bin/sh\ncat \""+state+"\" > \""+output+"\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal([]string{"hello"})
	command := exec.Command(os.Args[0], "-test.run=^TestAccountLaunchHelper$")
	command.Dir = home
	command.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin", "CLAUDE_CONFIG_DIR=" + account,
		"RELAY_CLAUDE_BIN=" + fake, "XDG_STATE_HOME=" + filepath.Join(home, "state"),
		"RELAY_TEST_ACCOUNT_LAUNCH=" + string(encoded)}
	if out, err := command.CombinedOutput(); err != nil || strings.Contains(string(out), "Relay:") {
		t.Fatalf("%v\n%s", err, out)
	}
	var seen struct {
		Onboarded bool                       `json:"hasCompletedOnboarding"`
		UserID    string                     `json:"userID"`
		Projects  map[string]map[string]bool `json:"projects"`
	}
	data, err := os.ReadFile(output)
	if err != nil || json.Unmarshal(data, &seen) != nil {
		t.Fatalf("%v %s", err, data)
	}
	if !seen.Onboarded || seen.UserID != "account" || !seen.Projects[home]["hasTrustDialogAccepted"] {
		t.Fatalf("Claude started with %s", data)
	}
}
