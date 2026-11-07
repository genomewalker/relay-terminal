package peernet

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// SenderPermissionClass reports "bypass", "prompting" or "" (unknown) for a
// live harness process and its native session. Callers must have bound the
// PID to its pane already; the start is captured here and rechecked below.
func SenderPermissionClass(home string, pid int, session string) string {
	if pid <= 1 || session == "" || strings.ContainsAny(session, "/*?[\\") {
		return ""
	}
	start, err := processStart(pid)
	if err != nil || start == "" {
		return ""
	}
	return runtimePermissionClass(home, Record{PID: pid, Start: start, Session: session})
}

// Runtime permission changes supersede initial launch flags. Unknown stays
// unasserted; neither the destination nor message content determines this mode.
func runtimePermissionClass(home string, target Record) string {
	if start, err := processStart(target.PID); err != nil || start != target.Start {
		return ""
	}
	codex, _ := filepath.Glob(filepath.Join(codexConfig(home, target.PID), "sessions/*/*/*/rollout-*-"+target.Session+".jsonl"))
	var claude []string
	if config, err := claudeConfig(home, target.PID); err == nil {
		claude, _ = filepath.Glob(filepath.Join(config, "projects/*/"+target.Session+".jsonl"))
	}
	mode := ""
	hasRuntimeMode := false
	paths := codex
	if len(codex) != 1 {
		paths = claude
	}
	if len(paths) == 1 {
		info, err := os.Lstat(paths[0])
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
			return ""
		}
		// The seek bounds allocation and parsing on long sessions.
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(owner.Uid) != os.Getuid() {
			return ""
		}
		file, err := os.Open(paths[0])
		if err != nil {
			return ""
		}
		const limit = int64(8 << 20)
		if info.Size() > limit {
			_, err = file.Seek(info.Size()-limit, io.SeekStart)
		}
		data, readErr := io.ReadAll(io.LimitReader(file, limit))
		file.Close()
		if err != nil || readErr != nil {
			return ""
		}
		lines := bytes.Split(data, []byte("\n"))
		for i := len(lines) - 1; i >= 0; i-- {
			var row struct {
				Type    string `json:"type"`
				Session string `json:"sessionId"`
				Mode    string `json:"permissionMode"`
				Payload struct {
					Approval string `json:"approval_policy"`
					Sandbox  struct {
						Type string `json:"type"`
					} `json:"sandbox_policy"`
				} `json:"payload"`
			}
			if json.Unmarshal(lines[i], &row) != nil {
				continue
			}
			if len(codex) == 1 && row.Type == "turn_context" {
				hasRuntimeMode = true
				if row.Payload.Approval == "never" && row.Payload.Sandbox.Type == "danger-full-access" {
					mode = "bypass"
				}
				switch row.Payload.Approval {
				case "on-request", "on-failure", "untrusted":
					mode = "prompting"
				}
				break
			}
			if len(codex) != 1 && row.Type == "permission-mode" && row.Session == target.Session {
				hasRuntimeMode = true
				mode = claudePermissionClass(row.Mode)
				break
			}
		}
	}
	if mode == "" && !hasRuntimeMode {
		var args []string
		if runtime.GOOS == "linux" {
			data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(target.PID), "cmdline"))
			if err == nil {
				args = strings.Split(string(data), "\x00")
			}
		} else {
			data, err := exec.Command("/bin/ps", "-p", strconv.Itoa(target.PID), "-o", "args=").Output()
			if err == nil {
				args = strings.Fields(string(data))
			}
		}
		mode = launchPermissionClass(home, args)
	}
	if start, err := processStart(target.PID); err != nil || start != target.Start {
		return ""
	}
	return mode
}

// launchPermissionClass reads only explicit launch flags. The native
// installer runs Claude as ~/.local/share/claude/versions/<v>, so argv[0] is
// that path rather than "claude". Claude applies --dangerously-skip-permissions
// and --permission-mode in order (the last wins) and falls back to
// --inherit-permission-mode; settings files are not read, so a mode set only
// there stays unknown.
func launchPermissionClass(home string, args []string) string {
	if len(args) == 0 {
		return ""
	}
	switch launchHarness(home, args[0]) {
	case "claude":
		return claudeLaunchPermissionClass(args[1:])
	case "codex":
		for _, arg := range args[1:] {
			if arg == "--dangerously-bypass-approvals-and-sandbox" {
				return "bypass"
			}
		}
	}
	return ""
}

func claudeLaunchPermissionClass(args []string) string {
	explicit, inherited := "", ""
	for i := 0; i < len(args); i++ {
		name, value, inline := strings.Cut(args[i], "=")
		next := func() string {
			if inline {
				return value
			}
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch {
		case args[i] == "--":
			i = len(args)
		case args[i] == "--dangerously-skip-permissions":
			explicit = "bypassPermissions"
		case name == "--permission-mode":
			explicit = next()
		case name == "--inherit-permission-mode":
			inherited = next()
		}
	}
	mode := explicit
	if mode == "" {
		mode = inherited
	}
	return claudePermissionClass(mode)
}

// claudePermissionClass maps Claude's permission modes to the inbound policy's
// two classes; an unrecognised mode is unknown, never guessed. Claude counts
// plan as bypass for an interactive session with bypass available, which can
// come from settings as well as flags, so plan is never asserted.
func claudePermissionClass(mode string) string {
	switch mode {
	case "bypassPermissions":
		return "bypass"
	case "default", "acceptEdits":
		return "prompting"
	}
	return ""
}

func launchHarness(home, executable string) string {
	switch base := filepath.Base(executable); base {
	case "claude", "codex":
		return base
	}
	if !filepath.IsAbs(executable) || !filepath.IsAbs(home) {
		return ""
	}
	versions, err := filepath.EvalSymlinks(filepath.Join(home, ".local", "share", "claude", "versions"))
	if err != nil {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return ""
	}
	if info, err := os.Stat(resolved); err == nil && info.Mode().IsRegular() &&
		filepath.Dir(resolved) == versions && filepath.Base(resolved) == filepath.Base(executable) {
		return "claude"
	}
	return ""
}
