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

// TestAccountLaunchHelper is runClaude in a child process, which execs the
// fake claude named by RELAY_CLAUDE_BIN.
func TestAccountLaunchHelper(t *testing.T) {
	encoded := os.Getenv("RELAY_TEST_ACCOUNT_LAUNCH")
	if encoded == "" {
		return
	}
	var arguments []string
	if err := json.Unmarshal([]byte(encoded), &arguments); err != nil {
		os.Exit(5)
	}
	runClaude(arguments)
	os.Exit(6)
}

// A replayed launch carries the retired status-line settings file; the
// account's model defaults and the Relay permission default are added, the
// retired file is dropped, and Relay's own settings appear once.
func TestClaudeLaunchAppliesAccountDefaultsAndDropsRetiredStatusSettings(t *testing.T) {
	home := t.TempDir()
	if _, err := agentaccounts.Save(home, agentaccounts.DefaultRegistry()); err != nil {
		t.Fatal(err)
	}
	account := filepath.Join(home, ".claude-personal")
	if err := os.MkdirAll(account, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"relay-model-defaults.json":  `{"version": 1, "model": "opus", "effort": "high"}`,
		"relay-launch-defaults.json": `{"version": 1, "permission_mode": "plan"}`,
	} {
		if err := os.WriteFile(filepath.Join(account, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	output := filepath.Join(home, "argv")
	fake := filepath.Join(home, "fake-claude")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \""+output+"\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	retired := filepath.Join(home, ".config", "relay", "claude-hooks-status.json")
	hooks := filepath.Join(home, ".relay", "claude-hooks.json")
	for _, test := range []struct {
		arguments, want []string
	}{
		{[]string{"--settings", retired, "hello"},
			[]string{"--settings", hooks, "--permission-mode", "plan", "--model", "opus", "--effort", "high", "hello"}},
		{[]string{"--settings=" + retired, "--model", "sonnet", "hello"},
			[]string{"--settings", hooks, "--permission-mode", "plan", "--effort", "high", "--model", "sonnet", "hello"}},
	} {
		os.Remove(output)
		encoded, _ := json.Marshal(test.arguments)
		command := exec.Command(os.Args[0], "-test.run=^TestAccountLaunchHelper$")
		command.Dir = home
		command.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin", "CLAUDE_CONFIG_DIR=" + account,
			"RELAY_CLAUDE_BIN=" + fake, "XDG_STATE_HOME=" + filepath.Join(home, "state"),
			"RELAY_TEST_ACCOUNT_LAUNCH=" + string(encoded)}
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v\n%s", test.arguments, err, out)
		}
		data, err := os.ReadFile(output)
		if err != nil {
			t.Fatal(err)
		}
		got := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
		if strings.Join(got, "\x00") != strings.Join(test.want, "\x00") {
			t.Errorf("%q:\n got %q\nwant %q", test.arguments, got, test.want)
		}
	}
}
