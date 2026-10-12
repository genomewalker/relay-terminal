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

// Runtime permission changes supersede initial launch flags. Unknown stays
// unasserted; neither the destination nor message content determines this mode.
func runtimePermissionClass(home string, target Record) string {
	if start, err := processStart(target.PID); err != nil || start != target.Start {
		return ""
	}
	codex, _ := filepath.Glob(filepath.Join(home, ".codex/sessions/*/*/*/rollout-*-"+target.Session+".jsonl"))
	claude, _ := filepath.Glob(filepath.Join(home, ".claude/projects/*/"+target.Session+".jsonl"))
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
				switch row.Mode {
				case "bypassPermissions":
					mode = "bypass"
				case "default", "acceptEdits", "plan":
					mode = "prompting"
				}
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
		if len(args) > 0 && filepath.Base(args[0]) == "claude" {
			for _, arg := range args {
				if arg == "--dangerously-skip-permissions" {
					mode = "bypass"
				}
			}
		}
	}
	if start, err := processStart(target.PID); err != nil || start != target.Start {
		return ""
	}
	return mode
}
