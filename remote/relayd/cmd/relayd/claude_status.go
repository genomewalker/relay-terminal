package main

import (
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Claude sends current model and effort to a status-line command even while
// idle. This command records restart metadata and subscription windows only;
// it never persists prompts, transcript bodies, cost or credentials.
type claudeQuotaWindow struct {
	UsedPercentage float64 `json:"used_percentage"`
	ResetsAt       *int64  `json:"resets_at,omitempty"`
}

func claudeQuotaWindows(raw json.RawMessage) map[string]claudeQuotaWindow {
	var input map[string]json.RawMessage
	if json.Unmarshal(raw, &input) != nil {
		return nil
	}
	result := make(map[string]claudeQuotaWindow)
	for _, key := range []string{"five_hour", "seven_day"} {
		var value struct {
			Used  *float64 `json:"used_percentage"`
			Reset *int64   `json:"resets_at"`
		}
		if json.Unmarshal(input[key], &value) != nil || value.Used == nil || *value.Used < 0 || *value.Used > 100 {
			continue
		}
		if value.Reset != nil && (*value.Reset <= 0 || *value.Reset >= 253402300800) {
			continue
		}
		result[key] = claudeQuotaWindow{UsedPercentage: *value.Used, ResetsAt: value.Reset}
	}
	return result
}

type claudeLiveStatus struct {
	SessionID  string                       `json:"session_id"`
	PaneID     string                       `json:"pane_id"`
	Model      string                       `json:"model"`
	Effort     string                       `json:"effort,omitempty"`
	CWD        string                       `json:"cwd"`
	Project    string                       `json:"project_dir"`
	Captured   time.Time                    `json:"captured_at"`
	RateLimits map[string]claudeQuotaWindow `json:"rate_limits,omitempty"`
}

func captureClaudeStatus(pane string, raw []byte, home string) error {
	if pane == "" || len(pane) > 110 || strings.ContainsAny(pane, "/\\\x00\r\n") || len(raw) > 65536 || os.Getenv("RELAY_SESSION") != pane {
		return errors.New("invalid Claude status pane")
	}
	var input struct {
		SessionID  string          `json:"session_id"`
		RateLimits json.RawMessage `json:"rate_limits"`
		Model      struct {
			ID string `json:"id"`
		} `json:"model"`
		Effort struct {
			Level string `json:"level"`
		} `json:"effort"`
		CWD       string `json:"cwd"`
		Workspace struct {
			Project string `json:"project_dir"`
		} `json:"workspace"`
	}
	if json.Unmarshal(raw, &input) != nil || input.SessionID == "" || len(input.SessionID) > 110 ||
		strings.ContainsAny(input.SessionID, "/\\\x00\r\n") || input.Model.ID == "" || len(input.Model.ID) > 180 ||
		!filepath.IsAbs(input.CWD) || !filepath.IsAbs(input.Workspace.Project) {
		return errors.New("invalid Claude status identity or settings")
	}
	directory := filepath.Join(home, ".local", "share", "relay", "claude-status")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return errors.New("Claude status directory is not private")
	}
	status := claudeLiveStatus{SessionID: input.SessionID, PaneID: pane, Model: input.Model.ID,
		Effort: input.Effort.Level, CWD: input.CWD, Project: input.Workspace.Project, Captured: time.Now().UTC(),
		RateLimits: claudeQuotaWindows(input.RateLimits)}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, pane+"-*.tmp")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, filepath.Join(directory, pane+".json")); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func runClaudeStatusCapture(arguments []string) {
	flags := flag.NewFlagSet("claude-status-capture", flag.ExitOnError)
	pane := flags.String("pane", "", "exact Relay pane")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("invalid Claude status capture")
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 65537))
	if err != nil || len(raw) > 65536 {
		fatal("Claude status input exceeds bound")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal("private home unavailable")
	}
	if err := captureClaudeStatus(*pane, raw, home); err != nil {
		fatal(err.Error())
	}
}
