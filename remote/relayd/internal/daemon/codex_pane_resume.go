package daemon

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"io"
	"os"
	"path/filepath"
	"regexp"
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
	// Only the observed case is refused before exit: a non-git folder
	// trusted through its parent alone. Other states are left to the
	// post-launch dialog check rather than held on a guess.
	if trust := agentaccounts.CodexProjectTrust(config, cwd); trust.Status == agentaccounts.CodexTrustParentOnly {
		return "", "", newPaneRefusal(PaneRefusalTrustPrompt, "Codex folder trust required for "+cwd+" ("+trust.Status+")")
	}
	shim := filepath.Join(home, ".local", "share", "relay", "shims", "codex")
	info, err := os.Stat(shim)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return "", "", newPaneRefusal(PaneRefusalLauncherUnavailable, "managed Codex launcher unavailable")
	}
	// Resume keeps the session's own model and effort. Without them Codex
	// falls back to the account default, which may have changed since.
	// The scanner above buffered past the first record; read from the start.
	flags := ""
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", "", newPaneRefusal(PaneRefusalResumeUnavailable, "saved session unreadable")
	}
	if model, effort := lastCodexTurnModel(bufio.NewReaderSize(file, 64<<10)); model != "" {
		flags = " -m " + shellQuote(model)
		if effort != "" {
			flags += " -c " + shellQuote("model_reasoning_effort="+effort)
		}
	}
	return cwd, "cd -- " + shellQuote(cwd) + " && CODEX_HOME=" + shellQuote(config) + " " + shellQuote(shim) + " resume" + flags + " " + shellQuote(target), nil
}

var (
	codexModelPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	codexEffortPattern = regexp.MustCompile(`^[a-z]{1,16}$`)
)

// lastCodexTurnModel returns the model and reasoning effort of the last
// turn_context record in the rest of a rollout. Oversized lines are skipped;
// values outside a strict charset are dropped rather than quoted onward.
func lastCodexTurnModel(reader *bufio.Reader) (string, string) {
	const limit = 4 << 20
	model, effort := "", ""
	var line []byte
	for {
		chunk, isPrefix, err := reader.ReadLine()
		if err != nil {
			break
		}
		if len(line)+len(chunk) <= limit {
			line = append(line, chunk...)
		} else {
			line = line[:0:0]
			for isPrefix {
				if _, isPrefix, err = reader.ReadLine(); err != nil {
					return model, effort
				}
			}
			continue
		}
		if isPrefix {
			continue
		}
		if bytes.Contains(line, []byte(`"turn_context"`)) {
			var record struct {
				Type    string `json:"type"`
				Payload struct {
					Model  string `json:"model"`
					Effort string `json:"effort"`
				} `json:"payload"`
			}
			if json.Unmarshal(line, &record) == nil && record.Type == "turn_context" && codexModelPattern.MatchString(record.Payload.Model) {
				model, effort = record.Payload.Model, ""
				if codexEffortPattern.MatchString(record.Payload.Effort) {
					effort = record.Payload.Effort
				}
			}
		}
		line = line[:0]
	}
	return model, effort
}

// codexManagedRouteRefusal is the pre-exit check for a pane under the managed
// Codex backend (case 7db531e6): its proxy descriptor must name this pane and
// an absolute frontend socket, the same precondition maintenance's restart
// has, or the pane is not exited because it could not be relaunched the same way.
// codexOutsideProxyMessage is the refusal for a Codex frontend attached
// directly to Codex's own app-server daemon (the one Codex desktop shares),
// not through Relay's per-pane proxy (case 0173baf5: 0.167.0 frontend,
// managed daemon 0.170.0, holding a desktop task). Relaunching it through
// Relay would move the conversation off that daemon while it still holds it.
const codexOutsideProxyMessage = "This Codex runs outside Relay's proxy, attached directly to Codex's own app-server daemon (shared with Codex desktop); Relay does not exit or relaunch it."

// codexOutsideProxy reports whether the pane's Codex is bound through the
// native daemon endpoint without a Relay proxy. Replaceable in tests.
var codexOutsideProxy = func(pane string) bool {
	if _, err := readStockCodexProxyBinding(pane); !errors.Is(err, errNoStockCodexProxy) {
		return false
	}
	binding, err := ReadNativeCodexBinding(pane)
	return err == nil && binding.Source == "native_runtime_mcp_origin" && binding.NativeEndpoint != nil
}

func codexOutsideProxyRefusal(pane string) *PaneRefusal {
	if codexOutsideProxy(pane) {
		return newPaneRefusal(PaneRefusalOutsideProxy, codexOutsideProxyMessage)
	}
	return nil
}

func codexManagedRouteRefusal(pane string) *PaneRefusal {
	if refusal := codexOutsideProxyRefusal(pane); refusal != nil {
		return refusal
	}
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
