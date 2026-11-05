package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClaudeHookSettingsShowRelayStatusLine(t *testing.T) {
	var settings struct {
		StatusLine struct {
			Type            string `json:"type"`
			Command         string `json:"command"`
			RefreshInterval int    `json:"refreshInterval"`
		} `json:"statusLine"`
	}
	if err := json.Unmarshal([]byte(claudeHookSettings), &settings); err != nil {
		t.Fatal(err)
	}
	// Linux rotation accepts a status capture at most 25 s old; idle refresh keeps it current.
	if settings.StatusLine.Type != "command" || settings.StatusLine.Command != "~/.local/bin/relayd claude-statusline" ||
		settings.StatusLine.RefreshInterval <= 0 || settings.StatusLine.RefreshInterval >= 25 {
		t.Fatalf("Relay status line missing or unable to keep the capture fresh: %+v", settings.StatusLine)
	}
}

func TestAccountClaudeStatusCommand(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "settings.json")
	if got := accountClaudeStatusCommand(path); got != "" {
		t.Fatalf("missing settings gave %q", got)
	}
	for text, want := range map[string]string{
		`{"statusLine":{"type":"command","command":"bash \"$HOME/.config/relay/cc-status.sh\""}}`: `bash "$HOME/.config/relay/cc-status.sh"`,
		`{"statusLine":{"type":"static","command":"x"}}`:                                          "",
		`{"statusLine":{"type":"command","command":"  "}}`:                                        "",
		`{"statusLine":{"type":"command","command":"relayd claude-statusline"}}`:                  "",
		`{"model":"x"}`: "",
		`not json`:      "",
	} {
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := accountClaudeStatusCommand(path); got != want {
			t.Fatalf("%s: got %q, want %q", text, got, want)
		}
	}
}

func TestClaudeStatusLineCapturesAndShowsTheAccountFooter(t *testing.T) {
	if mainHelper() {
		return
	}
	home := t.TempDir()
	account := filepath.Join(home, "account")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	footer := `{"statusLine":{"type":"command","command":"read -r line; printf 'footer:%s' \"${#line}\"; exit 3"}}`
	if err := os.WriteFile(filepath.Join(account, "settings.json"), []byte(footer), 0o600); err != nil {
		t.Fatal(err)
	}
	pane := "4f0d2b8e-6a3c-4c1e-9f57-2d8b1a7c3e90"
	session := "06f2fc08-cd1b-4cc9-b460-153eb62bd6e5"
	input, _ := json.Marshal(map[string]any{"session_id": session, "cwd": home, "model": map[string]string{"id": "claude-opus-5-5"},
		"workspace": map[string]string{"current_dir": home, "project_dir": home}})
	command := exec.Command(os.Args[0], "-test.run=^TestClaudeStatusLineCapturesAndShowsTheAccountFooter$")
	command.Env = append(os.Environ(), "HOME="+home, "CLAUDE_CONFIG_DIR="+account, "RELAY_SESSION="+pane,
		"RELAY_MAIN_TEST_HELPER=1", "RELAY_MAIN_TEST_ARGS=claude-statusline")
	command.Stdin = strings.NewReader(string(input) + "\n")
	output, err := command.Output()
	exit, _ := err.(*exec.ExitError)
	if exit == nil || exit.ExitCode() != 3 || string(output) != "footer:"+itoa(len(input)) {
		t.Fatalf("account footer output or exit status not passed through: %q %v", output, err)
	}
	raw, err := os.ReadFile(filepath.Join(home, ".local", "share", "relay", "claude-status", pane+".json"))
	if err != nil {
		t.Fatalf("pane status was not captured: %v", err)
	}
	var status claudeLiveStatus
	if err := json.Unmarshal(raw, &status); err != nil || status.SessionID != session || status.PaneID != pane ||
		time.Since(status.Captured) > time.Minute {
		t.Fatalf("captured status is wrong: %s %v", raw, err)
	}
}

func itoa(value int) string {
	data, _ := json.Marshal(value)
	return string(data)
}
