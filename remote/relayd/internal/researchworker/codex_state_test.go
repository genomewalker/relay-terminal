package researchworker

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func sqliteCLI(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Skip("sqlite3 CLI not installed")
	}
	path, _ = filepath.Abs(path)
	return path
}

// stateDB writes a Codex-shaped state_5.sqlite (the columns read, from Codex
// 0.166.0's schema) and a paginated rollout that has no turn_context.
func (h *harness) stateDB(t *testing.T, sqlite, model, effort, sandbox, approval, cwd, source string, children int) {
	t.Helper()
	h.codexHome = t.TempDir()
	dir := filepath.Join(h.codexHome, "sessions", "2026", "11", "06")
	_ = os.MkdirAll(dir, 0o700)
	_ = os.WriteFile(filepath.Join(dir, "rollout-2026-11-06T00-00-00-"+fakeThread+".jsonl"),
		[]byte(`{"type":"session_meta","payload":{"id":"`+fakeThread+`","history_mode":"paginated"}}`+"\n"), 0o600)
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	sql := "pragma journal_mode=wal;" +
		"create table threads (id text primary key, rollout_path text not null, source text not null, cwd text not null, sandbox_policy text not null, approval_mode text not null, cli_version text not null default '', model text, reasoning_effort text, history_mode text not null default 'legacy');" +
		"create table thread_spawn_edges (parent_thread_id text not null, child_thread_id text not null primary key, status text not null);" +
		"insert into threads values (" + strings.Join([]string{quote(fakeThread), quote("rollout"), quote(source), quote(cwd), quote(sandbox), quote(approval), quote("0.166.0"), quote(model), quote(effort), quote("paginated")}, ",") + ");" +
		"insert into threads values ('0199aaaa-0000-7000-8000-000000000999','r','exec','/','{\"type\":\"disabled\"}','never','0.166.0','other','low','paginated');"
	for i := 0; i < children; i++ {
		sql += "insert into thread_spawn_edges values (" + quote(fakeThread) + ",'child-" + string(rune('a'+i)) + "','completed');"
	}
	if out, err := exec.Command(sqlite, filepath.Join(h.codexHome, "state_5.sqlite"), sql).CombinedOutput(); err != nil {
		t.Fatalf("fixture db: %v %s", err, out)
	}
}

func TestCodexPaginatedThreadStateIsVerified(t *testing.T) {
	sqlite := sqliteCLI(t)
	h := newHarness(t)
	h.stateDB(t, sqlite, "gpt-6", "high", `{"type":"read-only"}`, "never", h.cwd, "exec", 0)
	request := h.request(t, ProviderCodex, "ok")
	request.SQLite3 = sqlite
	receipt, err := Run(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"model", "approval_policy", "sandbox", "effort", "cwd", "thread_source", "sub_agents", "thread", "items", "result"} {
		if status(receipt, name) != CheckVerified {
			t.Fatalf("%s = %q %+v", name, status(receipt, name), receipt.Checks)
		}
	}
	if !receipt.Verified || receipt.Effective["source"] != "codex_thread_state" || receipt.Effective["cli_version"] != "0.166.0" {
		t.Fatalf("receipt %+v", receipt)
	}
	// Without sqlite3 the same paginated thread stays unverified.
	h2 := newHarness(t)
	h2.stateDB(t, sqlite, "gpt-6", "high", `{"type":"read-only"}`, "never", h2.cwd, "exec", 0)
	receipt, _ = Run(context.Background(), h2.request(t, ProviderCodex, "ok"))
	if receipt.Verified || status(receipt, "sandbox") != CheckUnverified {
		t.Fatalf("no sqlite3: %+v", receipt.Checks)
	}
}

func TestCodexPaginatedThreadStateViolations(t *testing.T) {
	sqlite := sqliteCLI(t)
	type row struct {
		model, effort, sandbox, approval, source string
		children                                 int
	}
	good := row{"gpt-6", "high", `{"type":"read-only"}`, "never", "exec", 0}
	cases := map[string]struct {
		edit  func(*row)
		check string
	}{
		"full access":      {func(r *row) { r.sandbox = `{"type":"disabled"}` }, "sandbox"},
		"workspace write":  {func(r *row) { r.sandbox = `{"type":"workspace-write"}` }, "sandbox"},
		"approval asks":    {func(r *row) { r.approval = "on-request" }, "approval_policy"},
		"other model":      {func(r *row) { r.model = "gpt-6-mini" }, "model"},
		"other effort":     {func(r *row) { r.effort = "low" }, "effort"},
		"interactive":      {func(r *row) { r.source = "vscode" }, "thread_source"},
		"spawned subagent": {func(r *row) { r.children = 2 }, "sub_agents"},
	}
	for name, c := range cases {
		r := good
		c.edit(&r)
		h := newHarness(t)
		h.stateDB(t, sqlite, r.model, r.effort, r.sandbox, r.approval, h.cwd, r.source, r.children)
		request := h.request(t, ProviderCodex, "ok")
		request.SQLite3 = sqlite
		receipt, err := Run(context.Background(), request)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if receipt.Verified || status(receipt, c.check) != CheckViolated {
			t.Fatalf("%s: verified=%v %s=%q", name, receipt.Verified, c.check, status(receipt, c.check))
		}
	}
	// A thread missing from the database, and a relative sqlite3 path.
	h := newHarness(t)
	h.stateDB(t, sqlite, "gpt-6", "high", `{"type":"read-only"}`, "never", h.cwd, "exec", 0)
	_, _ = exec.Command(sqlite, filepath.Join(h.codexHome, "state_5.sqlite"), "delete from threads where id='"+fakeThread+"'").CombinedOutput()
	request := h.request(t, ProviderCodex, "ok")
	request.SQLite3 = sqlite
	receipt, _ := Run(context.Background(), request)
	if receipt.Verified || status(receipt, "model") != CheckUnverified {
		t.Fatalf("missing thread: %+v", receipt.Checks)
	}
	request = newHarness(t).request(t, ProviderCodex, "ok")
	request.SQLite3 = "sqlite3"
	if _, err := Run(context.Background(), request); err == nil {
		t.Fatal("relative sqlite3 accepted")
	}
}

// Opt-in, read-only check against a real Codex home: RELAY_CODEX_STATE_HOME
// and RELAY_CODEX_STATE_THREAD name an existing exec thread. It only reads the
// state database (through sqlite3 -readonly) and prints what was found.
func TestCodexThreadStateReadsARealCodexHome(t *testing.T) {
	home, thread := os.Getenv("RELAY_CODEX_STATE_HOME"), os.Getenv("RELAY_CODEX_STATE_THREAD")
	if home == "" || thread == "" {
		t.Skip("set RELAY_CODEX_STATE_HOME and RELAY_CODEX_STATE_THREAD to read a real Codex state database")
	}
	sqlite := sqliteCLI(t)
	p := basePolicy(ProviderCodex)
	launch, err := Plan(p, testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	receipt := &Receipt{Effective: map[string]any{}}
	none := func(detail string) []Check { t.Fatalf("thread state not read: %s", detail); return nil }
	checks := codexThreadState(Request{Policy: p, CodexHome: home, SQLite3: sqlite}, thread, launch, receipt, none)
	if receipt.Effective["source"] != "codex_thread_state" || receipt.Effective["model"] == nil || receipt.Effective["sandbox_policy"] == nil {
		t.Fatalf("no settings read: %+v", receipt.Effective)
	}
	t.Logf("effective %v", receipt.Effective)
	for _, c := range checks {
		t.Logf("%s %s %s", c.Name, c.Status, c.Detail)
	}
}
