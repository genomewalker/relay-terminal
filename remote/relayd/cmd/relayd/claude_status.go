package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/contextusage"
	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/protocol"
	"github.com/relay-terminal/relayd/internal/seatlimit"
	"github.com/relay-terminal/relayd/internal/subscriptionquota"
)

// Claude sends current model and effort to a status-line command even while
// idle. This command records restart metadata, context usage and subscription windows only;
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
	SessionID    string                       `json:"session_id"`
	PaneID       string                       `json:"pane_id"`
	Model        string                       `json:"model"`
	Effort       string                       `json:"effort,omitempty"`
	CWD          string                       `json:"cwd"`
	Project      string                       `json:"project_dir"`
	Captured     time.Time                    `json:"captured_at"`
	RateLimits   map[string]claudeQuotaWindow `json:"rate_limits,omitempty"`
	ContextUsage *contextusage.Counts         `json:"context_usage,omitempty"`
	// The pane's own account, so the desktop shows this pane that account's
	// usage when one host runs several Claude accounts (dandy-07, 2026-11-19).
	AccountScope string `json:"account_scope,omitempty"`
	// The conversation's current seat/usage-limit refusal (HTTP 429), read
	// from the transcript tail. Claude fires no Stop hook for that turn.
	SeatLimit *seatlimit.Event `json:"seat_limit,omitempty"`
}

func captureClaudeStatus(pane string, raw []byte, home string) error {
	if pane == "" || len(pane) > 110 || strings.ContainsAny(pane, "/\\\x00\r\n") || len(raw) > 65536 || os.Getenv("RELAY_SESSION") != pane {
		return errors.New("invalid Claude status pane")
	}
	var input struct {
		SessionID     string          `json:"session_id"`
		RateLimits    json.RawMessage `json:"rate_limits"`
		ContextWindow json.RawMessage `json:"context_window"`
		Model         struct {
			ID string `json:"id"`
		} `json:"model"`
		Effort struct {
			Level string `json:"level"`
		} `json:"effort"`
		CWD            string `json:"cwd"`
		TranscriptPath string `json:"transcript_path"`
		Workspace      struct {
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
		RateLimits: claudeQuotaWindows(input.RateLimits), AccountScope: subscriptionquota.ClaudeAccountScope(home)}
	if counts := contextusage.Claude(input.ContextWindow); counts.Used != nil || counts.Limit != nil {
		status.ContextUsage = &counts
	}
	statusPath := filepath.Join(directory, pane+".json")
	if filepath.IsAbs(input.TranscriptPath) && len(input.TranscriptPath) <= 4096 {
		if tail, err := seatlimit.ReadTail(input.TranscriptPath, seatlimit.TailBytes); err == nil {
			status.SeatLimit = seatlimit.Latest(tail)
		}
	}
	if status.SeatLimit != nil && time.Since(status.SeatLimit.At) > seatLimitFreshness {
		// A resumed conversation's old refusal, possibly from another account.
		status.SeatLimit = nil
	}
	if status.SeatLimit != nil && status.SeatLimit.ID != previousSeatLimitID(statusPath) {
		// The status file names a refusal only once it was sent, so a failed
		// send is tried again at the next update; the desktop records each
		// limit occurrence once.
		if emitSeatLimitEvent(pane, input.SessionID, status.AccountScope, status.SeatLimit) != nil {
			status.SeatLimit = nil
		}
	}
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
	if err := os.Rename(temporary, statusPath); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// seatLimitFreshness bounds how old a refusal row may be when first seen.
// The status line runs every 10 s, so a new refusal is seen within seconds.
const seatLimitFreshness = 15 * time.Minute

// previousSeatLimitID is the refusal the pane's last status already named.
func previousSeatLimitID(path string) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 1<<20 {
		return ""
	}
	var previous struct {
		SeatLimit *seatlimit.Event `json:"seat_limit"`
	}
	if json.Unmarshal(data, &previous) != nil || previous.SeatLimit == nil {
		return ""
	}
	return previous.SeatLimit.ID
}

// seatLimitHookEvent is the agent event the desktop reads: a synthetic
// "SeatLimit" hook with only content-free fields and Claude's short notice.
func seatLimitHookEvent(session, accountScope string, event *seatlimit.Event) map[string]any {
	hook := map[string]any{
		"hook_event_name": "SeatLimit", "session_id": session, "occurred_at": event.At.Format(time.RFC3339Nano),
		"message": event.Text, "limit_kind": event.Kind, "seat_limit_id": event.ID,
	}
	if event.Model != "" {
		hook["limit_model"] = event.Model
	}
	if event.ResetsAt > 0 {
		hook["resets_at"] = event.ResetsAt
	}
	if accountScope != "" && len(accountScope) <= 512 {
		hook["account_scope"] = accountScope
	}
	return hook
}

// emitSeatLimitEvent sends the event on the pane's ordinary (unbound) event
// channel, as a one-shot hook does. It never touches the agent binding.
func emitSeatLimitEvent(pane, session, accountScope string, event *seatlimit.Event) error {
	raw, err := json.Marshal(seatLimitHookEvent(session, accountScope, event))
	if err != nil {
		return err
	}
	envelope, err := daemon.CanonicalAgentEnvelope("claude", raw, "hook")
	if err != nil {
		return err
	}
	connection, err := net.DialTimeout("unix", defaultSocket(), 2*time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	writer := protocol.NewWriter(connection)
	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, SessionID: pane, EventOnly: true})
	if err != nil {
		return err
	}
	if err := writer.Write(hello); err != nil {
		return err
	}
	return writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: envelope})
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

// runClaudeStatusLine is the status line in Relay's claude-hooks.json. It
// records this pane's status for Relay, then shows the account's own status
// line with the same input, so Relay's settings never replace the user's footer.
func runClaudeStatusLine(arguments []string) {
	if len(arguments) != 0 {
		fatal("invalid Claude status line")
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 65537))
	if err != nil || len(raw) > 65536 {
		fatal("Claude status input exceeds bound")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal("private home unavailable")
	}
	if pane := os.Getenv("RELAY_SESSION"); pane != "" {
		// Capture failure never hides the footer; rotation then reports stale status.
		_ = captureClaudeStatus(pane, raw, home)
	}
	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		configDir = filepath.Join(home, ".claude")
	}
	command := accountClaudeStatusCommand(filepath.Join(configDir, "settings.json"))
	if command == "" {
		return
	}
	// The footer runs in its own process group so a timeout also stops its helpers.
	child := exec.Command("/bin/sh", "-c", command)
	child.Stdin = bytes.NewReader(raw)
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		os.Exit(1)
	}
	// Claude cancels an in-flight status line when a newer update arrives:
	// the footer's group stops with this command, never outliving it.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	select {
	case err = <-done:
	case <-stop:
		_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
		<-done
		os.Exit(1)
	case <-time.After(8 * time.Second):
		_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
		<-done
		os.Exit(1)
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() > 0 {
			os.Exit(exit.ExitCode())
		}
		os.Exit(1)
	}
}

// accountClaudeStatusCommand returns the account's own command status line,
// or "" when there is none. Relay's own status line is never run recursively.
func accountClaudeStatusCommand(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	var settings struct {
		StatusLine struct {
			Type    string `json:"type"`
			Command string `json:"command"`
		} `json:"statusLine"`
	}
	if json.NewDecoder(io.LimitReader(file, 1<<20)).Decode(&settings) != nil ||
		settings.StatusLine.Type != "command" || strings.TrimSpace(settings.StatusLine.Command) == "" ||
		strings.Contains(settings.StatusLine.Command, "claude-statusline") {
		return ""
	}
	return settings.StatusLine.Command
}
