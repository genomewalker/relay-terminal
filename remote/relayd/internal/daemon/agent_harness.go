package daemon

import (
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"
)

type HarnessProcess struct {
	Provider string `json:"provider"`
	PID      int    `json:"pid"`
	Start    string `json:"process_start"`
}

type PaneHarnessIdentity struct {
	PaneID    string           `json:"pane_id"`
	Role      string           `json:"role"`
	Provider  string           `json:"provider,omitempty"`
	Processes []HarnessProcess `json:"processes"`
	Reason    string           `json:"reason,omitempty"`
}

type PaneHarnessReport struct {
	Version    int                   `json:"version"`
	ObservedAt time.Time             `json:"observed_at"`
	Panes      []PaneHarnessIdentity `json:"panes"`
}

// Identify existing workers only. No terminal input, provider session mutation,
// transcript inference or messaging authority is derived from this report.
func ReadPaneHarnesses(panes []string) (PaneHarnessReport, error) {
	report := PaneHarnessReport{Version: 1, ObservedAt: time.Now().UTC(), Panes: []PaneHarnessIdentity{}}
	if len(panes) == 0 || len(panes) > 128 {
		return report, errors.New("expected 1 to 128 existing panes")
	}
	server := NewServer()
	seen := map[string]bool{}
	for _, pane := range panes {
		if !validSessionID.MatchString(pane) {
			return report, errors.New("invalid pane")
		}
		if seen[pane] {
			continue
		}
		seen[pane] = true
		identity := PaneHarnessIdentity{PaneID: pane, Role: "unavailable", Processes: []HarnessProcess{}}
		manifest, err := loadManifest(server.manifestPath(pane))
		if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
			identity.Reason = "Existing pane worker unavailable"
			report.Panes = append(report.Panes, identity)
			continue
		}
		before, err := processStartTime(manifest.ShellPID)
		if err != nil {
			identity.Reason = "Pane process unavailable"
			report.Panes = append(report.Panes, identity)
			continue
		}
		foreground, err := harnessForegroundGroup(manifest.ShellPID)
		if err != nil || foreground <= 0 {
			identity.Reason = "Foreground process identity unavailable"
			report.Panes = append(report.Panes, identity)
			continue
		}
		candidates := map[int]HarnessProcess{}
		ancestors := map[int][]int{}
		for pid, provider := range descendantAgentProcesses(manifest.ShellPID) {
			group, groupErr := harnessProcessGroup(pid)
			if groupErr != nil || group != foreground {
				continue
			}
			start, startErr := processStartTime(pid)
			wireStart, wireErr := processStartIdentity(pid)
			if startErr != nil || wireErr != nil {
				continue
			}
			chain, chainErr := networkAncestors(pid, wireStart)
			after, afterErr := processStartTime(pid)
			if chainErr != nil || afterErr != nil || start != after || !harnessChainContains(chain, manifest.ShellPID) {
				continue
			}
			candidates[pid] = HarnessProcess{Provider: provider, PID: pid, Start: "kernel:" + strconv.FormatUint(start, 10)}
			ancestors[pid] = chain
		}
		identity.Processes = outerHarnessProcesses(candidates, ancestors)
		after, afterErr := processStartTime(manifest.ShellPID)
		afterForeground, foregroundErr := harnessForegroundGroup(manifest.ShellPID)
		if afterErr != nil || before != after || foregroundErr != nil || afterForeground != foreground || validateWorkerIdentity(manifest) != nil {
			identity.Processes = []HarnessProcess{}
			identity.Reason = "Pane process changed during identification"
		} else if len(identity.Processes) == 0 {
			identity.Role = "shell"
			identity.Provider = "shell"
		} else if len(identity.Processes) == 1 {
			identity.Role = "harness"
			identity.Provider = identity.Processes[0].Provider
		} else {
			identity.Role = "multiple"
		}
		report.Panes = append(report.Panes, identity)
	}
	return report, nil
}

func harnessChainContains(chain []int, pid int) bool {
	for _, member := range chain {
		if member == pid {
			return true
		}
	}
	return false
}

// A tool or subagent below the foreground CLI does not replace its harness.
func outerHarnessProcesses(candidates map[int]HarnessProcess, ancestors map[int][]int) []HarnessProcess {
	roots := []HarnessProcess{}
	for pid, candidate := range candidates {
		nested := false
		for _, parent := range ancestors[pid] {
			if parent != pid {
				if _, exists := candidates[parent]; exists {
					nested = true
					break
				}
			}
		}
		if !nested {
			roots = append(roots, candidate)
		}
	}
	sort.Slice(roots, func(i, j int) bool { return roots[i].PID < roots[j].PID })
	return roots
}

func harnessCommandName(command string) string {
	command = strings.ToLower(strings.TrimSpace(command))
	switch command {
	case "claude", "codex", "gemini", "opencode", "aider", "goose", "amp", "droid", "copilot", "cursor-agent", "crush", "qwen", "pi":
		return command
	}
	return ""
}

func harnessInterpreter(command string) bool {
	return command == "node" || command == "nodejs" || command == "bun" || command == "deno" || command == "python" || command == "python3" || strings.HasPrefix(command, "python3.") || command == "uv" || command == "uvx"
}

// Inspect executable/entrypoint positions, never prompts or arbitrary arguments.
func classifyHarnessProcess(command, arguments string) string {
	command = strings.ToLower(strings.TrimSpace(command))
	if provider := harnessCommandName(command); provider != "" {
		return provider
	}
	// The native Claude updater stores executables under their version name.
	// An exact pinned exec then has comm=2.1.301 while argv[0] remains claude.
	// This identifies a candidate only; the native binding still verifies its
	// process incarnation, ancestry and provider conversation independently.
	if versionNamedClaudeProcess(command, arguments) {
		return "claude"
	}
	if !harnessInterpreter(command) {
		return ""
	}
	var args []string
	if strings.Contains(arguments, "\x00") {
		args = strings.Split(strings.TrimRight(arguments, "\x00"), "\x00")
	} else {
		args = strings.Fields(arguments)
	}
	if len(args) == 0 {
		return ""
	}
	base := func(s string) string {
		parts := strings.Split(strings.TrimRight(strings.ToLower(s), "/"), "/")
		return parts[len(parts)-1]
	}
	if provider := harnessCommandName(base(args[0])); provider != "" {
		return provider
	}
	for i := 1; i < len(args) && i < 16; i++ {
		arg := strings.ToLower(args[i])
		if arg == "-c" || arg == "-e" || arg == "--eval" || arg == "-p" || arg == "--print" {
			return ""
		}
		if arg == "-m" && strings.HasPrefix(command, "python") {
			if i+1 < len(args) && (args[i+1] == "aider" || strings.HasPrefix(args[i+1], "aider.")) {
				return "aider"
			}
			return ""
		}
		switch arg {
		case "-r", "--require", "--import", "--loader", "--experimental-loader", "--conditions", "--inspect-port", "-w", "-x":
			if i+1 >= len(args) {
				return ""
			}
			i++
			continue
		}
		if strings.HasPrefix(arg, "-") {
			continue
		}
		if provider := harnessCommandName(base(arg)); provider != "" {
			return provider
		}
		for _, pattern := range []struct{ path, provider string }{
			{"/@anthropic-ai/claude-code/", "claude"}, {"/@openai/codex/", "codex"},
			{"/@google/gemini-cli/", "gemini"}, {"/@github/copilot/", "copilot"},
			{"/@qwen-code/qwen-code/", "qwen"}, {"/@mariozechner/pi-coding-agent/", "pi"},
		} {
			if strings.Contains(arg, pattern.path) {
				return pattern.provider
			}
		}
		return ""
	}
	return ""
}

func versionNamedClaudeProcess(command, arguments string) bool {
	parts := strings.Split(command, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" {
			return false
		}
		for _, digit := range part {
			if digit < '0' || digit > '9' {
				return false
			}
		}
	}
	if strings.Contains(arguments, "\x00") {
		return strings.SplitN(arguments, "\x00", 2)[0] == "claude"
	}
	args := strings.Fields(arguments)
	return len(args) > 0 && args[0] == "claude"
}
