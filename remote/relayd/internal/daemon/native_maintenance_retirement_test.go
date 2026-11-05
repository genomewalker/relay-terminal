package daemon

// This file retains the expressions and concrete negatives of the retired
// maintenance/account/reviewer tests. References M/A/R index the archived
// originals and their per-expression crosswalk, rather than a name-only count.
import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func mrEq(t *testing.T, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v; want %#v", got, want)
	}
}
func mrHas(t *testing.T, words []string, s string, want bool) {
	t.Helper()
	mrEq(t, phContains(words, s), want)
}
func mrRaise(t *testing.T, text string, fn func()) {
	t.Helper()
	e := phRaised(t, fn)
	if e == nil || e.kind != phValueError || (text != "" && !strings.Contains(e.msg, text)) {
		t.Fatalf("exception %+v; want substring %q", e, text)
	}
}
func mrContext() *pyObject {
	return pyObj("approval_policy", "never", "sandbox_policy", pyObj("type", "danger-full-access"), "model", "gpt-rosalind-5.5", "effort", "high", "cwd", "/exact/current directory")
}
func mrCodex(argv []string, policy *pyObject, launcher []string, remote string, linux, task bool) []string {
	return phShlexSplit(phCodexResumeCommand(argv, "session-123", policy, launcher, remote, linux, task))
}
func TestNativeMaintenanceOriginalResumeAssertions(t *testing.T) {
	launcher := []string{"/home/test/.local/bin/codex"}
	t.Run("M17_claude_resume_configuration", func(t *testing.T) {
		args := []string{"claude", "--settings", "/private/hooks with spaces.json", "--dangerously-skip-permissions", "--model", "claude-opus-5-5", "--effort", "high", "--permission-mode", "bypassPermissions", "--resume", "old-session", "--add-dir", "/work/shared"}
		got := phShlexSplit(phClaudeResumeCommand(args, "exact-session", []string{"relayd", "agent", "claude"}, ""))
		mrEq(t, got[:3], []string{"relayd", "agent", "claude"})
		mrEq(t, got[3:len(got)-2], []string{"--settings", "/private/hooks with spaces.json", "--dangerously-skip-permissions", "--model", "claude-opus-5-5", "--effort", "high", "--permission-mode", "bypassPermissions", "--add-dir", "/work/shared"})
		mrEq(t, got[len(got)-2:], []string{"--resume", "exact-session"})
		mrHas(t, got, "old-session", false)
	})
	t.Run("M18_claude_no_replay", func(t *testing.T) {
		for _, args := range [][]string{{"claude", "original scientific prompt"}, {"claude", "--unknown", "value"}, {"claude", "--resume"}, {"claude", "--settings"}, {"claude", "--print"}} {
			mrRaise(t, "", func() { phClaudeResumeCommand(args, "exact-session", []string{"relayd", "agent", "claude"}, "") })
		}
		mrRaise(t, "Invalid Claude launch argument", func() {
			phClaudeResumeCommand([]string{"claude", "--settings", "line\nbreak"}, "exact-session", []string{"relayd", "agent", "claude"}, "")
		})
	})
	t.Run("M19_claude_literal_argument", func(t *testing.T) {
		v := "Literal $(touch /never-execute) and `id`"
		got := phShlexSplit(phClaudeResumeCommand([]string{"claude", "--append-system-prompt", v}, "exact-session", []string{"relayd", "agent", "claude"}, ""))
		mrEq(t, got[4], v)
	})
	t.Run("M33_managed_proxy_and_exact_policy", func(t *testing.T) {
		got := mrCodex([]string{"native-codex", "--profile", "relay-terminal", "--remote", "unix:///private/exact.sock", "resume", "previous", "--model", "old", "--full-auto"}, mrContext(), launcher, "unix:///private/exact.sock", false, false)
		mrEq(t, got[:3], []string{launcher[0], "--profile", "relay-terminal"})
		mrEq(t, got[len(got)-2:], []string{"resume", "session-123"})
		for _, s := range []string{"--remote", "previous", "old"} {
			mrHas(t, got, s, false)
		}
		n := 0
		for _, s := range got {
			if s == "--model" {
				n++
			}
		}
		mrEq(t, n, 1)
		for _, s := range []string{"danger-full-access", "never", `model_reasoning_effort="high"`, "/exact/current directory"} {
			mrHas(t, got, s, true)
		}
	})
	t.Run("M34_no_initial_prompt_or_unknown_launch", func(t *testing.T) {
		for _, argv := range [][]string{{"codex", "fix this"}, {"codex", "exec", "session"}, {"codex", "-c", `api_key="secret"`}, {"codex", "--remote", "wss://example.com"}, {"codex", "--profile"}} {
			mrRaise(t, "", func() { mrCodex(argv, mrContext(), launcher, "", false, false) })
		}
	})
	t.Run("M35_literal_cwd", func(t *testing.T) {
		ctx := mrContext()
		ctx.Set("cwd", "/a path/$(do-not-run)`also-not`")
		got := mrCodex([]string{"codex", "--cd", "/old/path"}, ctx, launcher, "", false, false)
		mrHas(t, got, "/a path/$(do-not-run)`also-not`", true)
		mrHas(t, got, "/old/path", false)
	})
	t.Run("M36_workspace_roots_network_temp", func(t *testing.T) {
		ctx := mrContext()
		policy := pyObj("type", "workspace-write", "writable_roots", pyListOf("/exact root"), "network_access", false, "exclude_tmpdir_env_var", true, "exclude_slash_tmp", true)
		ctx.Set("approval_policy", "on-request")
		ctx.Set("sandbox_policy", policy)
		got := mrCodex([]string{"codex"}, ctx, launcher, "", false, false)
		for _, s := range []string{"/exact root", "sandbox_workspace_write.network_access=false", "sandbox_workspace_write.exclude_slash_tmp=true"} {
			mrHas(t, got, s, true)
		}
		policy.Set("unknown_future_restriction", true)
		mrRaise(t, "", func() { mrCodex([]string{"codex"}, ctx, launcher, "", false, false) })
	})
	t.Run("M37_permissions_required", func(t *testing.T) {
		for _, key := range []string{"approval_policy", "sandbox_policy", "cwd"} {
			ctx := mrContext()
			ctx.Delete(key)
			mrRaise(t, "", func() { mrCodex([]string{"codex"}, ctx, launcher, "", false, false) })
		}
	})
	t.Run("M42_native_launcher_retained", func(t *testing.T) {
		got := mrCodex([]string{"codex"}, mrContext(), []string{"/exact/relayd", "agent", "codex"}, "", false, false)
		mrEq(t, got[:3], []string{"/exact/relayd", "agent", "codex"})
	})
	t.Run("M43_remote_saved_permissions", func(t *testing.T) {
		ctx := mrContext()
		ctx.Set("sandbox_policy", pyObj("type", "workspace-write"))
		got := mrCodex([]string{"codex", "--ask-for-approval", "on-request", "--sandbox", "read-only"}, ctx, []string{"/exact/relayd", "agent", "codex"}, "", false, true)
		mrEq(t, got[:3], []string{"/exact/relayd", "agent", "codex"})
		mrEq(t, got[len(got)-2:], []string{"resume", "session-123"})
		for _, s := range []string{"/exact/current directory", "gpt-rosalind-5.5"} {
			mrHas(t, got, s, true)
		}
		for _, s := range []string{"--ask-for-approval", "--sandbox", "--add-dir"} {
			mrHas(t, got, s, false)
		}
		for _, s := range got {
			if strings.HasPrefix(s, "sandbox_workspace_write.") {
				t.Fatal("remote policy override", got)
			}
		}
	})
	t.Run("M45_remote_extended_permissions_held", func(t *testing.T) {
		for _, policy := range []*pyObject{pyObj("type", "workspace-write", "writable_roots", pyListOf("/exact/root")), pyObj("type", "workspace-write", "network_access", false)} {
			ctx := mrContext()
			ctx.Set("sandbox_policy", policy)
			mrRaise(t, "manual restart", func() { mrCodex([]string{"codex"}, ctx, []string{"/exact/relayd", "agent", "codex"}, "", false, true) })
		}
	})
	t.Run("M46_remote_unknown_permissions_held", func(t *testing.T) {
		ctx := mrContext()
		ctx.Set("sandbox_policy", pyObj("type", "workspace-write", "unknown_permission", true))
		mrRaise(t, "", func() { mrCodex([]string{"codex"}, ctx, []string{"/exact/relayd", "agent", "codex"}, "", false, true) })
	})
	t.Run("M60_pinned_update_launcher", func(t *testing.T) {
		got := phShlexSplit(phPinnedCodexCommand("/exact/relayd agent codex resume s-1", "/h/.local/bin/codex"))
		mrEq(t, got[:2], []string{"RELAY_CODEX_BIN=/h/.local/bin/codex", "/exact/relayd"})
		for _, bad := range []any{nil, "codex", "/h/bin/co\ndex"} {
			mrRaise(t, "", func() { phPinnedCodexCommand("/exact/relayd agent codex resume s-1", bad) })
		}
	})
}
func mrTail(t *testing.T, rows []any, provider string, age time.Duration, synthetic bool) (string, any, string) {
	t.Helper()
	r := newPHReader(context.Background())
	if synthetic {
		r.codexLifecycle = func(row any) *pyList {
			if state := phGet(row, "state", nil); state != nil {
				return pyListOf(state, "time")
			}
			return nil
		}
	}
	path := phWrite(t, filepath.Join(t.TempDir(), "rollout.jsonl"), mrJSONLines(rows...), 0600)
	stamp := time.Now().Add(-age)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	return r.tailEvidence(path, provider)
}
func mrEvent(kind string) any {
	return pyObj("timestamp", "2026-10-18T13:00:00.000Z", "type", "event_msg", "payload", pyObj("type", kind))
}
func mrTurn() []any {
	return []any{mrEvent("task_started"), pyObj("type", "event_msg", "payload", pyObj("type", "user_message", "message", "hi")), mrEvent("task_complete")}
}
func TestNativeMaintenanceOriginalIdleAssertions(t *testing.T) {
	quiet := func(t *testing.T, rows []any, want string) {
		t.Helper()
		s, _, _ := mrTail(t, rows, "codex", 60*time.Second, false)
		mrEq(t, s, want)
	}
	t.Run("M0_completed_quiet", func(t *testing.T) { quiet(t, mrTurn(), "quiet") })
	t.Run("M1_growing_settling", func(t *testing.T) {
		s, _, _ := mrTail(t, mrTurn(), "codex", time.Second, false)
		mrEq(t, s, "settling")
	})
	t.Run("M2_work_after_complete", func(t *testing.T) {
		rows := []any{pyObj("type", "response_item", "payload", pyObj("type", "function_call", "name", "shell")), pyObj("type", "response_item", "payload", pyObj("type", "custom_tool_call", "name", "apply_patch")), pyObj("type", "response_item", "payload", pyObj("type", "local_shell_call"))}
		for _, kind := range []string{"exec_command_begin", "exec_approval_request", "apply_patch_approval_request", "mcp_tool_call_begin"} {
			rows = append(rows, mrEvent(kind))
		}
		for _, row := range rows {
			quiet(t, append(mrTurn(), row), "active")
		}
	})
	t.Run("M3_R78_R79_late_results", func(t *testing.T) {
		rows := []any{pyObj("type", "response_item", "payload", pyObj("type", "function_call_output", "call_id", "c", "output", "x")), pyObj("type", "response_item", "payload", pyObj("type", "custom_tool_call_output", "call_id", "c", "output", "x")), pyObj("type", "response_item", "payload", pyObj("type", "message", "role", "assistant", "content", pyListOf()))}
		for _, kind := range []string{"exec_command_end", "patch_apply_end", "mcp_tool_call_end"} {
			rows = append(rows, mrEvent(kind))
		}
		rows = append(rows, pyObj("type", "event_msg", "payload", pyObj("type", "item_completed", "turn_id", "earlier", "item", pyObj("type", "CommandExecution"))))
		for _, row := range rows {
			quiet(t, append(mrTurn(), row), "active")
			quiet(t, append(append(mrTurn(), row), mrTurn()...), "quiet")
		}
	})
	t.Run("M4_bookkeeping", func(t *testing.T) {
		quiet(t, append(mrTurn(), mrEvent("thread_settings_applied"), mrEvent("token_count")), "quiet")
	})
	t.Run("M5_new_turn", func(t *testing.T) {
		quiet(t, append(mrTurn(), mrEvent("task_started")), "active")
		quiet(t, append(mrTurn(), mrTurn()...), "quiet")
	})
	t.Run("M6_unknown", func(t *testing.T) { quiet(t, []any{pyObj("type", "session_meta", "payload", pyObj())}, "unknown") })
	t.Run("M38_claude_final_answer", func(t *testing.T) {
		rows := []any{pyObj("type", "user", "message", pyObj("content", "work")), pyObj("type", "assistant", "message", pyObj("stop_reason", "tool_use"))}
		s, _, _ := mrTail(t, rows, "claude", time.Minute, false)
		mrEq(t, s, "active")
		rows = append(rows, pyObj("type", "assistant", "message", pyObj("stop_reason", "end_turn")), pyObj("type", "progress"))
		s, _, _ = mrTail(t, rows, "claude", time.Minute, false)
		mrEq(t, s, "quiet")
	})
	t.Run("M39_context_and_revision", func(t *testing.T) {
		s, ctx, rev := mrTail(t, []any{pyObj("state", "active"), pyObj("type", "turn_context", "payload", mrContext()), pyObj("state", "quiet")}, "codex", time.Minute, true)
		mrEq(t, s, "quiet")
		mrEq(t, phGet(ctx, "model", nil), "gpt-rosalind-5.5")
		mrEq(t, len(rev), 64)
	})
	t.Run("M40_no_final", func(t *testing.T) {
		s, _, _ := mrTail(t, []any{pyObj("type", "progress")}, "claude", time.Minute, false)
		mrEq(t, s, "unknown")
	})
	t.Run("M41_compaction", func(t *testing.T) {
		rows := []any{pyObj("type", "assistant", "message", pyObj("stop_reason", "end_turn")), pyObj("type", "system", "subtype", "turn_duration"), pyObj("type", "user", "isCompactSummary", true, "message", pyObj("content", "summary")), pyObj("type", "system", "subtype", "informational")}
		s, _, _ := mrTail(t, rows, "claude", time.Minute, false)
		mrEq(t, s, "quiet")
	})
}
func TestNativeAccountOriginalScalarAndShellAssertions(t *testing.T) {
	home := mrTempDir(t)
	t.Setenv("HOME", home)
	t.Run("A67_codex_alias_and_claude_explicit", func(t *testing.T) {
		if err := os.Mkdir(filepath.Join(home, ".codex"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(home, ".codex"), filepath.Join(home, "alias")); err != nil {
			t.Fatal(err)
		}
		for _, p := range []string{filepath.Join(home, ".codex"), filepath.Join(home, "alias")} {
			mrEq(t, phSameAccount("codex", p, ""), true)
			mrEq(t, phAccountLabelDir(p, "codex"), "")
		}
		mrEq(t, phSameAccount("claude", home+"/.claude", ""), false)
		mrEq(t, phSameAccount("claude", home+"/.claude", home+"/.claude"), true)
	})
	t.Run("A69_account_labels", func(t *testing.T) {
		t.Setenv("HOME", "/home/u")
		for _, pair := range [][2]string{{"/home/u/.claude-personal", "~/.claude-personal"}, {"/srv/claude", "/srv/claude"}, {"/home/user2/.claude", "/home/user2/.claude"}, {"", ""}} {
			mrEq(t, phAccountLabelDir(pair[0], "claude"), pair[1])
		}
	})
	t.Run("A72_quote_and_validate", func(t *testing.T) {
		mrEq(t, phAccountCommand("/r/relayd agent codex", "codex", "/home/u/.codex-personal"), "CODEX_HOME=/home/u/.codex-personal /r/relayd agent codex")
		for _, provider := range []string{"claude", "codex"} {
			v := "CODEX_HOME"
			if provider == "claude" {
				v = "CLAUDE_CONFIG_DIR"
			}
			mrEq(t, phAccountCommand("/x", provider, ""), "env -u "+v+" /x")
		}
		for _, bad := range []string{"relative", "/home/u/../x"} {
			mrRaise(t, "", func() { phAccountCommand("/x", "claude", bad) })
		}
		for _, command := range []string{"codex", "relayd agent codex", "RELAY_CLAUDE_BIN=/x claude", ""} {
			for _, override := range []string{"", "/home/u/.codex-personal"} {
				mrRaise(t, "", func() { phAccountCommand(command, "codex", override) })
			}
		}
	})
	run := func(t *testing.T, command string, env []string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
		cmd.Env = env
		out, err := cmd.Output()
		if err != nil {
			if _, ok := err.(*exec.ExitError); !ok {
				t.Fatal(err)
			}
		}
		if ctx.Err() != nil {
			t.Fatal(ctx.Err())
		}
		return string(out)
	}
	t.Run("A73_pinned_launcher_after_PATH_reorder", func(t *testing.T) {
		root := t.TempDir()
		managed := filepath.Join(root, "managed")
		other := filepath.Join(root, "environment")
		for path, marker := range map[string]string{managed: "managed", other: "unmanaged"} {
			phWrite(t, filepath.Join(path, "relayd"), "#!/bin/sh\nprintf '"+marker+":%s\\n' \"${CODEX_HOME+set}\"\n", 0700)
		}
		for override, want := range map[string]string{"": "managed:\n", "/synthetic/work": "managed:set\n"} {
			command := phAccountCommand(filepath.Join(managed, "relayd")+" agent codex", "codex", override)
			out := run(t, "PATH="+phShlexQuote(other)+":\"$PATH\"; "+command, []string{"HOME=" + home, "PATH=/usr/bin:/bin", "CODEX_HOME=/synthetic/personal"})
			mrEq(t, out, want)
		}
	})
	t.Run("A74_unset_inherited_account_and_keep_native_assignment", func(t *testing.T) {
		for provider, variable := range map[string]string{"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"} {
			for override, want := range map[string]string{"": "", "/synthetic/work": "/synthetic/work\n"} {
				cmd := phAccountCommand("/usr/bin/printenv "+variable, provider, override)
				mrEq(t, run(t, cmd, []string{"HOME=" + home, "PATH=/usr/bin:/bin", variable + "=/synthetic/personal"}), want)
			}
		}
		cmd := phAccountCommand("RELAY_CLAUDE_BIN=/synthetic/claude /usr/bin/printenv RELAY_CLAUDE_BIN CLAUDE_CONFIG_DIR", "claude", "")
		mrEq(t, run(t, cmd, []string{"HOME=" + home, "PATH=/usr/bin:/bin", "CLAUDE_CONFIG_DIR=/synthetic/personal"}), "/synthetic/claude\n")
	})
}
func TestNativeMaintenanceOriginalBackgroundAndMCPAssertions(t *testing.T) {
	t.Run("M7_exact_ancestry", func(t *testing.T) {
		r := newPHReader(nil)
		p := mrProcesses(map[int64]phProcess{42: {10, "claude"}, 43: {42, "mcp-server"}, 44: {43, "worker"}, 99: {1, "bash"}})
		r.inventory = func() *phProcesses { return p }
		mrEq(t, r.backgroundShellWork(42, nil), false)
		p.set(45, phProcess{44, "/bin/bash"})
		mrEq(t, r.backgroundShellWork(42, nil), true)
		r.inventory = nil
		mrEq(t, r.backgroundShellWork(42, nil), nil)
		r.inventory = func() *phProcesses { return mrProcesses(map[int64]phProcess{3: {4, "bash"}, 4: {3, "bash"}}) }
		mrEq(t, r.backgroundShellWork(42, nil), false)
	})
	t.Run("M9_exact_mcp_argv", func(t *testing.T) {
		root := t.TempDir()
		smdb := phWrite(t, filepath.Join(root, "smdb-mcp"), "#!/opt/bin/python3.12\nprint()\n", 0o644)
		node := phWrite(t, filepath.Join(root, "server.js"), "#!/usr/bin/env -S node --no-warnings\n", 0o644)
		plain := phWrite(t, filepath.Join(root, "server.py"), "print()\n", 0o644)
		entries := []phMCPEntry{{"/home/u/.claude/bin/sqz-mcp", nil}, {smdb, nil}, {node, []string{"--stdio"}}, {plain, nil}, {"npx", []string{"-y", "pkg"}}, {"uvx", []string{"srv", "--x"}}}
		for _, argv := range [][]string{{"/home/u/.claude/bin/sqz-mcp"}, {"/opt/bin/python3.12", smdb}, {"node", node, "--stdio"}, {"/usr/bin/uvx", "srv", "--x"}} {
			mrEq(t, phMCPServerProcess(argv, entries), true)
		}
		for _, argv := range [][]string{{"/home/u/.claude/bin/sqz-mcp", "--extra"}, {"claude", "--print", "x"}, {"node", "/home/u/.npm/_npx/1/node_modules/.bin/pkg"}, {"/usr/local/bin/claude", smdb}, {"/usr/bin/python3", smdb}, {"node", smdb}, {"python3", plain}} {
			mrEq(t, phMCPServerProcess(argv, entries), false)
		}
		mrEq(t, phMCPServerProcess([]string{"/usr/local/bin/claude", "/opt/mcp/server.py"}, []phMCPEntry{{"/opt/mcp/server.py", nil}}), false)
		mrEq(t, phMCPServerProcess([]string{"/opt/bin/codex", smdb}, []phMCPEntry{{smdb, nil}}), false)
	})
}

var _ = fmt.Sprint

func mrJSONLines(rows ...any) string {
	var b strings.Builder
	for _, row := range rows {
		b.Write(pyCompact(row))
		b.WriteByte('\n')
	}
	return b.String()
}
func mrProcesses(rows map[int64]phProcess) *phProcesses {
	p := &phProcesses{rows: map[int64]phProcess{}}
	for pid, row := range rows {
		p.set(pid, row)
	}
	return p
}

const mrSession = "37f2638a-5ee3-4d9d-a19d-410e122b35dd"

type mrAccount struct {
	home, path, account string
	r                   *phReader
	checks              [][]string
	bindable            bool
	overrides           []string
	reads               int
}

func mrAccountFixture(t *testing.T, shared bool) *mrAccount {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	t.Setenv("CODEX_HOME", "")
	os.Unsetenv("CODEX_HOME")
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	f := &mrAccount{home: home, bindable: true}
	f.path = phWrite(t, filepath.Join(home, ".claude/projects/p", mrSession+".jsonl"), mrJSONLines(pyObj("type", "user", "sessionId", mrSession, "message", pyObj("content", "hello")), pyObj("type", "assistant", "message", pyObj("stop_reason", "end_turn"))), 0o644)
	personal := filepath.Join(home, ".claude-personal")
	if err := os.MkdirAll(personal, 0700); err != nil {
		t.Fatal(err)
	}
	if shared {
		if err := os.Symlink(filepath.Join(home, ".claude/projects"), filepath.Join(personal, "projects")); err != nil {
			t.Fatal(err)
		}
	}
	image := phWrite(t, filepath.Join(home, ".local/share/claude/versions/2.1.301"), "\x7fELFnative-claude", 0755)
	if err := os.MkdirAll(filepath.Join(home, ".local/bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(image, filepath.Join(home, ".local/bin/claude")); err != nil {
		t.Fatal(err)
	}
	r := newPHReader(context.Background())
	f.r = r
	r.nativeClaude = func(int64, bool) string { return "" }
	r.isLinux = false
	r.rootForPane = func(pane string) int64 { mrEq(t, pane, "pane"); return 22 }
	r.agent = func(root int64, binary, pane string) (int64, string) {
		mrEq(t, root, int64(22))
		mrEq(t, binary, "/synthetic/relayd")
		mrEq(t, pane, "pane")
		return 33, "claude"
	}
	r.identity = func(any) string { return "stable-kernel-incarnation" }
	r.binding = func(string, string, int64, string) *pyObject {
		return pyObj("session_id", mrSession, "transcript_path", f.path)
	}
	r.metadata = func(path, kind string) any { mrEq(t, kind, "claude"); return mrSession }
	r.accountOverride = func(int64, string) string {
		v := f.account
		if len(f.overrides) > 0 {
			i := f.reads
			if i >= len(f.overrides) {
				i = len(f.overrides) - 1
			}
			v = f.overrides[i]
		}
		f.reads++
		return v
	}
	r.arguments = func(int64) []string { return []string{"claude", "--model", "opus"} }
	r.inventory = func() *phProcesses { return mrProcesses(map[int64]phProcess{33: {22, "claude"}}) }
	r.run = func(args []string, timeout float64) string {
		if len(args) > 1 {
			switch args[1] {
			case "prompt-owner-binding":
				return `{"pane_id":"pane","provider":"claude","process_id":33,"process_start":99}`
			case "agent-process-identity":
				return `{"process_start":99}`
			case "account-transcript-check":
				f.checks = append(f.checks, append([]string{}, args...))
				mrEq(t, timeout, float64(5))
				if f.bindable {
					return `{"bindable":true}`
				}
				return `{"bindable":false}`
			case "--version":
				return "2.1.301 (Claude Code)\n"
			}
		}
		if len(args) > 0 && args[0] == "/usr/sbin/lsof" {
			if args[len(args)-1] == "nDi" {
				info, err := os.Stat(image)
				if err != nil {
					t.Fatal(err)
				}
				dev, ino := phStatDevIno(info)
				return fmt.Sprintf("p33\nftxt\nD0x%x\ni%d\nn%s\n", dev, ino, image)
			}
			return "p33\nftxt\nn" + image + "\n"
		}
		phRaise(phOSError, "unexpected fixture operation")
		return ""
	}
	return f
}
func (f *mrAccount) inspect(expect, target *string) *pyObject {
	f.reads = 0
	return f.r.inspectAccounts("pane", "/synthetic/relayd", expect, target)
}
func mrString(s string) *string { return &s }
func TestNativeAccountOriginalInspectionAssertions(t *testing.T) {
	t.Run("A61_same_conversation_only_account_changes", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		proof := f.inspect(nil, mrString("~/.claude-personal"))
		mrEq(t, proof.Get("move_error"), nil)
		moved := phShlexSplit(pyMustString(proof.Get("move_command")))
		original := phShlexSplit(pyMustString(proof.Get("resume_command")))
		mrEq(t, moved[0], "CLAUDE_CONFIG_DIR="+f.home+"/.claude-personal")
		mrEq(t, original[:3], []string{"env", "-u", "CLAUDE_CONFIG_DIR"})
		mrEq(t, moved[1:], original[3:])
		mrEq(t, moved[len(moved)-2:], []string{"--resume", mrSession})
	})
	t.Run("A62_subagent_transcripts", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		mrEq(t, f.inspect(nil, mrString("~/.claude-personal")).Get("subagent_work"), false)
		phWrite(t, filepath.Join(f.home, ".claude/projects/p", mrSession, "subagents/agent-a1.jsonl"), "{}\n", 0o644)
		mrEq(t, f.inspect(nil, mrString("~/.claude-personal")).Get("subagent_work"), nil)
	})
	t.Run("A63_target_binding_before_offer", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		mrEq(t, f.inspect(nil, mrString("~/.claude-personal")).Get("move_command") != nil, true)
		mrEq(t, f.checks, [][]string{{"/synthetic/relayd", "account-transcript-check", "claude", f.home + "/.claude-personal", f.home + "/.claude-personal/projects/p/" + mrSession + ".jsonl"}})
		f.bindable = false
		proof := f.inspect(nil, mrString("~/.claude-personal"))
		mrEq(t, proof.Get("move_command"), nil)
		mrEq(t, strings.Contains(pyMustString(proof.Get("move_error")), "could not bind this conversation"), true)
		mrEq(t, proof.Get("resume_command") != nil, true)
	})
	t.Run("A64_history_not_visible", func(t *testing.T) {
		f := mrAccountFixture(t, false)
		proof := f.inspect(nil, mrString("~/.claude-personal"))
		mrEq(t, proof.Get("move_command"), nil)
		mrEq(t, strings.Contains(pyMustString(proof.Get("move_error")), "not visible from the target account"), true)
	})
	t.Run("A65_same_account_and_bad_selectors", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		f.account = f.home + "/.claude-personal"
		proof := f.inspect(nil, mrString("~/.claude-personal"))
		mrEq(t, proof.Get("move_command"), nil)
		mrEq(t, strings.Contains(pyMustString(proof.Get("move_error")), "already uses that account"), true)
		f.account = f.home + "/.claude"
		moved := f.inspect(nil, mrString(""))
		mrEq(t, phShlexSplit(pyMustString(moved.Get("move_command")))[:6], []string{"env", "-u", "CLAUDE_CONFIG_DIR", "/synthetic/relayd", "agent", "claude"})
		f.account = ""
		for _, bad := range []string{"relative", "~/../x", "~/a b"} {
			mrEq(t, strings.Contains(pyMustString(f.inspect(nil, &bad).Get("move_error")), "invalid"), true)
		}
	})
	t.Run("A66_explicit_claude_default", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		f.account = f.home + "/.claude"
		proof := f.inspect(mrString(""), nil)
		mrEq(t, proof.Get("config_dir"), "~/.claude")
		mrEq(t, proof.Get("account_matches"), false)
		mrEq(t, proof.Get("move_command"), nil)
		mrEq(t, f.inspect(mrString("~/.claude"), nil).Get("account_matches"), true)
		mrEq(t, f.inspect(mrString("~/.claude-personal"), nil).Get("account_matches"), false)
		f.account = f.home + "/.claude-personal"
		mrEq(t, f.inspect(mrString("~/.claude-personal"), nil).Get("account_matches"), true)
	})
	t.Run("A68_M20_own_account_exact_lookup", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		f.account = f.home + "/.claude-personal"
		f.r.binding = func(string, string, int64, string) *pyObject {
			return pyObj("session_id", mrSession, "transcript_path", "")
		}
		var lookups []string
		f.r.metadata = func(path, kind string) any {
			mrEq(t, kind, "claude")
			lookups = append(lookups, path)
			return mrSession
		}
		proof := f.inspect(nil, nil)
		mrEq(t, len(lookups), 2)
		mrEq(t, lookups[0], f.home+"/.claude-personal/projects/p/"+mrSession+".jsonl")
		mrEq(t, proof.Get("config_dir"), phAccountLabelDir(f.account, "claude"))
		words := phShlexSplit(pyMustString(proof.Get("resume_command")))
		mrEq(t, words[0], "CLAUDE_CONFIG_DIR="+f.account)
		mrEq(t, words[1:4], []string{"/synthetic/relayd", "agent", "claude"})
		mrEq(t, words[len(words)-2:], []string{"--resume", mrSession})
		mrEq(t, []any{proof.Get("provider"), proof.Get("session_id"), proof.Get("lifecycle")}, []any{"claude", mrSession, "quiet"})
	})
	t.Run("A70_default_unsets", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		proof := f.inspect(nil, nil)
		mrEq(t, proof.Get("config_dir"), "")
		mrEq(t, phShlexSplit(pyMustString(proof.Get("resume_command")))[:6], []string{"env", "-u", "CLAUDE_CONFIG_DIR", "/synthetic/relayd", "agent", "claude"})
	})
	t.Run("A71_account_change_refused", func(t *testing.T) {
		f := mrAccountFixture(t, true)
		f.overrides = []string{f.home + "/.claude-personal", ""}
		mrRaise(t, "changed during inspection", func() { f.inspect(nil, nil) })
	})
	t.Run("M21_exact_lookup_not_newest", func(t *testing.T) {
		f := mrAccountFixture(t, false)
		account := filepath.Join(f.home, "custom-account")
		first := phWrite(t, filepath.Join(account, "projects/first", mrSession+".jsonl"), "{}", 0o644)
		t.Setenv("CLAUDE_CONFIG_DIR", account)
		f.r.metadata = func(string, string) any { return "different-session" }
		mrRaise(t, "exact saved Claude conversation", func() { f.r.exactClaudeTranscript(mrSession, "") })
		f.r.metadata = func(string, string) any { return mrSession }
		mrEq(t, f.r.exactClaudeTranscript(mrSession, ""), first)
		phWrite(t, filepath.Join(account, "projects/second", mrSession+".jsonl"), "{}", 0o644)
		mrRaise(t, "exact saved Claude conversation", func() { f.r.exactClaudeTranscript(mrSession, "") })
	})
	t.Run("M32_exact_discovery_arguments", func(t *testing.T) {
		r := phScriptedReader(map[string][]string{"prompt-owner-binding": {"null"}})
		r.rootForPane = func(string) int64 { return 22 }
		calls := 0
		r.agent = func(root int64, binary, pane string) (int64, string) {
			calls++
			mrEq(t, root, int64(22))
			mrEq(t, binary, "relayd")
			mrEq(t, pane, "pane")
			phRaise(phValueError, "stop after discovery")
			return 0, ""
		}
		mrRaise(t, "stop after discovery", func() { r.inspect("pane", "relayd") })
		mrEq(t, calls, 1)
	})
}

func TestNativeMaintenanceOriginalMCPConfigurationAssertions(t *testing.T) {
	t.Run("M8_positive_mcp_exclusion_only", func(t *testing.T) {
		r := newPHReader(nil)
		p := mrProcesses(map[int64]phProcess{42: {10, "claude"}, 43: {42, "sqz-mcp"}, 44: {42, "smdb-mcp"}, 45: {42, "relay-mcp-commu"}, 46: {42, "python3"}})
		r.inventory = func() *phProcesses { return p }
		entries := []phMCPEntry{{"/home/u/.claude/bin/sqz-mcp", nil}, {"/opt/bioinfo/bin/smdb-mcp", nil}}
		servers := func() ([]phMCPEntry, bool) { return entries, true }
		mrEq(t, r.backgroundShellWork(42, servers), false)
		probe := newPHReader(nil)
		probe.inventory = func() *phProcesses { return mrProcesses(map[int64]phProcess{42: {10, "claude"}, 43: {42, "claude"}}) }
		probe.epoch = func(pid int64) float64 {
			if pid == 42 {
				return 1000
			}
			return 1005
		}
		probe.arguments = func(int64) []string { return []string{"claude", "--print", "work"} }
		v := probe.backgroundShellWork(42, servers)
		mrEq(t, v == true || v == nil, true)
		mrEq(t, probe.backgroundShellWork(42, servers), true)
		mrEq(t, probe.backgroundShellWork(42, nil), nil)
		p.set(47, phProcess{42, "node"})
		p.set(48, phProcess{47, "node"})
		r.arguments = func(pid int64) []string {
			mrEq(t, pid, int64(47))
			return []string{"node", "/srv/mcp/index.js", "--stdio"}
		}
		with := func(args ...string) func() ([]phMCPEntry, bool) {
			return func() ([]phMCPEntry, bool) {
				return append(append([]phMCPEntry{}, entries...), phMCPEntry{"node", args}), true
			}
		}
		mrEq(t, r.backgroundShellWork(42, with("/srv/mcp/index.js", "--stdio")), false)
		mrEq(t, r.backgroundShellWork(42, with("/srv/mcp/index.js")), true)
		mrEq(t, r.backgroundShellWork(42, servers), true)
		mrEq(t, r.backgroundShellWork(42, func() ([]phMCPEntry, bool) { return nil, false }), nil)
		r.arguments = func(int64) []string { phRaise(phOSError, "gone"); return nil }
		mrEq(t, r.backgroundShellWork(42, servers), nil)
		r.inventory = func() *phProcesses {
			return mrProcesses(map[int64]phProcess{42: {10, "claude"}, 50: {1, "claude"}, 51: {50, "node"}})
		}
		mrEq(t, r.backgroundShellWork(42, func() ([]phMCPEntry, bool) { return nil, false }), false)
		r.inventory = func() *phProcesses { return p }
		p.set(52, phProcess{43, "bash"})
		mrEq(t, r.backgroundShellWork(42, servers), true)
	})
	t.Run("M10_read_command_args_no_secrets", func(t *testing.T) {
		home := mrTempDir(t)
		cwd := filepath.Join(home, "work/proj")
		if err := os.MkdirAll(cwd, 0700); err != nil {
			t.Fatal(err)
		}
		account := filepath.Join(home, ".claude-personal")
		plugin := filepath.Join(home, "plugin")
		if err := os.MkdirAll(filepath.Join(plugin, ".claude-plugin"), 0755); err != nil {
			t.Fatal(err)
		}
		phWrite(t, filepath.Join(account, ".claude.json"), string(pyCompact(pyObj("mcpServers", pyObj("sqz", pyObj("type", "stdio", "command", "/bin/sqz-mcp", "args", pyListOf(), "env", pyObj("TOKEN", "secret")), "web", pyObj("type", "http", "url", "https://x", "headers", pyObj("Authorization", "secret"))), "projects", pyObj(cwd, pyObj("mcpServers", pyObj("local", pyObj("command", "node", "args", pyListOf("/l.js")))))))), 0o644)
		parentConfig := phWrite(t, filepath.Join(filepath.Dir(cwd), ".mcp.json"), `{"mcpServers":{"proj":{"command":"uvx","args":["p"]}}}`, 0o644)
		phWrite(t, filepath.Join(plugin, ".mcp.json"), `{"mcpServers":{"z":{"command":"python3","args":["${CLAUDE_PLUGIN_ROOT}/server.py"]}}}`, 0o644)
		phWrite(t, filepath.Join(account, "plugins/installed_plugins.json"), string(pyCompact(pyObj("plugins", pyObj("z@m", pyListOf(pyObj("installPath", plugin)))))), 0o644)
		r := newPHReader(nil)
		r.cwd = func(int64) string { return cwd }
		entries := r.configuredMCPCommands(42, account, []string{"claude"})
		want := []phMCPEntry{{"/bin/sqz-mcp", []string{}}, {"node", []string{"/l.js"}}, {"uvx", []string{"p"}}, {"python3", []string{plugin + "/server.py"}}}
		mrEq(t, string(pyCompact(phEntriesValue(entries))), string(pyCompact(phEntriesValue(want))))
		mrEq(t, strings.Contains(string(pyCompact(phEntriesValue(entries))), "secret"), false)
		extra := r.configuredMCPCommands(42, account, []string{"claude", "--mcp-config", `{"mcpServers":{"e":{"command":"/bin/e","args":["1"]}}}`})
		found := false
		for _, e := range extra {
			if e.command == "/bin/e" && phEqualWords(e.args, []string{"1"}) {
				found = true
			}
		}
		mrEq(t, found, true)
		phWrite(t, parentConfig, "{not json", 0o644)
		mrEq(t, r.configuredMCPCommands(42, account, []string{"claude"}), []phMCPEntry(nil))
		r.cwd = func(int64) string { phRaise(phOSError, "gone"); return "" }
		mrEq(t, r.configuredMCPCommands(42, account, []string{"claude"}), []phMCPEntry(nil))
	})
}
func mrLaunched(agent, status string) []any {
	id := "toolu_" + agent + status
	return []any{pyObj("type", "assistant", "message", pyObj("content", pyListOf(pyObj("type", "tool_use", "id", id, "name", "Agent", "input", pyObj("run_in_background", true))))), pyObj("type", "user", "message", pyObj("role", "user", "content", pyListOf(pyObj("type", "tool_result", "tool_use_id", id, "content", "elided"))), "toolUseResult", pyObj("agentId", agent, "status", status, "isAsync", true))}
}
func mrNote(agent, status string) any {
	return pyObj("type", "user", "origin", pyObj("kind", "task-notification"), "message", pyObj("role", "user", "content", fmt.Sprintf("<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_%s</tool-use-id>\n<status>%s</status>\n<summary>elided</summary>\n</task-notification>", agent, agent, status)))
}
func mrStop(agent string, bad bool) []any {
	id := "toolu_stop_" + agent
	return []any{pyObj("type", "assistant", "message", pyObj("content", pyListOf(pyObj("type", "tool_use", "id", id, "name", "TaskStop", "input", pyObj("task_id", agent))))), pyObj("type", "user", "message", pyObj("content", pyListOf(pyObj("type", "tool_result", "tool_use_id", id, "is_error", bad, "content", "elided"))), "toolUseResult", pyObj("task_id", agent, "task_type", "local_agent"))}
}
func mrRows(parts ...any) []any {
	var rows []any
	for _, p := range parts {
		if list, ok := p.([]any); ok {
			rows = append(rows, list...)
		} else {
			rows = append(rows, p)
		}
	}
	return rows
}
func TestNativeMaintenanceOriginalSubagentAssertions(t *testing.T) {
	const session = "27ea6c73-4f7e-4e8e-9200-ace1a40a29cd"
	project := filepath.Join(t.TempDir(), "projects/-maps-projects-caeg-people-kbd606-rice")
	path := filepath.Join(project, session+".jsonl")
	write := func(parts ...any) { phWrite(t, path, mrJSONLines(mrRows(parts...)...), 0o644) }
	work := func() any { return phSubagentWork(path, session) }
	write(pyObj("type", "user", "message", pyObj("content", "hello")))
	mrEq(t, work(), false)
	if err := os.MkdirAll(filepath.Join(project, session, "tool-results"), 0700); err != nil {
		t.Fatal(err)
	}
	mrEq(t, work(), false)
	subagents := filepath.Join(project, session, "subagents")
	if err := os.Mkdir(subagents, 0700); err != nil {
		t.Fatal(err)
	}
	mrEq(t, work(), false)
	for _, a := range []string{"a1", "a2"} {
		p := phWrite(t, filepath.Join(subagents, "agent-"+a+".jsonl"), "{}\n", 0o644)
		phWrite(t, filepath.Join(subagents, "agent-"+a+".meta.json"), "{}", 0o644)
		if err := os.Chtimes(p, time.Unix(0, 0), time.Unix(0, 0)); err != nil {
			t.Fatal(err)
		}
	}
	launch := func(a string) []any { return mrLaunched(a, "async_launched") }
	for _, c := range []struct {
		name string
		rows []any
		want any
	}{
		{"launched_old_still_work", mrRows(launch("a1"), launch("a2")), true},
		{"completed_stopped", mrRows(launch("a1"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "stopped")), false},
		{"resumed", mrRows(launch("a1"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "completed"), launch("a2")), true},
		{"foreground_and_TaskStop", mrRows(mrLaunched("a1", "completed"), launch("a2"), mrStop("a2", false)), false},
		{"failed_TaskStop", mrRows(mrLaunched("a1", "completed"), launch("a2"), mrStop("a2", true)), true},
		{"missing_history", mrRows(launch("a1"), mrNote("a1", "completed")), nil},
		{"paused", mrRows(launch("a1"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "paused")), nil},
		{"forked_unknown", mrRows(mrLaunched("a1", "forked"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "completed")), nil},
		{"live_outweighs_unknown", mrRows(launch("a1"), launch("a2"), mrNote("a2", "paused")), true},
		{"all_complete", mrRows(launch("a1"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "completed")), false},
	} {
		t.Run(c.name, func(t *testing.T) { write(c.rows); mrEq(t, work(), c.want) })
	}
	t.Run("quoted_output_is_data", func(t *testing.T) {
		quoted := "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>"
		write(launch("a1"), pyObj("type", "assistant", "message", pyObj("content", pyListOf(pyObj("type", "tool_use", "id", "toolu_bash", "name", "Bash", "input", pyObj())))), pyObj("type", "user", "message", pyObj("content", pyListOf(pyObj("type", "tool_result", "tool_use_id", "toolu_bash", "content", quoted))), "toolUseResult", pyObj("stdout", quoted, "stderr", "")), pyObj("type", "user", "message", pyObj("content", quoted)), pyObj("type", "user", "message", pyObj("content", pyListOf(pyObj("type", "text", "text", quoted)))), launch("a2"), mrNote("a2", "completed"))
		mrEq(t, phSubagentLifecycle(path, []string{"a1"}), map[string][]string{"a1": {"start"}})
		mrEq(t, work(), true)
	})
	t.Run("only_correlated_tool_results_end", func(t *testing.T) {
		write(launch("a1"), pyObj("type", "assistant", "message", pyObj("content", pyListOf(pyObj("type", "tool_use", "id", "toolu_x", "name", "Bash", "input", pyObj())))), pyObj("type", "user", "message", pyObj("content", pyListOf(pyObj("type", "tool_result", "tool_use_id", "toolu_x", "content", "x"))), "toolUseResult", pyObj("agentId", "a1", "status", "completed")), pyObj("type", "assistant", "message", pyObj("content", pyListOf(pyObj("type", "tool_use", "id", "toolu_stop", "name", "TaskStop", "input", pyObj("task_id", "a1"))))), pyObj("type", "user", "message", pyObj("content", pyListOf(pyObj("type", "tool_result", "tool_use_id", "toolu_stop", "content", "x"))), "toolUseResult", pyObj("task_id", "other")), launch("a2"), mrNote("a2", "completed"))
		mrEq(t, work(), true)
	})
	mrEq(t, phSubagentWork("", session), nil)
	mrEq(t, phSubagentWork(filepath.Join(project, "other.jsonl"), session), nil)
	mrEq(t, phSubagentWork(filepath.Join(project, "missing.jsonl"), "missing"), nil)
	write(launch("a1"), mrNote("a1", "completed"), launch("a2"), mrNote("a2", "completed"))
	link := filepath.Join(subagents, "agent-c.jsonl")
	if err := os.Symlink(filepath.Join(subagents, "agent-a1.jsonl"), link); err != nil {
		t.Fatal(err)
	}
	mrEq(t, work(), nil)
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	t.Run("production_main_limit", func(t *testing.T) {
		f, err := os.OpenFile(path, os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		if err = f.Truncate(phSubagentMainLimit + 1); err != nil {
			t.Fatal(err)
		}
		f.Close()
		mrEq(t, work(), nil)
	})
	t.Run("unreadable_directory", func(t *testing.T) {
		write(launch("a1"))
		if err := os.Chmod(subagents, 0000); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(subagents, 0700)
		mrEq(t, work(), nil)
	})
}

func TestNativeMaintenanceOriginalHarnessAssertions(t *testing.T) {
	home := mrTempDir(t)
	t.Setenv("HOME", home)
	sessions := filepath.Join(home, ".claude/sessions")
	record := func(pid int64, kind, status string, start int64) {
		phWrite(t, filepath.Join(sessions, fmt.Sprint(pid)+".json"), string(pyCompact(pyObj("pid", pid, "procStart", fmt.Sprint(start), "kind", kind, "status", status, "sessionId", "s"+fmt.Sprint(pid), "messagingSocketPath", "/run/x.sock"))), 0o644)
	}
	starts := map[int64]int64{42: 1000, 70: 2000, 71: 2100, 72: 2200, 73: 2300}
	p := mrProcesses(map[int64]phProcess{42: {10, "claude"}, 70: {1, "claude"}, 71: {1, "claude"}, 72: {42, "claude"}, 73: {1, "claude"}})
	r := newPHReader(nil)
	r.identity = func(pid any) string { return fmt.Sprint("linux:", starts[phPid(pid)]) }
	r.inventory = func() *phProcesses { return p }
	record(42, "interactive", "idle", 1000)
	record(70, "bg", "shell", 2000)
	record(71, "bg", "idle", 9999)
	record(72, "bg", "idle", 2200)
	record(74, "bg", "idle", 2400)
	record(73, "interactive", "idle", 2300)
	mrEq(t, r.harnessStatus(42, ""), "idle")
	mrEq(t, r.backgroundAgentJobs(42, ""), int64(1))
	mrEq(t, r.harnessStatus(42, home+"/.claude-personal"), "idle")
	starts[42] = 1001
	mrEq(t, r.harnessStatus(42, ""), nil)
	starts[42] = 1000
	record(42, "interactive", "shell", 1000)
	mrEq(t, r.harnessStatus(42, ""), "shell")
	phWrite(t, filepath.Join(sessions, "42.json"), "{broken", 0o644)
	mrEq(t, r.harnessStatus(42, ""), nil)
	phWrite(t, filepath.Join(sessions, "70.json"), "{broken", 0o644)
	mrEq(t, r.backgroundAgentJobs(42, ""), nil)
	record(70, "bg", "shell", 2000)
	p.set(70, phProcess{71, "claude"})
	p.set(71, phProcess{70, "claude"})
	mrEq(t, r.backgroundAgentJobs(42, ""), nil)
	t.Setenv("HOME", home+"/none")
	mrEq(t, r.harnessStatus(42, ""), nil)
	mrEq(t, r.backgroundAgentJobs(42, ""), nil)
}
func mrNative(t *testing.T, path, body string) string {
	t.Helper()
	return phRealpath(phWrite(t, path, "\x7fELF"+body, 0755))
}
func TestNativeMaintenanceOriginalImageAndLauncherAssertions(t *testing.T) {
	t.Run("M13_actual_image_identity", func(t *testing.T) {
		home := mrTempDir(t)
		a := phWrite(t, home+"/old", "old", 0o644)
		b := phWrite(t, home+"/new", "new", 0o644)
		r := newPHReader(nil)
		r.nativeClaude = func(_ int64, installed bool) string {
			if installed {
				return b
			}
			return a
		}
		mrEq(t, r.currentClaudeImage(42), false)
		r.nativeClaude = func(int64, bool) string { return b }
		mrEq(t, r.currentClaudeImage(42), true)
		r.nativeClaude = func(int64, bool) string { phRaise(phValueError, "unknown"); return "" }
		mrEq(t, r.currentClaudeImage(42), nil)
	})
	t.Run("M14_nfs_verified_versions", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		old := mrNative(t, home+"/.local/share/claude/versions/.nfs00000019375ea8ca0012736b", "native-claude")
		target := mrNative(t, home+"/.local/share/claude/versions/2.1.301", "native-claude")
		r := newPHReader(nil)
		r.isLinux = true
		r.readlink = func(path string) (string, error) {
			if path == "/proc/42/exe" {
				return old, nil
			}
			return os.Readlink(path)
		}
		if err := os.MkdirAll(home+"/.local/bin", 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, home+"/.local/bin/claude"); err != nil {
			t.Fatal(err)
		}
		r.nativeClaude = func(_ int64, installed bool) string {
			if installed {
				return target
			}
			if !phVerifiedNative(old, r.uid) {
				phRaise(phValueError, "owner controlled")
			}
			return old
		}
		calls := 0
		r.run = func(argv []string, timeout float64) string {
			calls++
			if argv[0] == old {
				return "2.1.299 (Claude Code)\n"
			}
			return "2.1.301 (Claude Code)\n"
		}
		mrEq(t, r.installedUpdate(42, "claude"), true)
		mrEq(t, calls, 2)
		for _, reply := range []string{"2.1.302 (Claude Code)\n", "unrecognized output", "2.1.299 (Claude Code)\n"} {
			r.run = func([]string, float64) string { return reply }
			mrEq(t, r.installedUpdate(42, "claude"), false)
		}
		if err := os.Chmod(old, 0775); err != nil {
			t.Fatal(err)
		}
		mrEq(t, r.installedUpdate(42, "claude"), false)
	})
	t.Run("M15_pin_installed_native_not_PATH", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		target := mrNative(t, home+"/.local/share/claude/versions/2.1.301", "native-claude")
		if err := os.MkdirAll(home+"/.local/bin", 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, home+"/.local/bin/claude"); err != nil {
			t.Fatal(err)
		}
		r := newPHReader(nil)
		native := r.nativeClaudeExecutable(42, true)
		mrEq(t, native, target)
		words := phShlexSplit(phClaudeResumeCommand([]string{"claude", "--dangerously-skip-permissions"}, "exact-session", []string{"relayd", "agent", "claude"}, native))
		mrEq(t, words[0], "RELAY_CLAUDE_BIN="+target)
	})
	t.Run("M16_reject_scripts_and_writable", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		launcher := phWrite(t, home+"/.local/bin/claude", "#!/bin/sh\nexec unreviewed-claude", 0755)
		r := newPHReader(nil)
		mrRaise(t, "verified native executable", func() { r.nativeClaudeExecutable(42, true) })
		phWrite(t, launcher, "\x7fELFnative-claude", 0775)
		mrRaise(t, "owner controlled", func() { r.nativeClaudeExecutable(42, true) })
	})
	t.Run("M23_unknown_helper_refused", func(t *testing.T) {
		launcher := phWrite(t, filepath.Join(t.TempDir(), "launcher"), "#!/bin/sh\nexec /unreviewed/helper \"$@\"\n", 0o644)
		r := newPHReader(nil)
		mrRaise(t, "no reviewed native-image mapping", func() { r.installedRelayImage(launcher) })
	})
	t.Run("M24_direct_native_helper", func(t *testing.T) {
		// The original positive writes ELF bytes without setting executable bits.
		payload := phWrite(t, filepath.Join(mrTempDir(t), "native"), "\x7fELFowned-native-helper", 0o644)
		mrEq(t, newPHReader(nil).installedRelayImage(payload), payload)
	})
	t.Run("M47_release_store_versions", func(t *testing.T) {
		mrEq(t, phPathVersion("/h/.local/share/claude/versions/2.1.301", "claude").String(), "2.1.301")
		mrEq(t, phPathVersion("/opt/homebrew/Caskroom/codex/0.46.0/codex-aarch64-apple-darwin", "codex").String(), "0.46.0")
		mrEq(t, phPathVersion("/opt/homebrew/Cellar/node/24.1.0/lib/node_modules/@openai/codex/bin/codex.js", "codex"), phVersion(nil))
		mrEq(t, phPathVersion("/h/.local/share/claude/versions/.nfs0001", "claude"), phVersion(nil))
	})
	t.Run("M48_npm_native_image_only", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		pack := home + "/lib/node_modules/@openai/codex"
		script := phWrite(t, pack+"/bin/codex.js", "#!/usr/bin/env node\n", 0755)
		image := mrNative(t, pack+"/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex", "native")
		if err := os.MkdirAll(home+"/.local/bin", 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(script, home+"/.local/bin/codex"); err != nil {
			t.Fatal(err)
		}
		r := newPHReader(nil)
		r.isLinux = true
		launcher, gotImage := r.installedAgent("codex")
		mrEq(t, []string{launcher, gotImage}, []string{script, image})
		calls := 0
		r.run = func([]string, float64) string { calls++; return "codex-cli 0.162.1\n" }
		mrEq(t, r.imageVersion(script, "codex"), phVersion(nil))
		mrEq(t, calls, 0)
		mrEq(t, r.imageVersion(image, "codex").String(), "0.162.1")
		if err := os.Chmod(image, 0775); err != nil {
			t.Fatal(err)
		}
		mrEq(t, r.imageVersion(image, "codex"), phVersion(nil))
	})
	t.Run("M50_install_roots", func(t *testing.T) {
		root := phInstallRoot
		npm := "/p/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
		mrEq(t, root("/h/.local/share/claude/versions/2.1.301", "claude"), root("/h/.local/share/claude/versions/.nfs0001", "claude"))
		mrEq(t, root(npm, "codex"), "/p/lib/node_modules/@openai/codex")
		mrEq(t, root("/p/lib/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/codex/.nfs0002", "codex"), root(npm, "codex"))
		mrEq(t, root("/h/.local/share/relay/native-codex-0.160.1-w3_bh9n1/codex", "codex"), root("/h/.local/share/relay/native-codex/codex", "codex"))
		mrEq(t, root("/h/.local/share/relay/native-codex-0.160.1-w3_bh9n1/codex", "codex") == root(npm, "codex"), false)
		mrEq(t, root("/h/conda/lib/node_modules/@openai/codex/bin/codex", "codex") == root(npm, "codex"), false)
		mrEq(t, root("/opt/homebrew/Caskroom/codex/0.46.0/codex-aarch64-apple-darwin", "codex"), root("/opt/homebrew/Caskroom/codex/0.47.0/codex-aarch64-apple-darwin", "codex"))
	})
	t.Run("M53_darwin_device_inode", func(t *testing.T) {
		image := mrNative(t, filepath.Join(t.TempDir(), "codex"), "native")
		info, err := os.Stat(image)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		r := newPHReader(nil)
		r.isLinux = false
		r.run = func([]string, float64) string { return fmt.Sprintf("p42\nftxt\nD0x%x\ni%d\nn%s\n", dev, ino, image) }
		mrEq(t, r.runningImage(42), phImage{path: image, dev: dev, ino: ino, executable: image})
		r.run = func([]string, float64) string { return fmt.Sprintf("p42\nftxt\nD0x%x\ni%d\nn%s\n", dev+1, ino, image) }
		mrEq(t, r.runningImage(42).executable, "")
	})
	t.Run("M56_npm_outside_package_bin_refused", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		pack := home + "/lib/node_modules/@openai/codex"
		other := phWrite(t, pack+"/scripts/other.js", "#!/usr/bin/env node\n", 0755)
		mrNative(t, pack+"/vendor/x86_64-unknown-linux-musl/codex/codex", "native")
		if err := os.MkdirAll(home+"/.local/bin", 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(other, home+"/.local/bin/codex"); err != nil {
			t.Fatal(err)
		}
		a, b := newPHReader(nil).installedAgent("codex")
		mrEq(t, []string{a, b}, []string{"", ""})
	})
	t.Run("M58_nfs_store_root", func(t *testing.T) {
		store := "/h/.local/share/claude/versions"
		mrEq(t, phInstallRoot(store+"/.nfs0001", "claude"), store)
		mrEq(t, phInstallRoot(store+"/2.1.302", "claude"), store)
	})
	t.Run("M59_unknown_version_safe", func(t *testing.T) {
		r := newPHReader(nil)
		r.isLinux = false
		r.run = func([]string, float64) string { phRaise(phOSError, "gone"); return "" }
		mrEq(t, r.agentVersions(42, "codex"), phAgentVersions{})
	})
}

func TestNativeAccountEnvironmentRetirementChild(t *testing.T) {
	if os.Getenv("RELAY_RETIREMENT_ENV_CHILD") == "1" {
		time.Sleep(30 * time.Second)
	}
}
func TestNativeAccountOriginalExactProcessEnvironment(t *testing.T) {
	home := mrTempDir(t)
	personal := filepath.Join(home, ".claude-personal")
	cmd := exec.Command(os.Args[0], "-test.run=^TestNativeAccountEnvironmentRetirementChild$")
	cmd.Env = []string{"HOME=" + home, "CLAUDE_CONFIG_DIR=" + personal, "UNRELATED_SECRET=never-returned", "RELAY_RETIREMENT_ENV_CHILD=1"}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	r := newPHReader(context.Background())
	deadline := time.Now().Add(5 * time.Second)
	value := ""
	for {
		e := phRaised(t, func() { value = r.processAccountOverride(int64(cmd.Process.Pid), "claude") })
		if e == nil && value != "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("child environment never became readable")
		}
		time.Sleep(20 * time.Millisecond)
	}
	mrEq(t, value, personal)
	mrEq(t, r.conversationAccountRoot(int64(cmd.Process.Pid), "claude"), personal)
	mrEq(t, r.processAccountOverride(int64(cmd.Process.Pid), "codex"), "")
	if strings.Contains(value, "never-returned") {
		t.Fatal("unrelated environment escaped")
	}
}

func mrTempDir(t *testing.T) string {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNativeMaintenanceOriginalVersionSnapshotAssertions(t *testing.T) {
	t.Run("M49_replaced_and_current_native_version", func(t *testing.T) {
		home := mrTempDir(t)
		installed := mrNative(t, home+"/pkg/codex", "native")
		old := mrNative(t, home+"/proc-exe", "old")
		r := newPHReader(nil)
		calls := 0
		r.run = func(argv []string, timeout float64) string {
			calls++
			if argv[0] == old {
				return "codex-cli 0.160.1\n"
			}
			return "codex-cli 0.162.1\n"
		}
		info, err := os.Stat(old)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		v := r.agentVersionsFromImage("codex", phImage{path: home + "/.nfs0001", dev: dev, ino: ino, executable: old}, "/h/.local/bin/codex", installed)
		mrEq(t, []any{v.running, v.installed, v.imageCurrent}, []any{"0.160.1", "0.162.1", false})
		mrEq(t, phNewerInstalled(v), true)
		v.running = "0.163.0"
		mrEq(t, phNewerInstalled(v), false)
		v.running = nil
		mrEq(t, phNewerInstalled(v), false)
		info, err = os.Stat(installed)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino = phStatDevIno(info)
		calls = 0
		v = r.agentVersionsFromImage("codex", phImage{path: installed, dev: dev, ino: ino, executable: installed}, "/h/.local/bin/codex", installed)
		mrEq(t, []any{v.running, v.imageCurrent}, []any{"0.162.1", true})
		mrEq(t, calls, 1)
	})
	t.Run("M51_other_install_report_not_current", func(t *testing.T) {
		home := mrTempDir(t)
		legacy := mrNative(t, home+"/.local/share/relay/native-codex-0.160.1-a/codex", "old")
		installed := mrNative(t, home+"/lib/node_modules/@openai/codex/vendor/x/codex/codex", "native")
		info, err := os.Stat(legacy)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		r := newPHReader(nil)
		r.run = func(argv []string, timeout float64) string {
			if argv[0] == legacy {
				return "codex-cli 0.160.1"
			}
			return "codex-cli 0.162.1"
		}
		v := r.agentVersionsFromImage("codex", phImage{path: legacy, dev: dev, ino: ino, executable: legacy}, "/h/.local/bin/codex", installed)
		mrEq(t, phNewerInstalled(v), true)
		mrEq(t, v.sameInstall, false)
	})
	t.Run("M52_both_device_and_inode", func(t *testing.T) {
		installed := mrNative(t, filepath.Join(mrTempDir(t), "versions/2.1.302"), "native")
		info, err := os.Stat(installed)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		r := newPHReader(nil)
		r.run = func([]string, float64) string { return "2.1.302 (Claude Code)" }
		for _, c := range []struct {
			dev  int64
			want bool
		}{{dev, true}, {dev + 1, false}} {
			v := r.agentVersionsFromImage("claude", phImage{path: installed, dev: c.dev, ino: ino}, "/h/.local/bin/claude", installed)
			mrEq(t, v.imageCurrent, c.want)
		}
	})
	t.Run("M54_unknown_shared_parent_not_install", func(t *testing.T) {
		home := mrTempDir(t)
		old := mrNative(t, home+"/custom/bin/codex-old", "old")
		newImage := mrNative(t, home+"/custom/bin/codex-new", "native")
		info, err := os.Stat(old)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		r := newPHReader(nil)
		r.run = func(argv []string, timeout float64) string {
			if argv[0] == old {
				return "codex-cli 0.160.1"
			}
			return "codex-cli 0.162.1"
		}
		v := r.agentVersionsFromImage("codex", phImage{path: old, dev: dev, ino: ino, executable: old}, home+"/.local/bin/codex", newImage)
		mrEq(t, phInstallRoot(old, "codex"), "")
		mrEq(t, v.sameInstall, nil)
		mrEq(t, phNewerInstalled(v), true)
	})
	t.Run("M55_unproven_wrapper_no_archived_bundle", func(t *testing.T) {
		home := mrTempDir(t)
		t.Setenv("HOME", home)
		old := mrNative(t, home+"/.local/share/relay/native-codex-0.160.1-a/codex", "old")
		newImage := mrNative(t, home+"/.local/share/relay/native-codex-0.162.1-b/codex", "native")
		if err := os.Symlink(filepath.Base(filepath.Dir(newImage)), home+"/.local/share/relay/native-codex"); err != nil {
			t.Fatal(err)
		}
		phWrite(t, home+"/.local/bin/codex", "#!/bin/sh\nexec /some/other/install/codex \"$@\"\n", 0700)
		r := newPHReader(nil)
		launcher, installed := r.installedAgent("codex")
		mrEq(t, []string{launcher, installed}, []string{"", ""})
		info, err := os.Stat(old)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		r.run = func(argv []string, timeout float64) string {
			if argv[0] == old {
				return "codex-cli 0.160.1"
			}
			return "codex-cli 0.162.1"
		}
		v := r.agentVersionsFromImage("codex", phImage{path: old, dev: dev, ino: ino, executable: old}, launcher, installed)
		mrEq(t, []any{v.launcher, v.installed, v.sameInstall}, []any{nil, nil, nil})
		mrEq(t, phNewerInstalled(v), false)
		mrRaise(t, "", func() { phPinnedCodexCommand("/exact/relayd agent codex resume s-1", v.launcher) })
	})
	t.Run("M57_missing_installed_identity_unknown", func(t *testing.T) {
		home := mrTempDir(t)
		installed := mrNative(t, home+"/codex/0.162.1/codex", "native")
		old := mrNative(t, home+"/old-image", "old")
		info, err := os.Stat(old)
		if err != nil {
			t.Fatal(err)
		}
		dev, ino := phStatDevIno(info)
		if err := os.Remove(installed); err != nil {
			t.Fatal(err)
		}
		r := newPHReader(nil)
		r.run = func([]string, float64) string { t.Fatal("No executable may be run"); return "" }
		v := r.agentVersionsFromImage("codex", phImage{path: installed, dev: dev, ino: ino}, home+"/launcher", installed)
		mrEq(t, v.imageCurrent, nil)
		mrEq(t, []any{v.running, v.installed}, []any{"0.162.1", "0.162.1"})
	})
}
func TestNativeMaintenanceOriginalNamespaceAssertions(t *testing.T) {
	for _, mode := range []string{"workspace-write", "read-only"} {
		ctx := mrContext()
		ctx.Set("sandbox_policy", pyObj("type", mode))
		mrRaise(t, "automatic restart is held", func() {
			phCodexResumeWithNamespaces([]string{"codex"}, "session-123", ctx, []string{"/home/test/.local/bin/codex"}, "", true, true, func() string { return "0" })
		})
	}
	command := phCodexResumeWithNamespaces([]string{"codex"}, "session-123", mrContext(), []string{"/home/test/.local/bin/codex"}, "", true, true, func() string { return "0" })
	mrEq(t, strings.Contains(command, "resume session-123"), true)
}

func TestNativeMaintenanceOriginalContextAndShellAssertions(t *testing.T) {
	t.Run("M25_M26_context_support_enrollment", func(t *testing.T) {
		root := mrTempDir(t)
		for _, c := range []struct {
			wire string
			want any
		}{
			{`{"state":"ready","worker_pid":42}`, pyObj("supported", false, "enabled", false, "state", "unsupported_worker")},
			{`{"v":1,"enabled":true,"state":"evaluation_unavailable","generation":3,"lifecycle":"unavailable","refresh_capability":"unverified"}`, nil},
		} {
			daemon := phWrite(t, filepath.Join(root, "relayd"), "#!/bin/sh\ncat >/dev/null\nprintf '%s' "+phShlexQuote(c.wire)+"\n", 0700)
			result := newPHReader(context.Background()).contextObservation("pane", daemon)
			if c.want != nil {
				mrEq(t, string(pyCompact(result)), string(pyCompact(c.want)))
			} else {
				mrEq(t, result.Get("enabled"), true)
				mrEq(t, []any{result.Get("lifecycle"), result.Get("refresh_capability")}, []any{"unavailable", "unverified"})
			}
		}
	})
	t.Run("M30_M31_exact_shell_owner", func(t *testing.T) {
		valid := `{"version":1,"pane_id":"pane","provider":"shell","process_id":22,"process_start":99,"shell_pid":22,"shell_start":99}`
		r := phScriptedReader(map[string][]string{"prompt-owner-binding": {valid}})
		r.rootForPane = func(string) int64 { return 22 }
		r.identity = func(any) string { return "incarnation" }
		r.agent = func(int64, string, string) (int64, string) { t.Fatal("verified shell has no agent"); return 0, "" }
		proof := r.inspect("pane", "relayd")
		mrEq(t, []any{proof.Get("provider"), proof.Get("process_id"), proof.Get("process_start")}, []any{"shell", int64(22), int64(99)})
		_, exists := proof.Lookup("session_id")
		mrEq(t, exists, false)
		_, exists = proof.Lookup("resume_command")
		mrEq(t, exists, false)
		r = phScriptedReader(map[string][]string{"prompt-owner-binding": {valid, `{"provider":"codex"}`}})
		r.rootForPane = func(string) int64 { return 22 }
		r.identity = func(any) string { return "incarnation" }
		mrRaise(t, "shell owner changed", func() { r.inspect("pane", "relayd") })
	})
}

func TestNativeMaintenanceOriginalAuthenticatedClaudeDefaultLookup(t *testing.T) {
	f := mrAccountFixture(t, false)
	f.r.binding = func(string, string, int64, string) *pyObject {
		return pyObj("session_id", mrSession, "transcript_path", "")
	}
	f.r.transcript = func(int64, string) (string, string) {
		t.Fatal("authenticated session must not use open-file discovery")
		return "", ""
	}
	var paths []string
	f.r.metadata = func(path, kind string) any { mrEq(t, kind, "claude"); paths = append(paths, path); return mrSession }
	proof := f.inspect(nil, nil)
	mrEq(t, len(paths), 2)
	mrEq(t, paths[0], f.path)
	mrEq(t, []any{proof.Get("provider"), proof.Get("session_id"), proof.Get("lifecycle")}, []any{"claude", mrSession, "quiet"})
}
func TestNativeReviewerOriginalIdleAssertions(t *testing.T) {
	complete := func() any {
		return pyObj("timestamp", "2026-10-17T13:00:00.000Z", "type", "event_msg", "payload", pyObj("type", "task_complete"))
	}
	t.Run("R78_late_tool_results_need_new_completion", func(t *testing.T) {
		for _, kind := range []string{"function_call_output", "custom_tool_call_output"} {
			result := pyObj("type", "response_item", "payload", pyObj("type", kind, "call_id", "synthetic", "output", "synthetic result"))
			state, _, _ := mrTail(t, []any{complete(), result}, "codex", time.Minute, false)
			mrEq(t, state, "active")
		}
	})
	t.Run("R79_late_exec_patch_events_need_new_completion", func(t *testing.T) {
		for _, kind := range []string{"exec_command_end", "patch_apply_end", "mcp_tool_call_end"} {
			event := pyObj("timestamp", "2026-10-17T13:00:01.000Z", "type", "event_msg", "payload", pyObj("type", kind))
			state, _, _ := mrTail(t, []any{complete(), event}, "codex", time.Minute, false)
			mrEq(t, state, "active")
		}
	})
}
