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
	if refusal := codexManagedRouteRefusal(pane); refusal != nil {
		return empty, refusal
	}
	cwd, command, err := codexRelaunchCommand(home, config, target)
	if err != nil {
		return empty, err
	}
	live, err := processWorkingDirectory(owner.ProcessID)
	if err != nil || verifyNativeDirectoryEvidence(cwd, nil, live) != nil {
		return empty, newPaneRefusal(PaneRefusalOutsideProject, "saved session is outside this pane's project")
	}
	after, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || after != owner {
		return empty, newPaneRefusal(PaneRefusalPaneChanged, "original Codex owner changed during admission")
	}
	return CodexPaneResumePlan{Owner: owner, Session: target, Directory: cwd, ConfigDir: config, Command: command}, nil
}

// codexRelaunchCommand is the exact relaunch of saved session target from
// account config: its recorded directory and the managed launcher. It refuses
// a relaunch that cannot start cleanly, before any exit is sent.
func codexRelaunchCommand(home, config, target string) (string, string, error) {
	path, err := exactCodexResumeTranscript(config, target)
	if err != nil {
		return "", "", newPaneRefusal(PaneRefusalResumeUnavailable, err.Error())
	}
	file, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return "", "", err
	}
	defer file.Close()
	before, err := file.Stat()
	current, lerr := os.Lstat(path)
	if err != nil || lerr != nil || !before.Mode().IsRegular() || !os.SameFile(before, current) || current.Mode()&os.ModeSymlink != 0 {
		return "", "", newPaneRefusal(PaneRefusalPaneChanged, "saved session source changed")
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		return "", "", newPaneRefusal(PaneRefusalResumeUnavailable, "saved session metadata unavailable")
	}
	session, _, kind, err := nativeCodexOpenTranscriptMetadata(scanner.Bytes())
	var metadata struct {
		Payload struct {
			CWD string `json:"cwd"`
		} `json:"payload"`
	}
	if err != nil || session != target || kind != "root" || json.Unmarshal(scanner.Bytes(), &metadata) != nil || !filepath.IsAbs(metadata.Payload.CWD) {
		return "", "", newPaneRefusal(PaneRefusalResumeUnavailable, "saved session identity mismatch")
	}
	cwd := metadata.Payload.CWD
	// A relaunch that would stop at Codex's folder-trust dialog is refused
	// while the original agent still runs (case 10, 7b68ee70).
	if trust := agentaccounts.CodexProjectTrust(config, cwd); trust.Status == agentaccounts.CodexTrustParentOnly ||
		trust.Status == agentaccounts.CodexTrustUntrusted {
		return "", "", newPaneRefusal(PaneRefusalTrustPrompt, "Codex folder trust required for "+cwd+" ("+trust.Status+")")
	}
	shim := filepath.Join(home, ".local", "share", "relay", "shims", "codex")
	info, err := os.Stat(shim)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return "", "", newPaneRefusal(PaneRefusalLauncherUnavailable, "managed Codex launcher unavailable")
	}
	return cwd, "cd -- " + shellQuote(cwd) + " && CODEX_HOME=" + shellQuote(config) + " " + shellQuote(shim) + " resume " + shellQuote(target), nil
}

// codexManagedRouteRefusal is the pre-exit check for a pane under the managed
// Codex backend (case 7db531e6): its proxy descriptor must name this pane and
// an absolute frontend socket, the same precondition maintenance's restart
// has, or the pane is not exited because it could not be relaunched the same way.
func codexManagedRouteRefusal(pane string) *PaneRefusal {
	path := filepath.Join(phWorkerStateDirectory(), "relay/workers/codex-proxies", pane, "descriptor.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	var descriptor struct {
		Pane           string `json:"pane"`
		FrontendSocket string `json:"frontend_socket"`
	}
	if err != nil || len(data) > 64<<10 || json.Unmarshal(data, &descriptor) != nil || descriptor.Pane != pane ||
		!filepath.IsAbs(descriptor.FrontendSocket) {
		return newPaneRefusal(PaneRefusalRelaunchUnavailable, "The managed frontend route is unavailable.")
	}
	return nil
}

// ReadCodexPaneRelaunchPlan is same-pane recovery for a Codex pane whose
// agent already exited and left its retained shell (a resume held after
// "Exit submitted", case 7db531e6). The pane's owner must now be that shell;
// config is the original plan's account, so the session resumes there. The
// caller fences the launch input against Owner, the shell.
func ReadCodexPaneRelaunchPlan(pane, target, config string) (CodexPaneResumePlan, error) {
	var empty CodexPaneResumePlan
	if !validSessionID.MatchString(pane) || !validSessionID.MatchString(target) || !filepath.IsAbs(config) || filepath.Clean(config) != config {
		return empty, newPaneRefusal(PaneRefusalInvalidRequest, "exact pane, session UUID and absolute account directory required")
	}
	owner, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || owner.Provider != "shell" {
		return empty, newPaneRefusal(PaneRefusalIdentityUnavailable, "the pane's retained shell does not own the prompt (an agent may still run); use an ordinary resume")
	}
	resolved, err := filepath.EvalSymlinks(config)
	if err != nil || resolved != config {
		return empty, newPaneRefusal(PaneRefusalIdentityUnavailable, "original Codex account unavailable")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return empty, err
	}
	if refusal := codexLoginRefusal(home, config); refusal != "" {
		return empty, newPaneRefusal(PaneRefusalLoginMismatch, refusal)
	}
	if refusal := codexManagedRouteRefusal(pane); refusal != nil {
		return empty, refusal
	}
	cwd, command, err := codexRelaunchCommand(home, config, target)
	if err != nil {
		return empty, err
	}
	after, err := ReadVerifiedPromptOwnerBinding(pane)
	if err != nil || after != owner {
		return empty, newPaneRefusal(PaneRefusalPaneChanged, "the retained shell changed during admission")
	}
	return CodexPaneResumePlan{Owner: owner, Session: target, Directory: cwd, ConfigDir: config, Command: command}, nil
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
