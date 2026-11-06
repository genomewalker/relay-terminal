// Package researchworker plans the launch of a dedicated research worker whose
// tool policy is fixed on its command line (P2, option 1: dedicated restricted
// workers). Planning is pure: it builds argv and the files the worker needs,
// and never starts a process, reads credentials or calls a model.
//
// Enforcement levels are stated, not assumed:
//   - Claude: tools are fixed at launch (--tools "", an explicit
//     --allowedTools list, --strict-mcp-config with only the evidence reader).
//     The effective tool set has not been observed after launch, so the plan
//     says so in Unverified.
//   - Codex: --disable shell_tool removes exec_command/write_stdin from the
//     tools Codex describes to its model (checked offline with
//     `codex debug prompt-input`, Codex 0.166.0). apply_patch, the
//     collaboration (spawn_agent) tools and the code-mode exec runner remain,
//     and a hidden tool is not proven unrunnable. Codex is therefore
//     "partial" until a real, approved worker turn tries the shell and is
//     refused.
package researchworker

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const (
	ProviderClaude = "claude"
	ProviderCodex  = "codex"

	// ReaderServer is the only MCP server a worker is given.
	ReaderServer = "evidence"

	EnforcementLaunchFixed = "launch_fixed"
	EnforcementPartial     = "partial"

	// MCPConfigFile is written into the worker directory for Claude.
	MCPConfigFile = "evidence-mcp.json"
)

var (
	sha256Hex  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	modelLabel = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,127}$`)
	readerTool = regexp.MustCompile(`^[a-z][a-z0-9]*(_[a-z0-9]+)*$`) // no "__", so a name cannot carry its own mcp__ prefix

	claudeEfforts = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
	codexEfforts  = map[string]bool{"minimal": true, "low": true, "medium": true, "high": true, "xhigh": true}
)

// Claude built-in tools that must never be reachable, kept as a second fence
// behind --tools "".
var claudeDeniedTools = []string{"Bash", "BashOutput", "KillShell", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "Agent", "Skill", "SlashCommand", "TodoWrite"}

// Codex features disabled for a worker. Each is a real feature name (Codex
// rejects unknown --disable names); shell_tool is the one whose effect the
// probe test checks.
var codexDisabledFeatures = []string{"shell_tool", "multi_agent", "view_image", "image_generation", "apps", "plugins", "browser_use", "computer_use", "in_app_browser", "hooks", "skill_search", "tool_suggest", "sleep_tool"}

// CodexResidualTools are the tools Codex 0.166.0 still describes to its model
// under this plan. The probe test pins this set so a Codex update that changes
// it fails loudly.
var CodexResidualTools = []string{"apply_patch", "clock__curr_time", "list_mcp_resource_templates", "list_mcp_resources", "read_mcp_resource"}

type Reader struct {
	Command string   // absolute path of the evidence reader MCP server
	Args    []string // its arguments (e.g. the contract and allowlist paths)
	Tools   []string // reader tool names, without the mcp__evidence__ prefix
}

type Budget struct {
	Passes      int
	Retries     int
	WallSeconds int
	USD         float64
}

type Policy struct {
	Provider       string
	Executable     string // absolute path of the real provider binary, never a Relay shim
	Model          string
	Effort         string
	Cwd            string
	ContractSHA256 string
	Reader         Reader
	Budget         Budget
}

type Launch struct {
	Provider         string
	Argv             []string
	Dir              string
	Files            map[string][]byte // file name in WorkerDir -> content
	AllowedTools     []string          // fully qualified tool names the worker may call
	ScopeEnforcement string
	Residual         []string // tools still offered beyond the reader
	Unverified       []string // what this plan does not prove
	ContractSHA256   string
	Budget           Budget
}

func cleanArgument(value string) bool {
	if value == "" || len(value) > 4096 {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func absolute(path string) bool {
	return cleanArgument(path) && filepath.IsAbs(path) && filepath.Clean(path) == path
}

func validate(p Policy, workerDir string) error {
	switch {
	case p.Provider != ProviderClaude && p.Provider != ProviderCodex:
		return errors.New("provider must be claude or codex")
	case !absolute(p.Executable):
		return errors.New("executable must be a clean absolute path")
	case strings.Contains(p.Executable, "/relay/shims/"):
		return errors.New("executable is a Relay shim, not the provider binary")
	case !modelLabel.MatchString(p.Model):
		return errors.New("model is required")
	case p.Provider == ProviderClaude && !claudeEfforts[p.Effort], p.Provider == ProviderCodex && !codexEfforts[p.Effort]:
		return fmt.Errorf("effort %q is not valid for %s", p.Effort, p.Provider)
	case !absolute(p.Cwd):
		return errors.New("cwd must be a clean absolute path")
	case !absolute(workerDir):
		return errors.New("worker directory must be a clean absolute path")
	case !sha256Hex.MatchString(p.ContractSHA256):
		return errors.New("contract_sha256 must be 64 lowercase hex")
	case !absolute(p.Reader.Command):
		return errors.New("reader command must be a clean absolute path")
	case len(p.Reader.Args) > 16:
		return errors.New("too many reader arguments")
	case len(p.Reader.Tools) == 0 || len(p.Reader.Tools) > 8:
		return errors.New("reader needs 1-8 tool names")
	// Bounds match relay_research_capability's budget schema.
	case p.Budget.Passes < 1 || p.Budget.Passes > 10, p.Budget.Retries < 0 || p.Budget.Retries > 5,
		p.Budget.WallSeconds < 1 || p.Budget.WallSeconds > 3600, p.Budget.USD <= 0 || p.Budget.USD > 100:
		return errors.New("budget is outside passes 1-10, retries 0-5, wall_seconds 1-3600, usd (0,100]")
	}
	for _, arg := range p.Reader.Args {
		if !cleanArgument(arg) {
			return errors.New("reader arguments must be non-empty printable text")
		}
	}
	seen := map[string]bool{}
	for _, name := range p.Reader.Tools {
		if len(name) > 64 || !readerTool.MatchString(name) || seen[name] {
			return fmt.Errorf("reader tool %q is not a plain unique name", name)
		}
		seen[name] = true
	}
	return nil
}

// Plan returns the worker launch for p. workerDir is a private directory the
// caller creates for this one worker; Files are written there before launch.
func Plan(p Policy, workerDir string) (Launch, error) {
	if err := validate(p, workerDir); err != nil {
		return Launch{}, err
	}
	allowed := make([]string, len(p.Reader.Tools))
	for i, name := range p.Reader.Tools {
		allowed[i] = "mcp__" + ReaderServer + "__" + name
	}
	launch := Launch{Provider: p.Provider, Dir: p.Cwd, AllowedTools: allowed, ContractSHA256: p.ContractSHA256, Budget: p.Budget, Files: map[string][]byte{}}
	if p.Provider == ProviderClaude {
		config, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{ReaderServer: map[string]any{"type": "stdio", "command": p.Reader.Command, "args": append([]string{}, p.Reader.Args...)}}})
		launch.Files[MCPConfigFile] = config
		launch.Argv = []string{p.Executable, "--print", "--output-format", "json",
			"--model", p.Model, "--effort", p.Effort,
			"--tools", "",
			"--allowedTools", strings.Join(allowed, ","),
			"--disallowedTools", strings.Join(claudeDeniedTools, ","),
			"--strict-mcp-config", "--mcp-config", filepath.Join(workerDir, MCPConfigFile),
			"--setting-sources", "", "--disable-slash-commands",
			"--permission-mode", "dontAsk", "--permission-prompts", "none",
			"--max-budget-usd", strconv.FormatFloat(p.Budget.USD, 'f', -1, 64),
		}
		launch.ScopeEnforcement = EnforcementLaunchFixed
		launch.Unverified = []string{"effective Claude tool set not observed after launch", "Claude has not parsed this argv; the first approved worker launch is its first run", "passes, retries and wall_seconds are enforced by the caller, not by Claude"}
		return launch, nil
	}
	quote := func(value string) string { encoded, _ := json.Marshal(value); return string(encoded) }
	list := func(values []string) string { encoded, _ := json.Marshal(values); return string(encoded) }
	argv := []string{p.Executable, "exec", "--json", "--strict-config", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
		"-C", p.Cwd, "-s", "read-only", "-m", p.Model,
		"-c", "model_reasoning_effort=" + quote(p.Effort),
		"-c", `approval_policy="never"`,
		"-c", `web_search="disabled"`,
	}
	for _, feature := range codexDisabledFeatures {
		argv = append(argv, "--disable", feature)
	}
	argv = append(argv,
		"-c", "mcp_servers."+ReaderServer+".command="+quote(p.Reader.Command),
		"-c", "mcp_servers."+ReaderServer+".args="+list(append([]string{}, p.Reader.Args...)),
		"-c", "mcp_servers."+ReaderServer+".enabled_tools="+list(p.Reader.Tools),
		"-c", "mcp_servers."+ReaderServer+".required=true",
	)
	launch.Argv = argv
	launch.ScopeEnforcement = EnforcementPartial
	launch.Residual = append([]string{"code-mode exec runner", "collaboration (spawn_agent and related)"}, CodexResidualTools...)
	launch.Unverified = []string{"shell is hidden from the model, not proven unrunnable; needs one approved worker turn that tries the shell and is refused",
		"apply_patch is still offered; only the read-only sandbox blocks its writes",
		"Codex lists the reader's tools at start-up but prompt-input does not render MCP tools, so enabled_tools filtering is not observed offline",
		"usd is not enforced by Codex; passes, retries and wall_seconds are enforced by the caller"}
	return launch, nil
}
