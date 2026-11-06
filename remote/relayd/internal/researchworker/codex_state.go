package researchworker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"time"
)

// codexThreadState reads the settings Codex keeps for a paginated thread.
// Codex 0.164+ rollouts in paginated history carry no turn_context; the
// thread's model, effort, sandbox, approval, cwd and source live in the
// threads row of $CODEX_HOME/state_N.sqlite, and sub-agents it spawned in
// thread_spawn_edges. The database is opened read-only through the sqlite3
// CLI, which also reads its WAL (where fresh rows are). This is Codex's own
// per-thread record, not a per-turn one.
func codexThreadState(request Request, threadID string, launch Launch, receipt *Receipt, unverified func(string) []Check) []Check {
	if request.SQLite3 == "" {
		return unverified("rollout has no turn_context and no sqlite3 was given to read Codex thread state")
	}
	databases, _ := filepath.Glob(filepath.Join(request.CodexHome, "state_*.sqlite"))
	if len(databases) != 1 {
		return unverified(fmt.Sprintf("expected one Codex state database, found %d", len(databases)))
	}
	query := func(sql string) ([]map[string]any, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, request.SQLite3, "-readonly", "-json", "file:"+databases[0]+"?mode=ro", sql).Output()
		if err != nil {
			return nil, err
		}
		rows := []map[string]any{}
		if len(bytes.TrimSpace(out)) == 0 {
			return rows, nil
		}
		return rows, json.Unmarshal(out, &rows)
	}
	// threadID already matched ^[0-9a-f-]{8,64}$, so it cannot break out of
	// the quoted literal.
	rows, err := query("select model, reasoning_effort, sandbox_policy, approval_mode, cwd, source, cli_version from threads where id = '" + threadID + "'")
	if err != nil || len(rows) != 1 {
		return unverified("thread not found in the Codex state database")
	}
	row := rows[0]
	sandbox := map[string]any{}
	if text, ok := row["sandbox_policy"].(string); ok {
		_ = json.Unmarshal([]byte(text), &sandbox)
	}
	receipt.Effective = map[string]any{"source": "codex_thread_state", "model": row["model"], "reasoning_effort": row["reasoning_effort"],
		"sandbox_policy": sandbox, "approval_mode": row["approval_mode"], "cwd": row["cwd"], "thread_source": row["source"], "cli_version": row["cli_version"]}
	checks := []Check{
		compare("model", row["model"], request.Policy.Model),
		compare("approval_policy", row["approval_mode"], "never"),
		compare("sandbox", sandbox["type"], "read-only"),
		compare("effort", row["reasoning_effort"], request.Policy.Effort),
		compare("cwd", row["cwd"], launch.Dir),
		compare("thread_source", row["source"], "exec"),
	}
	children, err := query("select count(*) as n from thread_spawn_edges where parent_thread_id = '" + threadID + "'")
	switch {
	case err != nil || len(children) != 1:
		checks = append(checks, Check{Name: "sub_agents", Status: CheckUnverified, Detail: "could not read spawned threads"})
	case children[0]["n"] != float64(0):
		checks = append(checks, Check{Name: "sub_agents", Status: CheckViolated, Detail: fmt.Sprintf("worker spawned %v sub-agent threads", children[0]["n"])})
	default:
		checks = append(checks, Check{Name: "sub_agents", Status: CheckVerified})
	}
	return checks
}
