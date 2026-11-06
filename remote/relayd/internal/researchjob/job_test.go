package researchjob

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/researchworker"
)

const (
	contract  = "c70e78fa89c0ba9c5bfdac261c74b83fb954d6a984cfcd9c3af0143dce4dc3c8"
	requestID = "6f1d2c3b-4a59-4e7d-8c1b-2a3f4e5d6c7b"
	thread    = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001"
)

// TestMain lets the test binary stand in for a provider (no model call).
func TestMain(m *testing.M) {
	if scenario := os.Getenv("FAKE_JOB_SCENARIO"); scenario != "" {
		os.Exit(fakeProvider(scenario))
	}
	os.Exit(m.Run())
}

func fakeProvider(scenario string) int {
	prompt, _ := io.ReadAll(os.Stdin)
	if path := os.Getenv("FAKE_JOB_LOG"); path != "" {
		f, _ := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		_, _ = f.WriteString(string(prompt) + "\n")
		f.Close()
	}
	cwd, _ := os.Getwd()
	emit := func(v any) { b, _ := json.Marshal(v); os.Stdout.Write(append(b, '\n')) }
	model := ""
	for i, a := range os.Args {
		if (a == "--model" || a == "-m") && i+1 < len(os.Args) {
			model = os.Args[i+1]
		}
	}
	switch scenario {
	case "hang":
		time.Sleep(30 * time.Second)
		return 0
	case "exit-1":
		return 1
	case "codex-ok":
		emit(map[string]any{"type": "thread.started", "thread_id": thread})
		emit(map[string]any{"type": "turn.started"})
		emit(map[string]any{"type": "item.completed", "item": map[string]any{"type": "agent_message", "text": "codex answer"}})
		emit(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 100, "output_tokens": 20}})
		return 0
	}
	emit(map[string]any{"type": "system", "subtype": "init", "session_id": "sess-1", "cwd": cwd, "model": model, "permissionMode": "dontAsk",
		"tools": []string{"mcp__evidence__list", "mcp__evidence__read", "mcp__evidence__search"}, "mcp_servers": []any{map[string]any{"name": "evidence", "status": "connected"}}})
	result := map[string]any{"type": "result", "subtype": "success", "is_error": false, "result": "answer to " + string(prompt), "session_id": "sess-1", "total_cost_usd": 0.42, "usage": map[string]any{"input_tokens": 100}}
	if scenario == "error-result" {
		result["subtype"], result["is_error"] = "error_during_execution", true
	}
	emit(result)
	return 0
}

type env struct {
	jobs, workers, cwd, log string
	manager                 *Manager
}

func privateDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "d")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{jobs: privateDir(t), workers: privateDir(t), cwd: t.TempDir(), log: filepath.Join(t.TempDir(), "runs.log")}
	if real, err := filepath.EvalSymlinks(e.cwd); err == nil {
		e.cwd = real
	}
	m, err := NewManager(e.jobs, e.workers)
	if err != nil {
		t.Fatal(err)
	}
	e.manager = m
	return e
}

func (e *env) request(provider, scenario string) researchworker.Request {
	self, _ := os.Executable()
	model, effort := "claude-opus-5-5", "high"
	if provider == researchworker.ProviderCodex {
		model = "gpt-6"
	}
	return researchworker.Request{RequestID: requestID, Prompt: "Summarise S001", Env: append(os.Environ(), "FAKE_JOB_SCENARIO="+scenario, "FAKE_JOB_LOG="+e.log),
		Policy: researchworker.Policy{Provider: provider, Executable: self, Model: model, Effort: effort, Cwd: e.cwd, ContractSHA256: contract,
			Reader: researchworker.EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", strings.Repeat("a", 64), contract),
			Budget: researchworker.DefaultBudget}}
}

func (e *env) runs() int {
	raw, _ := os.ReadFile(e.log)
	return strings.Count(string(raw), "\n")
}

func wait(t *testing.T, m *Manager, jobID string) Job {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	job, err := m.Wait(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	return job
}

func TestJobCompletesWithATerminalRecord(t *testing.T) {
	e := newEnv(t)
	job, admitted, err := e.manager.Admit(e.request(researchworker.ProviderClaude, "ok"))
	if err != nil || !admitted || !uuidPattern.MatchString(job.JobID) || job.RequestID != requestID || (job.State != StateAdmitted && job.State != StateRunning) {
		t.Fatalf("admit: %v %v %+v", err, admitted, job)
	}
	done := wait(t, e.manager, job.JobID)
	if done.State != StateCompleted || done.TurnID != "sess-1" || done.Result == nil || *done.Result != "answer to Summarise S001" || !done.Verified {
		t.Fatalf("terminal %+v", done)
	}
	if done.ContractSHA256 != contract || done.Binding.ContractSHA256 != contract || done.Binding.PromptSHA256 == "" {
		t.Fatalf("contract binding %+v", done.Binding)
	}
	if done.StartedAt == nil || done.EndedAt == nil || done.DurationMS == nil || done.StartedAt.Before(done.AdmittedAt.Add(-time.Second)) || done.EndedAt.Before(*done.StartedAt) || *done.DurationMS < 0 {
		t.Fatalf("timings %+v", done)
	}
	if done.EffectiveSettings["model"] != "claude-opus-5-5" || done.Cost.USD == nil || *done.Cost.USD != 0.42 || done.Cost.Status != researchworker.CheckVerified {
		t.Fatalf("settings/cost %+v %+v", done.EffectiveSettings, done.Cost)
	}
	if usage, ok := done.Usage.(map[string]any); !ok || usage["input_tokens"] != float64(100) {
		t.Fatalf("usage %v", done.Usage)
	}
	byRequest, err := e.manager.GetByRequest(requestID)
	if err != nil || byRequest.JobID != job.JobID || byRequest.State != StateCompleted {
		t.Fatalf("by request %v %+v", err, byRequest)
	}
	// The durable record is what queries return, also from a fresh manager.
	fresh, _ := NewManager(e.jobs, e.workers)
	again, err := fresh.Get(job.JobID)
	if err != nil || again.State != StateCompleted || again.TurnID != "sess-1" || *again.Result != *done.Result {
		t.Fatalf("fresh manager %v %+v", err, again)
	}
	info, _ := os.Stat(filepath.Join(e.jobs, "requests", requestID+".json"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("record mode %v", info.Mode())
	}
}

func TestAdmissionIsIdempotentOnRequestID(t *testing.T) {
	e := newEnv(t)
	request := e.request(researchworker.ProviderClaude, "ok")
	first, _, err := e.manager.Admit(request)
	if err != nil {
		t.Fatal(err)
	}
	second, admitted, err := e.manager.Admit(request)
	if err != nil || admitted || second.JobID != first.JobID {
		t.Fatalf("second admit: %v %v %s", err, admitted, second.JobID)
	}
	wait(t, e.manager, first.JobID)
	third, admitted, err := e.manager.Admit(request)
	if err != nil || admitted || third.JobID != first.JobID || third.State != StateCompleted {
		t.Fatalf("admit after completion: %v %v %+v", err, admitted, third)
	}
	changed := request
	changed.Prompt = "Another question"
	if _, _, err := e.manager.Admit(changed); !errors.Is(err, ErrBoundToMore) {
		t.Fatalf("other prompt: %v", err)
	}
	changed = e.request(researchworker.ProviderClaude, "ok")
	changed.Policy.Budget.WallSeconds = 60
	if _, _, err := e.manager.Admit(changed); !errors.Is(err, ErrBoundToMore) {
		t.Fatalf("other budget: %v", err)
	}
	if e.runs() != 1 {
		t.Fatalf("worker ran %d times", e.runs())
	}
}

func TestCancelKillsARunningJob(t *testing.T) {
	e := newEnv(t)
	job, _, err := e.manager.Admit(e.request(researchworker.ProviderClaude, "hang"))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for e.runs() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if current, _ := e.manager.Get(job.JobID); current.State != StateRunning {
		t.Fatalf("not running: %+v", current)
	}
	asked, err := e.manager.Cancel(job.JobID)
	if err != nil || asked.CancelRequestedAt == nil {
		t.Fatalf("cancel: %v %+v", err, asked)
	}
	started := time.Now()
	done := wait(t, e.manager, job.JobID)
	if time.Since(started) > 5*time.Second || done.State != StateCancelled || done.Result != nil || done.Verified || done.CancelRequestedAt == nil || done.EndedAt == nil {
		t.Fatalf("cancelled job %+v", done)
	}
	again, err := e.manager.Cancel(job.JobID)
	if err != nil || again.State != StateCancelled || e.runs() != 1 {
		t.Fatalf("second cancel %v %+v", err, again)
	}
}

func TestCancelBeforeStartRunsNothingAndCancelAfterEndChangesNothing(t *testing.T) {
	e := newEnv(t)
	release := make(chan struct{})
	e.manager.run = func(ctx context.Context, r researchworker.Request) (researchworker.Receipt, error) {
		<-release
		return researchworker.Run(ctx, r)
	}
	job, _, _ := e.manager.Admit(e.request(researchworker.ProviderClaude, "ok"))
	if _, err := e.manager.Cancel(job.JobID); err != nil {
		t.Fatal(err)
	}
	close(release)
	done := wait(t, e.manager, job.JobID)
	if done.State != StateCancelled || e.runs() != 0 {
		t.Fatalf("cancel before start: %+v runs=%d", done, e.runs())
	}

	e2 := newEnv(t)
	job, _, _ = e2.manager.Admit(e2.request(researchworker.ProviderClaude, "ok"))
	completed := wait(t, e2.manager, job.JobID)
	after, err := e2.manager.Cancel(job.JobID)
	if err != nil || after.State != StateCompleted || after.CancelRequestedAt != nil || *after.Result != *completed.Result {
		t.Fatalf("cancel after completion changed the record: %v %+v", err, after)
	}
}

func TestTimeoutAndFailureAreTerminal(t *testing.T) {
	e := newEnv(t)
	request := e.request(researchworker.ProviderClaude, "hang")
	request.Policy.Budget.WallSeconds = 1
	job, _, _ := e.manager.Admit(request)
	done := wait(t, e.manager, job.JobID)
	if done.State != StateTimeout || done.Result != nil || done.Verified || done.Budget.WallSeconds.Status != researchworker.CheckViolated {
		t.Fatalf("timeout %+v", done)
	}
	for scenario, want := range map[string]string{"error-result": "result", "exit-1": ""} {
		e := newEnv(t)
		job, _, _ := e.manager.Admit(e.request(researchworker.ProviderClaude, scenario))
		done := wait(t, e.manager, job.JobID)
		if done.State != StateFailed || done.Verified || done.Failure == "" || !strings.Contains(done.Failure, want) {
			t.Fatalf("%s: %+v", scenario, done)
		}
	}
}

func TestCodexJobCarriesExplicitUnknownCost(t *testing.T) {
	e := newEnv(t)
	job, _, _ := e.manager.Admit(e.request(researchworker.ProviderCodex, "codex-ok"))
	done := wait(t, e.manager, job.JobID)
	if done.State != StateCompleted || done.TurnID != thread || *done.Result != "codex answer" {
		t.Fatalf("codex job %+v", done)
	}
	if done.Cost.USD != nil || done.Cost.Status != researchworker.USDUnknown || done.Budget.USD.Status != researchworker.USDUnknown {
		t.Fatalf("cost must be explicit unknown: %+v", done.Cost)
	}
	if usage, ok := done.Usage.(map[string]any); !ok || usage["output_tokens"] != float64(20) {
		t.Fatalf("usage %v", done.Usage)
	}
	// Completed is not verified: without a Codex rollout or state database
	// the settings stay unverified, and the record says so.
	if done.Verified || done.ScopeEnforcement != researchworker.EnforcementPartial {
		t.Fatalf("codex verification %+v", done)
	}
}

func TestQueryAndCancelTakeOnlyExactIDs(t *testing.T) {
	e := newEnv(t)
	job, _, _ := e.manager.Admit(e.request(researchworker.ProviderClaude, "ok"))
	wait(t, e.manager, job.JobID)
	for _, id := range []string{"", strings.ToUpper(job.JobID), job.JobID[:8], job.JobID + " ", "../requests/" + requestID, "*"} {
		if _, err := e.manager.Get(id); !errors.Is(err, ErrInvalidID) {
			t.Fatalf("Get(%q): %v", id, err)
		}
		if _, err := e.manager.Cancel(id); !errors.Is(err, ErrInvalidID) {
			t.Fatalf("Cancel(%q): %v", id, err)
		}
	}
	for _, id := range []string{requestID, "00000000-0000-4000-8000-000000000000"} {
		if _, err := e.manager.Get(id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Get(%q) found something: %v", id, err)
		}
		if _, err := e.manager.Cancel(id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Cancel(%q): %v", id, err)
		}
	}
	if _, err := e.manager.GetByRequest(job.JobID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("job_id accepted as request_id: %v", err)
	}
	if _, err := e.manager.GetByRequest(strings.ToUpper(requestID)); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("uppercase request_id: %v", err)
	}
}

func TestAStoppedRunnerIsReportedUnknownAndNeverRestarted(t *testing.T) {
	e := newEnv(t)
	block := make(chan struct{})
	var jobID string
	t.Cleanup(func() {
		close(block)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = e.manager.Wait(ctx, jobID)
	})
	e.manager.run = func(ctx context.Context, r researchworker.Request) (researchworker.Receipt, error) {
		<-block
		return researchworker.Receipt{}, errors.New("stopped")
	}
	job, _, _ := e.manager.Admit(e.request(researchworker.ProviderClaude, "ok"))
	jobID = job.JobID
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if j, _ := e.manager.Get(job.JobID); j.State == StateRunning {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	// A new manager (as after a restart) finds a running record with no runner.
	restarted, _ := NewManager(e.jobs, e.workers)
	got, err := restarted.Get(job.JobID)
	if err != nil || got.State != StateUnknown || !strings.Contains(got.Failure, "not started again") {
		t.Fatalf("restart: %v %+v", err, got)
	}
	again, admitted, err := restarted.Admit(e.request(researchworker.ProviderClaude, "ok"))
	if err != nil || admitted || again.JobID != job.JobID || again.State != StateUnknown || e.runs() != 0 {
		t.Fatalf("unknown job restarted: %v %v %+v runs=%d", err, admitted, again, e.runs())
	}
	if _, err := restarted.Cancel(job.JobID); err != nil {
		t.Fatal(err)
	}
}

func TestARestartSettlesFromTheWorkerReceipt(t *testing.T) {
	e := newEnv(t)
	job, _, _ := e.manager.Admit(e.request(researchworker.ProviderClaude, "ok"))
	done := wait(t, e.manager, job.JobID)
	// Simulate a manager that stopped after the worker wrote its receipt but
	// before the job record became terminal.
	stale := done
	stale.State, stale.Result, stale.EndedAt, stale.TurnID = StateRunning, nil, nil, ""
	encoded, _ := json.Marshal(stale)
	_ = os.WriteFile(filepath.Join(e.jobs, "requests", requestID+".json"), encoded, 0o600)
	restarted, _ := NewManager(e.jobs, e.workers)
	got, err := restarted.Get(job.JobID)
	if err != nil || got.State != StateCompleted || got.TurnID != "sess-1" || got.Result == nil || e.runs() != 1 {
		t.Fatalf("settle from receipt: %v %+v", err, got)
	}
}

func TestManagerRefusesSharedRootsAndBadRequests(t *testing.T) {
	open := filepath.Join(t.TempDir(), "open")
	_ = os.Mkdir(open, 0o755)
	_ = os.Chmod(open, 0o755)
	if _, err := NewManager(open, privateDir(t)); err == nil {
		t.Fatal("shared jobs root accepted")
	}
	if _, err := NewManager(privateDir(t), "relative"); err == nil {
		t.Fatal("relative workers root accepted")
	}
	e := newEnv(t)
	for name, edit := range map[string]func(*researchworker.Request){
		"bad request id": func(r *researchworker.Request) { r.RequestID = "x" },
		"empty prompt":   func(r *researchworker.Request) { r.Prompt = "" },
		"two passes":     func(r *researchworker.Request) { r.Policy.Budget.Passes = 2 },
		"bad contract":   func(r *researchworker.Request) { r.Policy.ContractSHA256 = "abc" },
	} {
		request := e.request(researchworker.ProviderClaude, "ok")
		edit(&request)
		if _, _, err := e.manager.Admit(request); err == nil {
			t.Fatalf("%s admitted", name)
		}
	}
	entries, _ := os.ReadDir(filepath.Join(e.jobs, "jobs"))
	if len(entries) != 0 || e.runs() != 0 {
		t.Fatal("a refused request created a job or started a worker")
	}
}
