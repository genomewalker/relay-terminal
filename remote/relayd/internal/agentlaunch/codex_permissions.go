package agentlaunch

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// CodexPermissions are the sandbox and approval policy a Codex thread last
// ran with, as recorded by its rollout. Official Codex rejects permission
// flags on a --remote resume, so a resumed thread otherwise falls back to the
// app server's configured defaults.
type CodexPermissions struct {
	SandboxMode    string `json:"sandbox_mode"`
	ApprovalPolicy string `json:"approval_policy"`
}

var codexSandboxModes = map[string]bool{"danger-full-access": true, "workspace-write": true, "read-only": true}
var codexApprovalPolicies = map[string]bool{"never": true, "on-request": true, "on-failure": true, "untrusted": true}

// CodexResumedThread returns the exact thread a TUI launch resumes. Launches
// that choose their own permissions are left to Codex unchanged.
func CodexResumedThread(argv []string) (string, bool) {
	thread := ""
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		flag, _, _ := strings.Cut(arg, "=")
		switch flag {
		case "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--sandbox", "-s", "--ask-for-approval", "-a", "--approval-policy", "--permissions":
			return "", false
		case "-c", "--config":
			value := ""
			if _, inline, ok := strings.Cut(arg, "="); ok && flag == "--config" {
				value = inline
			} else if i+1 < len(argv) {
				i++
				value = argv[i]
			}
			key, _, _ := strings.Cut(value, "=")
			key = strings.TrimSpace(key)
			if key == "sandbox_mode" || key == "approval_policy" || strings.HasPrefix(key, "sandbox_") {
				return "", false
			}
		case "--model", "-m", "--profile", "-p", "--cd", "-C", "--add-dir", "--enable", "--disable", "--image", "-i", "--reasoning-effort", "--remote", "--remote-auth-token-env":
			if !strings.Contains(arg, "=") {
				i++
			}
		case "--":
			return thread, thread != ""
		case "resume":
			if thread != "" || i+1 >= len(argv) || !sessionUUID.MatchString(argv[i+1]) {
				return "", false
			}
			i++
			thread = argv[i]
		}
	}
	return thread, thread != ""
}

// SavedCodexPermissions reads the last turn context of one exact thread's
// rollout under codexHome. It returns an error unless exactly one owned
// rollout names the thread and records known permission values.
func SavedCodexPermissions(codexHome, threadID string) (CodexPermissions, error) {
	if !sessionUUID.MatchString(threadID) || !filepath.IsAbs(codexHome) {
		return CodexPermissions{}, errors.New("invalid Codex thread")
	}
	var found string
	visited := 0
	err := filepath.WalkDir(filepath.Join(codexHome, "sessions"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		visited++
		if visited > 100000 {
			return errors.New("Codex rollout search exceeds bound")
		}
		if entry.Type().IsRegular() && strings.HasPrefix(entry.Name(), "rollout-") && strings.HasSuffix(entry.Name(), "-"+threadID+".jsonl") {
			if found != "" {
				return errors.New("ambiguous Codex rollout")
			}
			found = path
		}
		return nil
	})
	if err != nil {
		return CodexPermissions{}, err
	}
	if found == "" {
		return CodexPermissions{}, errors.New("Codex rollout unavailable")
	}
	info, err := os.Lstat(found)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 256<<20 {
		return CodexPermissions{}, errors.New("Codex rollout unavailable or too large")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
		return CodexPermissions{}, errors.New("Codex rollout owner changed")
	}
	file, err := os.Open(found)
	if err != nil {
		return CodexPermissions{}, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	var latest *CodexPermissions
	metaSeen := false
	for scanner.Scan() {
		var item struct {
			Type    string `json:"type"`
			Payload struct {
				ID             string `json:"id"`
				ApprovalPolicy string `json:"approval_policy"`
				SandboxPolicy  struct {
					Type string `json:"type"`
				} `json:"sandbox_policy"`
			} `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &item) != nil {
			continue
		}
		switch item.Type {
		case "session_meta":
			if metaSeen || item.Payload.ID != threadID {
				return CodexPermissions{}, errors.New("Codex rollout identity mismatch")
			}
			metaSeen = true
		case "turn_context":
			latest = &CodexPermissions{SandboxMode: item.Payload.SandboxPolicy.Type, ApprovalPolicy: item.Payload.ApprovalPolicy}
		}
	}
	if err := scanner.Err(); err != nil {
		return CodexPermissions{}, err
	}
	if !metaSeen || latest == nil {
		return CodexPermissions{}, errors.New("Codex rollout records no permissions")
	}
	if !codexSandboxModes[latest.SandboxMode] || !codexApprovalPolicies[latest.ApprovalPolicy] {
		return CodexPermissions{}, errors.New("Codex rollout records unknown permissions")
	}
	return *latest, nil
}

// CodexHome is the Codex state directory a process with this environment
// uses. A relative CODEX_HOME is ignored rather than resolved.
func CodexHome(environment []string) string {
	for i := len(environment) - 1; i >= 0; i-- {
		if value, ok := strings.CutPrefix(environment[i], "CODEX_HOME="); ok && filepath.IsAbs(value) {
			return value
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

// AppServerArguments are config overrides that make an app server apply the
// saved permissions to the resumed thread.
func (p CodexPermissions) AppServerArguments() []string {
	if !codexSandboxModes[p.SandboxMode] || !codexApprovalPolicies[p.ApprovalPolicy] {
		return nil
	}
	return []string{"-c", `sandbox_mode="` + p.SandboxMode + `"`, "-c", `approval_policy="` + p.ApprovalPolicy + `"`}
}
