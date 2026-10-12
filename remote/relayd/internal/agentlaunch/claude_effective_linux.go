//go:build linux

package agentlaunch

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type ClaudeEffectiveSettings struct {
	SessionID      string    `json:"session_id"`
	PaneID         string    `json:"pane_id"`
	SourcePID      int       `json:"source_pid"`
	SourceStart    string    `json:"source_start"`
	Model          string    `json:"model"`
	Effort         string    `json:"effort,omitempty"`
	PermissionMode string    `json:"permission_mode"`
	CWD            string    `json:"cwd"`
	FreshArguments []string  `json:"fresh_args"`
	CapturedAt     time.Time `json:"captured_at"`
}

type claudeStatusRecord struct {
	SessionID  string    `json:"session_id"`
	PaneID     string    `json:"pane_id"`
	Model      string    `json:"model"`
	Effort     string    `json:"effort"`
	CWD        string    `json:"cwd"`
	Project    string    `json:"project_dir"`
	CapturedAt time.Time `json:"captured_at"`
}

func DiscoverClaudeEffectiveSettings(snapshot Snapshot, sessionID string) (ClaudeEffectiveSettings, error) {
	if snapshot.Client != "claude" || !sessionUUID.MatchString(sessionID) || !snapshot.Arguments.Reusable {
		return ClaudeEffectiveSettings{}, errors.New("invalid Claude source")
	}
	if err := VerifyProcess(snapshot); err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	if !claudeArgBindsSession(snapshot.EffectiveArgs, sessionID) {
		return ClaudeEffectiveSettings{}, errors.New("Claude source does not name exact session")
	}
	home, config, err := claudeSourceDirectories(snapshot)
	if err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	statusPath := filepath.Join(home, ".local", "share", "relay", "claude-status", snapshot.RelayPaneID+".json")
	status, err := readClaudeStatusRecord(statusPath)
	if err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	if status.SessionID != sessionID || status.PaneID != snapshot.RelayPaneID || status.Project != snapshot.CWD || status.CWD != snapshot.CWD ||
		status.Model == "" || time.Since(status.CapturedAt) < 0 || time.Since(status.CapturedAt) > 25*time.Second {
		return ClaudeEffectiveSettings{}, errors.New("Claude live status is stale or changed")
	}
	if err := verifyClaudeAgentListing(snapshot, sessionID); err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	mode, err := claudeTranscriptPermission(config, sessionID)
	if err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	args, err := effectiveClaudeArguments(snapshot.Arguments.Fresh, status.Model, status.Effort, mode)
	if err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	if err := VerifyProcess(snapshot); err != nil {
		return ClaudeEffectiveSettings{}, err
	}
	return ClaudeEffectiveSettings{SessionID: sessionID, PaneID: snapshot.RelayPaneID,
		SourcePID: snapshot.PID, SourceStart: snapshot.ProcessStart, Model: status.Model,
		Effort: status.Effort, PermissionMode: mode, CWD: status.CWD,
		FreshArguments: args, CapturedAt: status.CapturedAt}, nil
}

func claudeArgBindsSession(args []string, id string) bool {
	for i, arg := range args {
		if (arg == "--resume" || arg == "-r" || arg == "--session-id") && i+1 < len(args) && args[i+1] == id {
			return true
		}
		if arg == "--resume="+id || arg == "--session-id="+id {
			return true
		}
	}
	return false
}

func claudeSourceDirectories(snapshot Snapshot) (string, string, error) {
	raw, err := boundedRead(filepath.Join("/proc", strconv.Itoa(snapshot.PID), "environ"))
	if err != nil {
		return "", "", errors.New("Claude source environment unavailable")
	}
	vars := map[string]string{}
	for _, entry := range bytes.Split(raw, []byte{0}) {
		key, value, found := bytes.Cut(entry, []byte{'='})
		if found && (string(key) == "HOME" || string(key) == "CLAUDE_CONFIG_DIR") {
			if _, duplicate := vars[string(key)]; duplicate {
				return "", "", errors.New("ambiguous Claude source environment")
			}
			vars[string(key)] = string(value)
		}
	}
	home := vars["HOME"]
	config := vars["CLAUDE_CONFIG_DIR"]
	if config == "" {
		config = filepath.Join(home, ".claude")
	}
	if !filepath.IsAbs(home) || filepath.Clean(home) != home || !filepath.IsAbs(config) || filepath.Clean(config) != config {
		return "", "", errors.New("Claude source directories are invalid")
	}
	return home, config, nil
}

func readClaudeStatusRecord(path string) (claudeStatusRecord, error) {
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
		return claudeStatusRecord{}, errors.New("Claude status directory is not private")
	}
	parentStat, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || parentStat.Uid != uint32(os.Getuid()) {
		return claudeStatusRecord{}, errors.New("Claude status directory owner changed")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > 4096 {
		return claudeStatusRecord{}, errors.New("private Claude status unavailable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return claudeStatusRecord{}, errors.New("Claude status owner changed")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return claudeStatusRecord{}, err
	}
	var record claudeStatusRecord
	if json.Unmarshal(data, &record) != nil {
		return claudeStatusRecord{}, errors.New("Claude status is invalid")
	}
	return record, nil
}

func verifyClaudeAgentListing(snapshot Snapshot, sessionID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, snapshot.Executable, "agents", "--json")
	command.Dir = snapshot.CWD
	output, err := command.Output()
	if err != nil || len(output) > 1<<20 {
		return errors.New("Claude active-session listing unavailable")
	}
	var rows []struct {
		PID       int    `json:"pid"`
		SessionID string `json:"sessionId"`
		CWD       string `json:"cwd"`
	}
	if json.Unmarshal(output, &rows) != nil {
		return errors.New("Claude active-session listing invalid")
	}
	matches := 0
	for _, row := range rows {
		if row.PID == snapshot.PID {
			if row.SessionID != sessionID || row.CWD != snapshot.CWD {
				return errors.New("Claude agent listing disagrees with source")
			}
			matches++
		}
	}
	if matches != 1 {
		return errors.New("Claude agent listing lacks unique source")
	}
	return nil
}

func claudeTranscriptPermission(config, sessionID string) (string, error) {
	var found string
	visited := 0
	err := filepath.WalkDir(filepath.Join(config, "projects"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		visited++
		if visited > 100000 {
			return errors.New("Claude transcript search exceeds bound")
		}
		if entry.Type().IsRegular() && entry.Name() == sessionID+".jsonl" {
			if found != "" {
				return errors.New("ambiguous Claude transcript")
			}
			found = path
		}
		return nil
	})
	if err != nil || found == "" {
		return "", errors.New("Claude transcript unavailable")
	}
	info, err := os.Lstat(found)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 256<<20 {
		return "", errors.New("Claude transcript unavailable or too large")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return "", errors.New("Claude transcript owner changed")
	}
	file, err := os.Open(found)
	if err != nil {
		return "", err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	mode := ""
	for scanner.Scan() {
		var row struct {
			Type           string `json:"type"`
			SessionID      string `json:"sessionId"`
			PermissionMode string `json:"permissionMode"`
		}
		if json.Unmarshal(scanner.Bytes(), &row) != nil {
			return "", errors.New("invalid Claude transcript entry")
		}
		if row.Type == "permission-mode" && row.SessionID == sessionID {
			mode = row.PermissionMode
		}
	}
	if scanner.Err() != nil {
		return "", errors.New("Claude transcript unreadable")
	}
	if mode == "" {
		return "", errors.New("Claude permission mode unavailable")
	}
	return mode, nil
}

func effectiveClaudeArguments(fresh []string, model, effort, mode string) ([]string, error) {
	allowed := map[string]bool{"default": true, "plan": true, "acceptEdits": true, "auto": true, "dontAsk": true, "bypassPermissions": true}
	if !allowed[mode] || model == "" || len(model) > 180 || strings.ContainsAny(model, "\x00\r\n") {
		return nil, errors.New("invalid effective Claude settings")
	}
	if effort != "" && !map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}[effort] {
		return nil, errors.New("invalid Claude effort")
	}
	args := make([]string, 0, len(fresh)+6)
	for i := 0; i < len(fresh); i++ {
		arg := fresh[i]
		if arg == "--model" || arg == "-m" || arg == "--permission-mode" || arg == "--effort" {
			if i+1 >= len(fresh) {
				return nil, errors.New("captured Claude option is incomplete")
			}
			i++
			continue
		}
		if strings.HasPrefix(arg, "--model=") || strings.HasPrefix(arg, "--permission-mode=") || strings.HasPrefix(arg, "--effort=") {
			continue
		}
		if arg == "--dangerously-skip-permissions" && mode != "bypassPermissions" {
			continue
		}
		args = append(args, arg)
	}
	args = append(args, "--model", model, "--permission-mode", mode)
	if effort != "" {
		args = append(args, "--effort", effort)
	}
	return args, nil
}
