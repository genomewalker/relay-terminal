package researchworker

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const fakeThread = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001"
const fakeRequest = "6f1d2c3b-4a59-4e7d-8c1b-2a3f4e5d6c7b"

// fakeWorker stands in for the provider binary. It records how it was started
// and prints scripted provider events. It never calls a model.
func fakeWorker(scenario string) int {
	prompt, _ := io.ReadAll(os.Stdin)
	cwd, _ := os.Getwd()
	var relayVars []string
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "RELAY_") {
			relayVars = append(relayVars, entry)
		}
	}
	if path := os.Getenv("FAKE_WORKER_LOG"); path != "" {
		record, _ := json.Marshal(map[string]any{"argv": os.Args[1:], "stdin": string(prompt), "cwd": cwd, "relay_env": relayVars})
		file, _ := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		_, _ = file.Write(append(record, '\n'))
		file.Close()
	}
	argv := os.Args[1:]
	flag := func(name string) string {
		for i := 0; i+1 < len(argv); i++ {
			if argv[i] == name {
				return argv[i+1]
			}
		}
		return ""
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	emit := func(v any) { b, _ := json.Marshal(v); _, _ = out.Write(append(b, '\n')) }
	if scenario == "hang" {
		out.Flush()
		time.Sleep(30 * time.Second)
		return 0
	}
	if scenario == "exit-1" {
		fmt.Fprintln(os.Stderr, "provider failed")
		return 1
	}
	if len(argv) > 0 && argv[0] == "exec" {
		if scenario != "no-thread" {
			emit(map[string]any{"type": "thread.started", "thread_id": fakeThread})
		}
		emit(map[string]any{"type": "turn.started"})
		switch scenario {
		case "shell-item":
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "command_execution", "command": "cat /etc/passwd", "exit_code": 0}})
		case "file-change":
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "file_change", "changes": []any{}}})
		case "collab":
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "collab_tool_call", "tool": "spawn_agent"}})
		case "other-mcp":
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "mcp_tool_call", "server": "chitta", "tool": "recall"}})
		case "reader-write":
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "mcp_tool_call", "server": "evidence", "tool": "write"}})
		default:
			emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i1", "type": "mcp_tool_call", "server": "evidence", "tool": "read", "status": "completed"}})
		}
		emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "i2", "type": "agent_message", "text": "synthesis for " + string(prompt)}})
		if scenario == "turn-failed" {
			emit(map[string]any{"type": "turn.failed", "error": map[string]any{"message": "usage limit"}})
			return 1
		}
		emit(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 100, "output_tokens": 20}})
		return 0
	}
	if scenario == "no-init" {
		emit(map[string]any{"type": "result", "subtype": "success", "is_error": false, "result": "x"})
		return 0
	}
	tools := []string{"mcp__evidence__list", "mcp__evidence__read", "mcp__evidence__search"}
	servers := []any{map[string]any{"name": "evidence", "status": "connected"}}
	model, mode := flag("--model"), flag("--permission-mode")
	switch scenario {
	case "bash-tool":
		tools = append(tools, "Bash")
	case "extra-mcp":
		servers = append(servers, map[string]any{"name": "chitta", "status": "connected"})
		tools = append(tools, "mcp__chitta__recall")
	case "reader-failed":
		servers = []any{map[string]any{"name": "evidence", "status": "failed"}}
	case "wrong-model":
		model = "claude-haiku-5-5"
	case "bypass":
		mode = "bypassPermissions"
	}
	emit(map[string]any{"type": "system", "subtype": "init", "session_id": "sess-1", "cwd": cwd, "model": model, "permissionMode": mode, "tools": tools, "mcp_servers": servers})
	name := "mcp__evidence__read"
	if scenario == "tool-use-outside" {
		name = "Bash"
	}
	emit(map[string]any{"type": "assistant", "message": map[string]any{"content": []any{map[string]any{"type": "tool_use", "name": name, "input": map[string]any{"id": "S001"}}}}})
	cost := 0.42
	if scenario == "over-budget" {
		cost = 3.5
	}
	result := map[string]any{"type": "result", "subtype": "success", "is_error": false, "result": "synthesis for " + string(prompt), "session_id": "sess-1", "total_cost_usd": cost, "usage": map[string]any{"input_tokens": 100}}
	if scenario == "error-result" {
		result["subtype"], result["is_error"] = "error_max_turns", true
	}
	emit(result)
	return 0
}

type harness struct {
	root, log, codexHome, cwd string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{root: filepath.Join(t.TempDir(), "workers"), log: filepath.Join(t.TempDir(), "worker.log"), cwd: t.TempDir()}
	if err := os.Mkdir(h.root, 0o700); err != nil {
		t.Fatal(err)
	}
	if real, err := filepath.EvalSymlinks(h.cwd); err == nil {
		h.cwd = real
	}
	return h
}

func (h *harness) rollout(t *testing.T, context map[string]any) {
	t.Helper()
	h.codexHome = t.TempDir()
	dir := filepath.Join(h.codexHome, "sessions", "2026", "11", "06")
	_ = os.MkdirAll(dir, 0o700)
	line, _ := json.Marshal(map[string]any{"type": "turn_context", "payload": context})
	_ = os.WriteFile(filepath.Join(dir, "rollout-2026-11-06T00-00-00-"+fakeThread+".jsonl"), append(line, '\n'), 0o600)
}

func (h *harness) request(t *testing.T, provider, scenario string) Request {
	t.Helper()
	self, _ := os.Executable()
	p := basePolicy(provider)
	p.Executable, p.Cwd = self, h.cwd
	p.Reader = EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", strings.Repeat("a", 64), testContract)
	return Request{RequestID: fakeRequest, Policy: p, Prompt: "Summarise S001", WorkersRoot: h.root, CodexHome: h.codexHome,
		Env: append(os.Environ(), "FAKE_WORKER_SCENARIO="+scenario, "FAKE_WORKER_LOG="+h.log, "RELAY_MCP_TOKEN=must-not-leak", "RELAY_CONTROL_TOKEN=x")}
}

func (h *harness) runs(t *testing.T) []map[string]any {
	t.Helper()
	raw, _ := os.ReadFile(h.log)
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var v map[string]any
		if json.Unmarshal([]byte(line), &v) == nil {
			out = append(out, v)
		}
	}
	return out
}

func status(r Receipt, name string) string {
	result := ""
	for _, c := range r.Checks {
		if c.Name == name && (result == "" || c.Status == CheckViolated) {
			result = c.Status
		}
	}
	return result
}

func TestClaudeWorkerLaunchBindsAndVerifies(t *testing.T) {
	h := newHarness(t)
	request := h.request(t, ProviderClaude, "ok")
	receipt, err := Run(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Verified || receipt.ExitCode != 0 || receipt.SessionID != "sess-1" || receipt.Result != "synthesis for Summarise S001" || receipt.CostUSD == nil || *receipt.CostUSD != 0.42 {
		t.Fatalf("receipt %+v", receipt)
	}
	for _, name := range []string{"model", "tools", "mcp_servers", "permission_mode", "cwd", "result", "usd", "exit", "wall_seconds"} {
		if status(receipt, name) != CheckVerified {
			t.Fatalf("%s = %q", name, status(receipt, name))
		}
	}
	if status(receipt, "effort") != CheckUnverified {
		t.Fatal("effort claimed verified without evidence")
	}
	b := receipt.Binding
	if b.RequestID != fakeRequest || b.ContractSHA256 != testContract || b.Provider != ProviderClaude || b.PromptSHA256 != digestString("Summarise S001") || len(b.ArgvSHA256) != 64 {
		t.Fatalf("binding %+v", b)
	}
	runs := h.runs(t)
	if len(runs) != 1 || runs[0]["stdin"] != "Summarise S001" || runs[0]["cwd"] != h.cwd || runs[0]["relay_env"] != nil {
		t.Fatalf("worker start %v", runs)
	}
	argv, _ := stringsOf(runs[0]["argv"])
	if value(t, argv, "--mcp-config") != filepath.Join(h.root, fakeRequest, MCPConfigFile) || value(t, argv, "--output-format") != "stream-json" || !slices.Contains(argv, "--verbose") {
		t.Fatalf("argv %q", argv)
	}
	dir := filepath.Join(h.root, fakeRequest)
	for _, name := range []string{"binding.json", "receipt.json", "events.jsonl", "stderr.txt", MCPConfigFile} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", name, err, info)
		}
	}
	if info, _ := os.Stat(dir); info.Mode().Perm() != 0o700 {
		t.Fatalf("worker dir mode %v", info.Mode())
	}

	// Same request again: the stored receipt, no second worker.
	again, err := Run(context.Background(), request)
	if err != nil || again.Binding != receipt.Binding || !again.Verified || len(h.runs(t)) != 1 {
		t.Fatalf("replay started a worker or changed the receipt: %v %d", err, len(h.runs(t)))
	}
	// Same request_id, different contract or prompt: refused, nothing started.
	other := request
	other.Prompt = "Different question"
	if _, err := Run(context.Background(), other); err == nil || !strings.Contains(err.Error(), "already bound") {
		t.Fatalf("rebinding accepted: %v", err)
	}
	other = h.request(t, ProviderClaude, "ok")
	other.Policy.ContractSHA256 = strings.Repeat("b", 64)
	other.Policy.Reader = EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", strings.Repeat("a", 64), other.Policy.ContractSHA256)
	if _, err := Run(context.Background(), other); err == nil || !strings.Contains(err.Error(), "already bound") {
		t.Fatalf("contract change accepted: %v", err)
	}
	if len(h.runs(t)) != 1 {
		t.Fatal("a refused request started a worker")
	}
}

func TestClaudeWorkerViolationsAreNotVerified(t *testing.T) {
	cases := map[string]string{
		"bash-tool": "tools", "extra-mcp": "mcp_servers", "reader-failed": "mcp_servers", "wrong-model": "model", "bypass": "permission_mode",
		"tool-use-outside": "tool_use", "over-budget": "usd", "error-result": "result", "exit-1": "exit", "no-init": "init",
	}
	for scenario, check := range cases {
		h := newHarness(t)
		receipt, err := Run(context.Background(), h.request(t, ProviderClaude, scenario))
		if err != nil {
			t.Fatalf("%s: %v", scenario, err)
		}
		if receipt.Verified || status(receipt, check) != CheckViolated {
			t.Fatalf("%s: verified=%v %s=%q checks=%+v", scenario, receipt.Verified, check, status(receipt, check), receipt.Checks)
		}
	}
}

func TestCodexWorkerLaunchVerifiesFromEventsAndRollout(t *testing.T) {
	h := newHarness(t)
	h.rollout(t, map[string]any{"model": "gpt-6", "approval_policy": "never", "sandbox_policy": map[string]any{"type": "read-only"}, "effort": "high", "cwd": h.cwd})
	receipt, err := Run(context.Background(), h.request(t, ProviderCodex, "ok"))
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Verified || receipt.SessionID != fakeThread || receipt.Result != "synthesis for Summarise S001" || receipt.ScopeEnforcement != EnforcementPartial {
		t.Fatalf("receipt %+v", receipt)
	}
	for _, name := range []string{"thread", "items", "model", "approval_policy", "sandbox", "effort", "cwd", "result"} {
		if status(receipt, name) != CheckVerified {
			t.Fatalf("%s = %q", name, status(receipt, name))
		}
	}
	if status(receipt, "usd") != CheckUnverified {
		t.Fatal("Codex cost claimed verified")
	}
	argv, _ := stringsOf(h.runs(t)[0]["argv"])
	if argv[0] != "exec" || !slices.Contains(argv, "shell_tool") || h.runs(t)[0]["stdin"] != "Summarise S001" {
		t.Fatalf("argv %q", argv)
	}
}

func TestCodexWorkerWithoutRolloutStaysUnverified(t *testing.T) {
	h := newHarness(t)
	receipt, err := Run(context.Background(), h.request(t, ProviderCodex, "ok"))
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Verified || status(receipt, "model") != CheckUnverified || status(receipt, "sandbox") != CheckUnverified || status(receipt, "items") != CheckVerified {
		t.Fatalf("missing rollout must leave settings unverified: %+v", receipt.Checks)
	}
	h2 := newHarness(t)
	h2.rollout(t, map[string]any{"model": "gpt-6", "cwd": h2.cwd})
	receipt, _ = Run(context.Background(), h2.request(t, ProviderCodex, "ok"))
	if receipt.Verified || status(receipt, "sandbox") != CheckUnverified || status(receipt, "model") != CheckVerified {
		t.Fatalf("partial turn_context: %+v", receipt.Checks)
	}
}

func TestCodexWorkerViolationsAreNotVerified(t *testing.T) {
	good := func(h *harness) map[string]any {
		return map[string]any{"model": "gpt-6", "approval_policy": "never", "sandbox_policy": map[string]any{"type": "read-only"}, "effort": "high", "cwd": h.cwd}
	}
	cases := map[string]struct {
		scenario, check string
		edit            func(map[string]any)
	}{
		"shell ran":         {"shell-item", "items", nil},
		"file change":       {"file-change", "items", nil},
		"collaboration":     {"collab", "items", nil},
		"other mcp":         {"other-mcp", "items", nil},
		"reader write tool": {"reader-write", "items", nil},
		"no thread":         {"no-thread", "thread", nil},
		"turn failed":       {"turn-failed", "result", nil},
		"exit 1":            {"exit-1", "exit", nil},
		"full access":       {"ok", "sandbox", func(c map[string]any) { c["sandbox_policy"] = map[string]any{"type": "danger-full-access"} }},
		"approval asks":     {"ok", "approval_policy", func(c map[string]any) { c["approval_policy"] = "on-request" }},
		"other model":       {"ok", "model", func(c map[string]any) { c["model"] = "gpt-6-mini" }},
		"other effort":      {"ok", "effort", func(c map[string]any) { c["effort"] = "low" }},
	}
	for name, c := range cases {
		h := newHarness(t)
		context0 := good(h)
		if c.edit != nil {
			c.edit(context0)
		}
		h.rollout(t, context0)
		receipt, err := Run(context.Background(), h.request(t, ProviderCodex, c.scenario))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if receipt.Verified || status(receipt, c.check) != CheckViolated {
			t.Fatalf("%s: verified=%v %s=%q %+v", name, receipt.Verified, c.check, status(receipt, c.check), receipt.Checks)
		}
	}
}

func TestWorkerWallClockKillsTheProcessGroup(t *testing.T) {
	h := newHarness(t)
	request := h.request(t, ProviderClaude, "hang")
	request.Policy.Budget.WallSeconds = 1
	started := time.Now()
	receipt, err := Run(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > 10*time.Second {
		t.Fatalf("timeout took %s", elapsed)
	}
	if !receipt.TimedOut || receipt.Verified || status(receipt, "wall_seconds") != CheckViolated {
		t.Fatalf("receipt %+v", receipt)
	}
}

func TestRunRefusesBeforeStartingAnything(t *testing.T) {
	h := newHarness(t)
	cases := map[string]func(*Request){
		"uppercase request id": func(r *Request) { r.RequestID = strings.ToUpper(fakeRequest) },
		"bad request id":       func(r *Request) { r.RequestID = "../escape" },
		"empty prompt":         func(r *Request) { r.Prompt = "" },
		"huge prompt":          func(r *Request) { r.Prompt = strings.Repeat("x", maxPromptBytes+1) },
		"relative root":        func(r *Request) { r.WorkersRoot = "workers" },
		"missing root":         func(r *Request) { r.WorkersRoot = filepath.Join(h.root, "none") },
		"relative codex home":  func(r *Request) { r.CodexHome = "codex" },
		"bad policy":           func(r *Request) { r.Policy.Model = "" },
		"reader for another contract": func(r *Request) {
			r.Policy.Reader = EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", strings.Repeat("a", 64), strings.Repeat("c", 64))
		},
	}
	for name, mutate := range cases {
		request := h.request(t, ProviderClaude, "ok")
		mutate(&request)
		if _, err := Run(context.Background(), request); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	open := filepath.Join(t.TempDir(), "open")
	_ = os.Mkdir(open, 0o755)
	_ = os.Chmod(open, 0o755)
	request := h.request(t, ProviderClaude, "ok")
	request.WorkersRoot = open
	if _, err := Run(context.Background(), request); err == nil {
		t.Fatal("shared workers root accepted")
	}
	if len(h.runs(t)) != 0 {
		t.Fatal("a refused request started a worker")
	}
	// A bound request without a receipt (an earlier start with unknown outcome)
	// is never started again.
	request = h.request(t, ProviderClaude, "ok")
	dir := filepath.Join(h.root, fakeRequest)
	_ = os.Mkdir(dir, 0o700)
	_ = os.WriteFile(filepath.Join(dir, "binding.json"), []byte("{}"), 0o600)
	if _, err := Run(context.Background(), request); err == nil {
		t.Fatal("mismatched binding accepted")
	}
	_ = os.RemoveAll(dir)
	first, err := Run(context.Background(), request)
	if err != nil || !first.Verified {
		t.Fatalf("first run: %v %+v", err, first)
	}
	_ = os.Remove(filepath.Join(dir, "receipt.json"))
	if _, err := Run(context.Background(), request); !errors.Is(err, ErrAlreadyAdmitted) {
		t.Fatalf("unknown outcome retried: %v", err)
	}
	if len(h.runs(t)) != 1 {
		t.Fatalf("worker started %d times", len(h.runs(t)))
	}
}
