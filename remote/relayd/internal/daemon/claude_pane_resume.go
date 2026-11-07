package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// ReadClaudePaneResumePlan is read-only admission for an explicit same-pane
// restart of the pane's own Claude session onto the installed launcher. The
// session is the verified owner's; Claude's --resume keeps that session ID.
// The account is the running process's own CLAUDE_CONFIG_DIR, exactly as set
// or unset: an explicit ~/.claude reads another .claude.json than the default.
// ConfigDir is that exact override ("" = provider default) so a later plan can
// prove the resumed process kept it. The caller fences input against Owner.
func ReadClaudePaneResumePlan(pane, expected string) (CodexPaneResumePlan, error) {
	var empty CodexPaneResumePlan
	if !validSessionID.MatchString(pane) || !nativeClaudeSessionID.MatchString(expected) {
		return empty, errors.New("exact pane and session UUIDs required")
	}
	owner, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || owner.Provider != "claude" || owner.SessionID != expected || owner.InputOnly {
		return empty, errors.New("original Claude prompt owner changed or unavailable")
	}
	override, err := agentConfigOverride(owner.ProcessID, "claude")
	if err != nil {
		return empty, errors.New("original Claude account unavailable")
	}
	root := override
	if root == "" {
		if root, err = defaultAgentConfigRoot("claude"); err != nil {
			return empty, err
		}
	}
	path, err := nativeClaudeTranscript(root, expected)
	if err != nil || path == "" {
		return empty, errors.New("saved session is missing or ambiguous in the original account")
	}
	file, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return empty, err
	}
	defer file.Close()
	before, err := file.Stat()
	current, lerr := os.Lstat(path)
	if err != nil || lerr != nil || !before.Mode().IsRegular() || !os.SameFile(before, current) || current.Mode()&os.ModeSymlink != 0 {
		return empty, errors.New("saved session source changed")
	}
	// The located transcript must be the one the live owner is bound to.
	if stat, ok := before.Sys().(*syscall.Stat_t); !ok || fmt.Sprintf("%d:%d", stat.Dev, stat.Ino) != owner.TranscriptIdentity {
		return empty, errors.New("saved session is not the pane's bound transcript")
	}
	cwd, err := claudeTranscriptDirectory(file, expected)
	if err != nil {
		return empty, err
	}
	live, err := processWorkingDirectory(owner.ProcessID)
	if err != nil || verifyNativeDirectoryEvidence(cwd, nil, live) != nil {
		return empty, errors.New("saved session is outside this pane's project")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return empty, err
	}
	shim := filepath.Join(home, ".local", "share", "relay", "shims", "claude")
	info, err := os.Stat(shim)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return empty, errors.New("managed Claude launcher unavailable")
	}
	command, err := claudePaneResumeCommand(cwd, override, shim, expected)
	if err != nil {
		return empty, err
	}
	after, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || after != owner {
		return empty, errors.New("original Claude owner changed during admission")
	}
	return CodexPaneResumePlan{Owner: owner, Session: expected, Directory: cwd, ConfigDir: override, Command: command}, nil
}

// claudeTranscriptDirectory is the session's recorded project directory: the
// first bounded record of exactly this session that names one.
func claudeTranscriptDirectory(file *os.File, session string) (string, error) {
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for count := 0; count < 4000 && scanner.Scan(); count++ {
		var record struct {
			SessionID string `json:"sessionId"`
			Cwd       string `json:"cwd"`
		}
		if json.Unmarshal(scanner.Bytes(), &record) != nil || record.SessionID != session || record.Cwd == "" {
			continue
		}
		if !filepath.IsAbs(record.Cwd) || filepath.Clean(record.Cwd) != record.Cwd {
			return "", errors.New("saved session directory is invalid")
		}
		return record.Cwd, nil
	}
	return "", errors.New("saved session metadata unavailable")
}

// claudePaneResumeCommand selects the account exactly as the original process
// had it: the same CLAUDE_CONFIG_DIR value, or the variable unset.
func claudePaneResumeCommand(cwd, override, shim, session string) (string, error) {
	if !filepath.IsAbs(cwd) || !filepath.IsAbs(shim) || !nativeClaudeSessionID.MatchString(session) {
		return "", errors.New("invalid Claude resume plan")
	}
	account := "env -u CLAUDE_CONFIG_DIR"
	if override != "" {
		if !filepath.IsAbs(override) || filepath.Clean(override) != override {
			return "", errors.New("original Claude account directory is invalid")
		}
		account = "CLAUDE_CONFIG_DIR=" + shellQuote(override)
	}
	return "cd -- " + shellQuote(cwd) + " && " + account + " " + shellQuote(shim) + " --resume " + shellQuote(session), nil
}
