package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"os"
	"path/filepath"
	"strings"
)

// CodexPaneResumePlan is read-only admission for an explicit same-pane resume.
// The caller must fence terminal input against Owner again at dispatch.
type CodexPaneResumePlan struct {
	Owner     PromptOwnerBinding `json:"owner"`
	Session   string             `json:"session_id"`
	Directory string             `json:"directory"`
	Command   string             `json:"command"`
	ConfigDir string             `json:"config_dir"`
}

func ReadCodexPaneResumePlan(pane, expected, target string) (CodexPaneResumePlan, error) {
	var empty CodexPaneResumePlan
	if !validSessionID.MatchString(pane) || !validSessionID.MatchString(expected) || !validSessionID.MatchString(target) {
		return empty, newPaneRefusal(PaneRefusalInvalidRequest, "exact pane and session UUIDs required")
	}
	owner, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || owner.Provider != "codex" || owner.SessionID != expected || owner.InputOnly {
		return empty, newPaneRefusal(PaneRefusalIdentityUnavailable, "original Codex prompt owner changed or unavailable")
	}
	config, err := agentConfigRoot(owner.ProcessID, "codex")
	if err != nil {
		return empty, newPaneRefusal(PaneRefusalIdentityUnavailable, "original Codex account unavailable")
	}
	config, err = filepath.EvalSymlinks(config)
	if err != nil {
		return empty, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return empty, err
	}
	if refusal := codexLoginRefusal(home, config); refusal != "" {
		return empty, newPaneRefusal(PaneRefusalLoginMismatch, refusal)
	}
	path, err := exactCodexResumeTranscript(config, target)
	if err != nil {
		return empty, err
	}
	file, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return empty, err
	}
	defer file.Close()
	before, err := file.Stat()
	current, lerr := os.Lstat(path)
	if err != nil || lerr != nil || !before.Mode().IsRegular() || !os.SameFile(before, current) || current.Mode()&os.ModeSymlink != 0 {
		return empty, newPaneRefusal(PaneRefusalPaneChanged, "saved session source changed")
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		return empty, newPaneRefusal(PaneRefusalResumeUnavailable, "saved session metadata unavailable")
	}
	session, _, kind, err := nativeCodexOpenTranscriptMetadata(scanner.Bytes())
	var metadata struct {
		Payload struct {
			CWD string `json:"cwd"`
		} `json:"payload"`
	}
	if err != nil || session != target || kind != "root" || json.Unmarshal(scanner.Bytes(), &metadata) != nil || !filepath.IsAbs(metadata.Payload.CWD) {
		return empty, newPaneRefusal(PaneRefusalResumeUnavailable, "saved session identity mismatch")
	}
	cwd := metadata.Payload.CWD
	live, err := processWorkingDirectory(owner.ProcessID)
	if err != nil || verifyNativeDirectoryEvidence(cwd, nil, live) != nil {
		return empty, newPaneRefusal(PaneRefusalOutsideProject, "saved session is outside this pane's project")
	}
	// Pre-exit: a relaunch that would stop at Codex's folder-trust dialog is
	// refused while the original agent still runs (case 10, 7b68ee70).
	if trust := agentaccounts.CodexProjectTrust(config, cwd); trust.Status == agentaccounts.CodexTrustParentOnly ||
		trust.Status == agentaccounts.CodexTrustUntrusted {
		return empty, newPaneRefusal(PaneRefusalTrustPrompt, "Codex folder trust required for "+cwd+" ("+trust.Status+")")
	}
	shim := filepath.Join(home, ".local", "share", "relay", "shims", "codex")
	info, err := os.Stat(shim)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return empty, newPaneRefusal(PaneRefusalLauncherUnavailable, "managed Codex launcher unavailable")
	}
	after, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || after != owner {
		return empty, newPaneRefusal(PaneRefusalPaneChanged, "original Codex owner changed during admission")
	}
	return CodexPaneResumePlan{Owner: owner, Session: target, Directory: cwd, ConfigDir: config,
		Command: "cd -- " + shellQuote(cwd) + " && CODEX_HOME=" + shellQuote(config) + " " + shellQuote(shim) + " resume " + shellQuote(target)}, nil
}

func exactCodexResumeTranscript(config, session string) (string, error) {
	if !validSessionID.MatchString(session) {
		return "", errors.New("invalid saved session UUID")
	}
	matches, err := filepath.Glob(filepath.Join(config, "sessions", "*", "*", "*", "*"+session+".jsonl"))
	if err != nil || len(matches) != 1 || !strings.HasSuffix(filepath.Base(matches[0]), "-"+session+".jsonl") {
		return "", errors.New("saved session is missing or ambiguous in the original account")
	}
	return matches[0], nil
}
