package researchworker

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

const testContract = "c70e78fa89c0ba9c5bfdac261c74b83fb954d6a984cfcd9c3af0143dce4dc3c8"
const testWorkerDir = "/private/var/relay/research-workers/6f1d2c3b"

func basePolicy(provider string) Policy {
	p := Policy{Provider: provider, Model: "claude-opus-5-5", Effort: "high", Cwd: "/projects/caeg/people/kbd606/project",
		Executable: "/Users/kbd606/.local/share/claude/versions/2.1.318", ContractSHA256: testContract,
		Reader: Reader{Command: "/opt/relay/bin/evidence-reader", Args: []string{"--contract", "/private/var/relay/contract.json"}, Tools: []string{"read", "search"}},
		Budget: Budget{Passes: 1, Retries: 0, WallSeconds: 180, USD: 3}}
	if provider == ProviderCodex {
		p.Model, p.Executable = "gpt-6", "/Users/kbd606/.codex/packages/standalone/current/bin/codex"
	}
	return p
}

// value returns the argument after flag, failing if flag is absent or repeated.
func value(t *testing.T, argv []string, flag string) string {
	t.Helper()
	index := -1
	for i, a := range argv {
		if a == flag {
			if index >= 0 {
				t.Fatalf("%s given twice", flag)
			}
			index = i
		}
	}
	if index < 0 || index+1 >= len(argv) {
		t.Fatalf("%s missing in %q", flag, argv)
	}
	return argv[index+1]
}

func configs(argv []string) []string {
	var out []string
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == "-c" {
			out = append(out, argv[i+1])
		}
	}
	return out
}

func TestClaudeWorkerToolsAreFixedAtLaunch(t *testing.T) {
	launch, err := Plan(basePolicy(ProviderClaude), testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	argv := launch.Argv
	if argv[0] != "/Users/kbd606/.local/share/claude/versions/2.1.318" || !slices.Contains(argv, "--print") || !slices.Contains(argv, "--strict-mcp-config") || !slices.Contains(argv, "--disable-slash-commands") {
		t.Fatalf("missing launch fences: %q", argv)
	}
	if value(t, argv, "--tools") != "" {
		t.Fatal("built-in tools are not all disabled")
	}
	if got := value(t, argv, "--allowedTools"); got != "mcp__evidence__read,mcp__evidence__search" {
		t.Fatalf("allowed tools %q", got)
	}
	denied := strings.Split(value(t, argv, "--disallowedTools"), ",")
	for _, tool := range []string{"Bash", "Write", "Edit", "WebFetch", "WebSearch", "Task", "Read"} {
		if !slices.Contains(denied, tool) {
			t.Fatalf("%s is not denied", tool)
		}
	}
	for flag, want := range map[string]string{"--model": "claude-opus-5-5", "--effort": "high", "--setting-sources": "", "--permission-mode": "dontAsk", "--permission-prompts": "none", "--max-budget-usd": "3", "--mcp-config": testWorkerDir + "/" + MCPConfigFile} {
		if got := value(t, argv, flag); got != want {
			t.Fatalf("%s = %q, want %q", flag, got, want)
		}
	}
	for _, forbidden := range []string{"--dangerously-skip-permissions", "--bare", "--no-session-persistence", "--resume", "--continue"} {
		if slices.Contains(argv, forbidden) {
			t.Fatalf("%s must not be passed", forbidden)
		}
	}
	var config struct {
		MCPServers map[string]struct {
			Type    string   `json:"type"`
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if json.Unmarshal(launch.Files[MCPConfigFile], &config) != nil || len(config.MCPServers) != 1 || len(launch.Files) != 1 {
		t.Fatalf("MCP config must hold exactly the reader: %s", launch.Files[MCPConfigFile])
	}
	reader := config.MCPServers[ReaderServer]
	if reader.Type != "stdio" || reader.Command != "/opt/relay/bin/evidence-reader" || !slices.Equal(reader.Args, []string{"--contract", "/private/var/relay/contract.json"}) {
		t.Fatalf("reader entry %+v", reader)
	}
	if launch.ScopeEnforcement != EnforcementLaunchFixed || len(launch.Unverified) == 0 || launch.Dir != "/projects/caeg/people/kbd606/project" || launch.ContractSHA256 != testContract {
		t.Fatalf("launch metadata %+v", launch)
	}
}

func TestCodexWorkerDisablesShellAndReportsPartial(t *testing.T) {
	launch, err := Plan(basePolicy(ProviderCodex), testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	argv := launch.Argv
	if argv[1] != "exec" {
		t.Fatalf("not a one-shot worker: %q", argv)
	}
	for _, flag := range []string{"--strict-config", "--ignore-user-config", "--ignore-rules", "--json"} {
		if !slices.Contains(argv, flag) {
			t.Fatalf("%s missing", flag)
		}
	}
	if value(t, argv, "-s") != "read-only" || value(t, argv, "-m") != "gpt-6" || value(t, argv, "-C") != "/projects/caeg/people/kbd606/project" {
		t.Fatalf("sandbox/model/cwd wrong: %q", argv)
	}
	var disabled []string
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == "--disable" {
			disabled = append(disabled, argv[i+1])
		}
	}
	for _, feature := range []string{"shell_tool", "multi_agent", "view_image", "apps", "plugins", "browser_use", "computer_use", "hooks"} {
		if !slices.Contains(disabled, feature) {
			t.Fatalf("%s not disabled", feature)
		}
	}
	want := []string{`model_reasoning_effort="high"`, `approval_policy="never"`, `web_search="disabled"`,
		`mcp_servers.evidence.command="/opt/relay/bin/evidence-reader"`, `mcp_servers.evidence.args=["--contract","/private/var/relay/contract.json"]`,
		`mcp_servers.evidence.enabled_tools=["read","search"]`, `mcp_servers.evidence.required=true`}
	if got := configs(argv); !slices.Equal(got, want) {
		t.Fatalf("config overrides\n got %q\nwant %q", got, want)
	}
	for _, c := range configs(argv) {
		if strings.HasPrefix(c, "mcp_servers.") && !strings.HasPrefix(c, "mcp_servers.evidence.") {
			t.Fatalf("second MCP server configured: %s", c)
		}
	}
	if slices.Contains(argv, "--dangerously-bypass-approvals-and-sandbox") || slices.Contains(argv, "--full-auto") {
		t.Fatal("sandbox bypass passed")
	}
	if launch.ScopeEnforcement != EnforcementPartial || !slices.Contains(launch.Residual, "apply_patch") || len(launch.Files) != 0 {
		t.Fatalf("Codex must be reported partial with residuals: %+v", launch)
	}
	joined := strings.Join(launch.Unverified, " | ")
	if !strings.Contains(joined, "not proven unrunnable") {
		t.Fatalf("Codex shell claim is overstated: %s", joined)
	}
}

func TestCodexEffortUsesCodexNames(t *testing.T) {
	p := basePolicy(ProviderCodex)
	p.Effort = "minimal"
	if _, err := Plan(p, testWorkerDir); err != nil {
		t.Fatal(err)
	}
	p.Effort = "max"
	if _, err := Plan(p, testWorkerDir); err == nil {
		t.Fatal("Claude-only effort accepted for Codex")
	}
}

func TestPlanRejectsUnsafeOrMalformedPolicies(t *testing.T) {
	cases := map[string]func(*Policy, *string){
		"unknown provider":    func(p *Policy, _ *string) { p.Provider = "relay" },
		"relative executable": func(p *Policy, _ *string) { p.Executable = "claude" },
		"relay shim":          func(p *Policy, _ *string) { p.Executable = "/Users/kbd606/.local/share/relay/shims/claude" },
		"unclean executable":  func(p *Policy, _ *string) { p.Executable = "/usr/bin/../bin/claude" },
		"no model":            func(p *Policy, _ *string) { p.Model = "" },
		"placeholder model":   func(p *Policy, _ *string) { p.Model = "UNVERIFIED PREFLIGHT" },
		"unverified effort":   func(p *Policy, _ *string) { p.Effort = "unverified" },
		"codex-only effort":   func(p *Policy, _ *string) { p.Effort = "minimal" },
		"relative cwd":        func(p *Policy, _ *string) { p.Cwd = "project" },
		"relative worker dir": func(_ *Policy, d *string) { *d = "workers/1" },
		"short contract":      func(p *Policy, _ *string) { p.ContractSHA256 = testContract[:63] },
		"uppercase contract":  func(p *Policy, _ *string) { p.ContractSHA256 = strings.ToUpper(testContract) },
		"relative reader":     func(p *Policy, _ *string) { p.Reader.Command = "evidence-reader" },
		"no reader tools":     func(p *Policy, _ *string) { p.Reader.Tools = nil },
		"prefixed tool":       func(p *Policy, _ *string) { p.Reader.Tools = []string{"mcp__evidence__read"} },
		"wildcard tool":       func(p *Policy, _ *string) { p.Reader.Tools = []string{"*"} },
		"shell as tool":       func(p *Policy, _ *string) { p.Reader.Tools = []string{"Bash"} },
		"duplicate tool":      func(p *Policy, _ *string) { p.Reader.Tools = []string{"read", "read"} },
		"newline in arg":      func(p *Policy, _ *string) { p.Reader.Args = []string{"--x\n--y"} },
		"empty arg":           func(p *Policy, _ *string) { p.Reader.Args = []string{""} },
		"zero passes":         func(p *Policy, _ *string) { p.Budget.Passes = 0 },
		"too many retries":    func(p *Policy, _ *string) { p.Budget.Retries = 6 },
		"zero wall":           func(p *Policy, _ *string) { p.Budget.WallSeconds = 0 },
		"long wall":           func(p *Policy, _ *string) { p.Budget.WallSeconds = 3601 },
		"zero usd":            func(p *Policy, _ *string) { p.Budget.USD = 0 },
		"huge usd":            func(p *Policy, _ *string) { p.Budget.USD = 101 },
	}
	for _, provider := range []string{ProviderClaude, ProviderCodex} {
		for name, mutate := range cases {
			if provider == ProviderCodex && name == "codex-only effort" {
				continue
			}
			p, dir := basePolicy(provider), testWorkerDir
			mutate(&p, &dir)
			if launch, err := Plan(p, dir); err == nil {
				t.Fatalf("%s/%s accepted: %q", provider, name, launch.Argv)
			}
		}
	}
}
