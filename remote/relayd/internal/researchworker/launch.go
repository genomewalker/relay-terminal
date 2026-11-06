package researchworker

// Launch, bind and verify one dedicated research worker (P2).
//
// Run admits a request once: it creates <root>/<request_id> exclusively and
// writes binding.json (request_id, contract hash, provider, model, effort,
// argv hash, prompt hash) before starting anything. A second Run with the same
// request_id never starts another worker: it returns the stored receipt when
// the binding matches and a receipt exists, and refuses otherwise (a binding
// without a receipt means an earlier start had an unknown outcome, which is
// never retried).
//
// After the worker exits, its effective settings are checked from the
// provider's own records, not from the plan:
//   - Claude: the stream-json init event (model, tools, MCP servers,
//     permission mode, cwd), every tool_use, and the result (error, cost).
//   - Codex: the exec --json events (thread, every item; any shell, file
//     change, web search or collaboration item is a violation; MCP calls must
//     be the evidence reader's tools) and, when found, the rollout
//     turn_context (model, approval, sandbox, effort). Without a rollout those
//     settings stay unverified.
//
// A receipt is Verified only when every required check is verified and none
// is violated. Unverified is never reported as verified.

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"
)

const (
	CheckVerified   = "verified"
	CheckViolated   = "violated"
	CheckUnverified = "unverified"

	maxEventBytes  = 16 << 20
	maxStderrBytes = 1 << 20
	maxPromptBytes = 256 << 10
)

var requestUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

var ErrAlreadyAdmitted = errors.New("request_id was already admitted with an unknown outcome; not started again")

type Request struct {
	RequestID   string
	Policy      Policy
	Prompt      string
	WorkersRoot string   // private (0700, owned) directory holding one folder per request
	Env         []string // base environment; RELAY_* variables are removed
	CodexHome   string   // optional: where to find the Codex rollout for verification
	SQLite3     string   // optional: absolute sqlite3 CLI path, to read paginated Codex thread state
}

type Binding struct {
	Version        int    `json:"version"`
	RequestID      string `json:"request_id"`
	ContractSHA256 string `json:"contract_sha256"`
	Provider       string `json:"provider"`
	Model          string `json:"model"`
	Effort         string `json:"effort"`
	ArgvSHA256     string `json:"argv_sha256"`
	PromptSHA256   string `json:"prompt_sha256"`
	Budget         Budget `json:"budget"`
}

// USDUnknown is the status when the provider reports no cost.
const USDUnknown = "unknown, not verified"

// BudgetLine is one limit, what was used, and how that was established.
type BudgetLine struct {
	Limit  any    `json:"limit"`
	Used   any    `json:"used"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

type BudgetUse struct {
	Passes      BudgetLine `json:"passes"`
	Retries     BudgetLine `json:"retries"`
	WallSeconds BudgetLine `json:"wall_seconds"`
	USD         BudgetLine `json:"usd"`
}

type Check struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

type Receipt struct {
	Binding          Binding        `json:"binding"`
	WorkerDir        string         `json:"worker_dir"`
	ExitCode         int            `json:"exit_code"`
	TimedOut         bool           `json:"timed_out"`
	StartedAt        time.Time      `json:"started_at"`
	EndedAt          time.Time      `json:"ended_at"`
	SessionID        string         `json:"session_id,omitempty"`
	Result           string         `json:"result,omitempty"`
	CostUSD          *float64       `json:"cost_usd,omitempty"`
	Usage            map[string]any `json:"usage,omitempty"`
	Effective        map[string]any `json:"effective_settings"`
	Budget           BudgetUse      `json:"budget"`
	Checks           []Check        `json:"checks"`
	ScopeEnforcement string         `json:"scope_enforcement"`
	Verified         bool           `json:"verified"`
}

func digestString(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func privateDirectory(path string) error {
	if !absolute(path) {
		return errors.New("workers root must be a clean absolute path")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() {
		return errors.New("workers root is not an existing directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0o077 != 0 {
		return errors.New("workers root must be owned by this user and private (0700)")
	}
	return nil
}

func writePrivate(path string, content []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(content); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// workerEnv drops Relay credentials and controls so a worker cannot reach
// Relay as its parent.
func workerEnv(base []string) []string {
	out := make([]string, 0, len(base))
	for _, entry := range base {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "RELAY_") {
			continue
		}
		out = append(out, entry)
	}
	return out
}

type cappedFile struct {
	file  *os.File
	left  int64
	trunc bool
}

func (c *cappedFile) Write(p []byte) (int, error) {
	n := len(p)
	if int64(len(p)) > c.left {
		p, c.trunc = p[:c.left], true
	}
	if len(p) > 0 {
		written, err := c.file.Write(p)
		c.left -= int64(written)
		if err != nil {
			return written, err
		}
	}
	return n, nil
}

// Run admits, starts and verifies one worker. It returns an error only when
// nothing was started; once started, the outcome is in the receipt.
func Run(ctx context.Context, request Request) (Receipt, error) {
	if !requestUUID.MatchString(request.RequestID) {
		return Receipt{}, errors.New("request_id must be a lowercase UUID")
	}
	if request.Prompt == "" || len(request.Prompt) > maxPromptBytes {
		return Receipt{}, errors.New("prompt must be 1 byte to 256 KiB")
	}
	if request.CodexHome != "" && !absolute(request.CodexHome) {
		return Receipt{}, errors.New("codex home must be a clean absolute path")
	}
	if request.SQLite3 != "" && !absolute(request.SQLite3) {
		return Receipt{}, errors.New("sqlite3 must be a clean absolute path")
	}
	if err := privateDirectory(request.WorkersRoot); err != nil {
		return Receipt{}, err
	}
	dir := filepath.Join(request.WorkersRoot, request.RequestID)
	launch, err := Plan(request.Policy, dir)
	if err != nil {
		return Receipt{}, err
	}
	argv, _ := json.Marshal(launch.Argv)
	binding := Binding{Version: 1, RequestID: request.RequestID, ContractSHA256: request.Policy.ContractSHA256, Provider: request.Policy.Provider,
		Model: request.Policy.Model, Effort: request.Policy.Effort, ArgvSHA256: digestString(string(argv)), PromptSHA256: digestString(request.Prompt), Budget: request.Policy.Budget}
	encoded, _ := json.MarshalIndent(binding, "", "  ")

	if err := os.Mkdir(dir, 0o700); err != nil {
		if !os.IsExist(err) {
			return Receipt{}, err
		}
		return existing(dir, binding)
	}
	if err := writePrivate(filepath.Join(dir, "binding.json"), encoded); err != nil {
		return Receipt{}, fmt.Errorf("could not bind request: %w", err)
	}
	for name, content := range launch.Files {
		if err := writePrivate(filepath.Join(dir, name), content); err != nil {
			return Receipt{}, fmt.Errorf("could not write %s: %w", name, err)
		}
	}
	return start(ctx, request, launch, binding, dir), nil
}

func existing(dir string, binding Binding) (Receipt, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "binding.json"))
	var stored Binding
	if err != nil || json.Unmarshal(raw, &stored) != nil {
		return Receipt{}, ErrAlreadyAdmitted
	}
	if stored != binding {
		return Receipt{}, errors.New("request_id is already bound to a different contract, model, prompt or launch; refused")
	}
	raw, err = os.ReadFile(filepath.Join(dir, "receipt.json"))
	var receipt Receipt
	if err != nil || json.Unmarshal(raw, &receipt) != nil || receipt.Binding != binding {
		return Receipt{}, ErrAlreadyAdmitted
	}
	return receipt, nil
}

func start(ctx context.Context, request Request, launch Launch, binding Binding, dir string) Receipt {
	receipt := Receipt{Binding: binding, WorkerDir: dir, ScopeEnforcement: launch.ScopeEnforcement, ExitCode: -1, Effective: map[string]any{}}
	events, err := os.OpenFile(filepath.Join(dir, "events.jsonl"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		receipt.Checks = []Check{{Name: "start", Status: CheckViolated, Detail: "could not create the event log"}}
		return finish(dir, receipt)
	}
	defer events.Close()
	stderr, err := os.OpenFile(filepath.Join(dir, "stderr.txt"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		receipt.Checks = []Check{{Name: "start", Status: CheckViolated, Detail: "could not create the stderr log"}}
		return finish(dir, receipt)
	}
	defer stderr.Close()

	wall := time.Duration(request.Policy.Budget.WallSeconds) * time.Second
	ctx, cancel := context.WithTimeout(ctx, wall)
	defer cancel()
	command := exec.Command(launch.Argv[0], launch.Argv[1:]...)
	command.Dir = launch.Dir
	command.Env = workerEnv(request.Env)
	command.Stdin = strings.NewReader(request.Prompt)
	eventSink := &cappedFile{file: events, left: maxEventBytes}
	command.Stdout = eventSink
	command.Stderr = &cappedFile{file: stderr, left: maxStderrBytes}
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	receipt.StartedAt = time.Now().UTC()
	if err := command.Start(); err != nil {
		receipt.EndedAt = time.Now().UTC()
		receipt.Checks = []Check{{Name: "start", Status: CheckViolated, Detail: "worker did not start: " + err.Error()}}
		return finish(dir, receipt)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	var waitErr error
	select {
	case waitErr = <-done:
	case <-ctx.Done():
		receipt.TimedOut = true
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		waitErr = <-done
	}
	receipt.EndedAt = time.Now().UTC()
	if command.ProcessState != nil {
		receipt.ExitCode = command.ProcessState.ExitCode()
	}
	_ = waitErr

	checks := []Check{}
	if receipt.TimedOut {
		checks = append(checks, Check{Name: "wall_seconds", Status: CheckViolated, Detail: fmt.Sprintf("killed after %s", wall)})
	} else {
		checks = append(checks, Check{Name: "wall_seconds", Status: CheckVerified})
	}
	if eventSink.trunc {
		checks = append(checks, Check{Name: "event_log", Status: CheckViolated, Detail: "provider output exceeded 16 MiB and was truncated"})
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "events.jsonl"))
	if launch.Provider == ProviderClaude {
		checks = append(checks, verifyClaude(raw, launch, request.Policy, &receipt)...)
	} else {
		checks = append(checks, verifyCodex(raw, launch, request, &receipt)...)
	}
	if receipt.ExitCode == 0 {
		checks = append(checks, Check{Name: "exit", Status: CheckVerified})
	} else {
		checks = append(checks, Check{Name: "exit", Status: CheckViolated, Detail: fmt.Sprintf("exit code %d", receipt.ExitCode)})
	}
	receipt.Checks = checks
	receipt.Budget = budgetUse(request.Policy.Budget, receipt)
	return finish(dir, receipt)
}

// budgetUse summarises the budget from the checks already made. Retries are
// always 0: Run starts a request once and never restarts it.
func budgetUse(budget Budget, receipt Receipt) BudgetUse {
	line := func(name string, limit, used any) BudgetLine {
		out := BudgetLine{Limit: limit, Used: used, Status: CheckUnverified}
		for _, c := range receipt.Checks {
			if c.Name == name && (out.Status != CheckViolated) {
				out.Status, out.Detail = c.Status, c.Detail
			}
		}
		return out
	}
	elapsed := receipt.EndedAt.Sub(receipt.StartedAt).Seconds()
	use := BudgetUse{
		Passes:      line("passes", budget.Passes, 1),
		Retries:     BudgetLine{Limit: budget.Retries, Used: 0, Status: CheckVerified, Detail: "started once; Run never restarts a request"},
		WallSeconds: line("wall_seconds", budget.WallSeconds, float64(int(elapsed*1000))/1000),
		USD:         line("usd", budget.USD, nil),
	}
	if receipt.CostUSD != nil {
		use.USD.Used = *receipt.CostUSD
	} else {
		use.USD.Status = USDUnknown
	}
	return use
}

// requiredChecks must all be verified for a receipt to be Verified.
var requiredChecks = map[string][]string{
	ProviderClaude: {"model", "tools", "mcp_servers", "permission_mode", "cwd", "result", "exit", "wall_seconds", "passes"},
	ProviderCodex:  {"thread", "items", "model", "approval_policy", "sandbox", "result", "exit", "wall_seconds", "passes"},
}

func finish(dir string, receipt Receipt) Receipt {
	status := map[string]string{}
	violated := false
	for _, check := range receipt.Checks {
		if check.Status == CheckViolated {
			violated = true
		}
		if _, seen := status[check.Name]; !seen || check.Status == CheckViolated {
			status[check.Name] = check.Status
		}
	}
	receipt.Verified = !violated
	for _, name := range requiredChecks[receipt.Binding.Provider] {
		if status[name] != CheckVerified {
			receipt.Verified = false
		}
	}
	encoded, _ := json.MarshalIndent(receipt, "", "  ")
	_ = writePrivate(filepath.Join(dir, "receipt.json"), encoded)
	return receipt
}

func eventLines(raw []byte) []map[string]any {
	var out []map[string]any
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64<<10), maxEventBytes)
	for scanner.Scan() {
		var event map[string]any
		if json.Unmarshal(scanner.Bytes(), &event) == nil {
			out = append(out, event)
		}
	}
	return out
}

func stringsOf(value any) ([]string, bool) {
	list, ok := value.([]any)
	if !ok {
		return nil, false
	}
	out := make([]string, 0, len(list))
	for _, x := range list {
		s, ok := x.(string)
		if !ok {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}

func compare(name string, got any, want string) Check {
	value, ok := got.(string)
	switch {
	case !ok || value == "":
		return Check{Name: name, Status: CheckUnverified, Detail: "not reported by the provider"}
	case value != want:
		return Check{Name: name, Status: CheckViolated, Detail: fmt.Sprintf("effective %q, planned %q", value, want)}
	}
	return Check{Name: name, Status: CheckVerified}
}

func verifyClaude(raw []byte, launch Launch, policy Policy, receipt *Receipt) []Check {
	var checks []Check
	var init, result map[string]any
	inits, results := 0, 0
	for _, event := range eventLines(raw) {
		switch event["type"] {
		case "system":
			if event["subtype"] == "init" {
				inits++
				if init == nil {
					init = event
				}
			}
		case "result":
			results++
			result = event
		case "assistant":
			message, _ := event["message"].(map[string]any)
			blocks, _ := message["content"].([]any)
			for _, block := range blocks {
				b, _ := block.(map[string]any)
				if b["type"] == "tool_use" {
					name, _ := b["name"].(string)
					if !slices.Contains(launch.AllowedTools, name) {
						checks = append(checks, Check{Name: "tool_use", Status: CheckViolated, Detail: "worker called " + name})
					}
				}
			}
		}
	}
	// One --print invocation is one pass: one session start and one result.
	switch {
	case inits > 1 || results > 1:
		checks = append(checks, Check{Name: "passes", Status: CheckViolated, Detail: fmt.Sprintf("%d session starts and %d results in one worker", inits, results)})
	case results == 1:
		checks = append(checks, Check{Name: "passes", Status: CheckVerified})
	default:
		checks = append(checks, Check{Name: "passes", Status: CheckUnverified, Detail: "the pass did not finish"})
	}
	if init == nil {
		return append(checks, Check{Name: "init", Status: CheckViolated, Detail: "no stream-json init event; effective settings unknown"},
			Check{Name: "usd", Status: CheckUnverified, Detail: USDUnknown + " (no result reported)"})
	}
	receipt.SessionID, _ = init["session_id"].(string)
	for _, key := range []string{"model", "permissionMode", "cwd", "tools", "mcp_servers"} {
		receipt.Effective[key] = init[key]
	}
	checks = append(checks, compare("model", init["model"], policy.Model), compare("permission_mode", init["permissionMode"], "dontAsk"), compare("cwd", init["cwd"], launch.Dir))
	if tools, ok := stringsOf(init["tools"]); !ok {
		checks = append(checks, Check{Name: "tools", Status: CheckUnverified, Detail: "tool list not reported"})
	} else {
		extra := []string{}
		for _, tool := range tools {
			if !slices.Contains(launch.AllowedTools, tool) {
				extra = append(extra, tool)
			}
		}
		if len(extra) > 0 {
			checks = append(checks, Check{Name: "tools", Status: CheckViolated, Detail: "worker has tools beyond the reader: " + strings.Join(extra, ",")})
		} else {
			checks = append(checks, Check{Name: "tools", Status: CheckVerified})
		}
	}
	servers, _ := init["mcp_servers"].([]any)
	connected := len(servers) == 1
	for _, server := range servers {
		s, _ := server.(map[string]any)
		connected = connected && s["name"] == ReaderServer && s["status"] == "connected"
	}
	if connected {
		checks = append(checks, Check{Name: "mcp_servers", Status: CheckVerified})
	} else {
		detail, _ := json.Marshal(servers)
		checks = append(checks, Check{Name: "mcp_servers", Status: CheckViolated, Detail: "expected only a connected evidence reader, got " + string(detail)})
	}
	checks = append(checks, Check{Name: "effort", Status: CheckUnverified, Detail: "Claude does not report effort in its init event"})
	if result == nil {
		return append(checks, Check{Name: "result", Status: CheckViolated, Detail: "no result event"}, Check{Name: "usd", Status: CheckUnverified, Detail: USDUnknown + " (no result reported)"})
	}
	receipt.Result, _ = result["result"].(string)
	if usage, ok := result["usage"].(map[string]any); ok {
		receipt.Usage = usage
	}
	if cost, ok := result["total_cost_usd"].(float64); ok {
		receipt.CostUSD = &cost
		if cost > policy.Budget.USD {
			checks = append(checks, Check{Name: "usd", Status: CheckViolated, Detail: fmt.Sprintf("cost %.4f exceeds %.4f", cost, policy.Budget.USD)})
		} else {
			checks = append(checks, Check{Name: "usd", Status: CheckVerified})
		}
	} else {
		checks = append(checks, Check{Name: "usd", Status: CheckUnverified, Detail: USDUnknown + " (Claude reported no cost)"})
	}
	if result["is_error"] == true || result["subtype"] != "success" {
		return append(checks, Check{Name: "result", Status: CheckViolated, Detail: fmt.Sprintf("result %v", result["subtype"])})
	}
	return append(checks, Check{Name: "result", Status: CheckVerified})
}

func verifyCodex(raw []byte, launch Launch, request Request, receipt *Receipt) []Check {
	var checks []Check
	threadID, completed, failure, final := "", false, "", ""
	turns := 0
	itemsOK := true
	for _, event := range eventLines(raw) {
		switch event["type"] {
		case "thread.started":
			if threadID == "" {
				threadID, _ = event["thread_id"].(string)
			}
		case "turn.started":
			turns++
		case "turn.completed":
			completed = true
			if usage, ok := event["usage"].(map[string]any); ok {
				receipt.Usage = usage
			}
		case "turn.failed", "error":
			failure = fmt.Sprint(event["error"], event["message"])
		case "item.started", "item.updated", "item.completed":
			item, _ := event["item"].(map[string]any)
			kind, _ := item["type"].(string)
			if kind == "" {
				kind, _ = item["item_type"].(string)
			}
			switch kind {
			case "agent_message":
				if event["type"] == "item.completed" {
					final, _ = item["text"].(string)
				}
			case "reasoning", "todo_list":
			case "mcp_tool_call":
				server, _ := item["server"].(string)
				tool, _ := item["tool"].(string)
				if server != ReaderServer || !slices.Contains(launch.AllowedTools, "mcp__"+server+"__"+tool) {
					itemsOK = false
					checks = append(checks, Check{Name: "items", Status: CheckViolated, Detail: fmt.Sprintf("worker called %s/%s", server, tool)})
				}
			default:
				// command_execution, file_change, web_search, collab_tool_call and
				// anything unknown are outside the reader-only scope.
				itemsOK = false
				checks = append(checks, Check{Name: "items", Status: CheckViolated, Detail: "worker produced a " + kind + " item"})
			}
		}
	}
	if threadID == "" {
		checks = append(checks, Check{Name: "thread", Status: CheckViolated, Detail: "no thread.started event"})
	} else {
		receipt.SessionID = threadID
		checks = append(checks, Check{Name: "thread", Status: CheckVerified})
	}
	if itemsOK {
		checks = append(checks, Check{Name: "items", Status: CheckVerified})
	}
	checks = append(checks, codexTurnContext(request, threadID, launch, receipt)...)
	receipt.Result = final
	switch {
	case failure != "":
		checks = append(checks, Check{Name: "result", Status: CheckViolated, Detail: "turn failed: " + failure})
	case !completed:
		checks = append(checks, Check{Name: "result", Status: CheckViolated, Detail: "no turn.completed event"})
	default:
		checks = append(checks, Check{Name: "result", Status: CheckVerified})
	}
	// One codex exec run with one prompt is one pass: exactly one turn.
	switch {
	case turns > 1:
		checks = append(checks, Check{Name: "passes", Status: CheckViolated, Detail: fmt.Sprintf("%d turns in one worker", turns)})
	case turns == 1 && completed:
		checks = append(checks, Check{Name: "passes", Status: CheckVerified})
	default:
		checks = append(checks, Check{Name: "passes", Status: CheckUnverified, Detail: "the pass did not finish"})
	}
	return append(checks, Check{Name: "usd", Status: CheckUnverified, Detail: USDUnknown + " (Codex reports tokens, not cost)"})
}

// codexTurnContext reads the effective settings Codex recorded for the thread.
func codexTurnContext(request Request, threadID string, launch Launch, receipt *Receipt) []Check {
	unverified := func(detail string) []Check {
		var out []Check
		for _, name := range []string{"model", "approval_policy", "sandbox", "effort"} {
			out = append(out, Check{Name: name, Status: CheckUnverified, Detail: detail})
		}
		return out
	}
	if request.CodexHome == "" || threadID == "" || !regexp.MustCompile(`^[0-9a-f-]{8,64}$`).MatchString(threadID) {
		return unverified("no Codex rollout to read")
	}
	matches, _ := filepath.Glob(filepath.Join(request.CodexHome, "sessions", "*", "*", "*", "rollout-*-"+threadID+".jsonl"))
	if len(matches) != 1 {
		return codexThreadState(request, threadID, launch, receipt, unverified)
	}
	file, err := os.Open(matches[0])
	if err != nil {
		return unverified("Codex rollout unreadable")
	}
	defer file.Close()
	var context map[string]any
	scanner := bufio.NewScanner(io.LimitReader(file, 64<<20))
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	for scanner.Scan() {
		var line struct {
			Type    string         `json:"type"`
			Payload map[string]any `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &line) == nil && line.Type == "turn_context" {
			context = line.Payload
		}
	}
	if context == nil {
		return codexThreadState(request, threadID, launch, receipt, unverified)
	}
	sandbox, _ := context["sandbox_policy"].(map[string]any)
	receipt.Effective = map[string]any{"model": context["model"], "approval_policy": context["approval_policy"], "sandbox_policy": sandbox, "effort": context["effort"], "cwd": context["cwd"]}
	return []Check{
		compare("model", context["model"], request.Policy.Model),
		compare("approval_policy", context["approval_policy"], "never"),
		compare("sandbox", sandbox["type"], "read-only"),
		compare("effort", context["effort"], request.Policy.Effort),
		compare("cwd", context["cwd"], launch.Dir),
	}
}
