package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestManagedStockCodexCoversInteractiveLaunchesWithoutWrappingTools(t *testing.T) {
	for _, args := range [][]string{nil, {"--dangerously-bypass-approvals-and-sandbox"}, {"resume", "exact-thread"}, {"fork", "exact-thread"}, {"-p", "review", "resume", "exact-thread"}, {"--model", "fixture", "Explain this project"}} {
		if !managedStockCodexArguments(args, "existing-pane") {
			t.Fatalf("interactive launch skipped: %q", args)
		}
	}
	for _, args := range [][]string{{"--help"}, {"--version"}, {"app-server", "--listen", "stdio://"}, {"exec", "task"}, {"-m", "fixture", "review"}, {"login"}, {"mcp", "list"}, {"--remote", "unix:///already-owned.sock"}} {
		if managedStockCodexArguments(args, "existing-pane") {
			t.Fatalf("tool invocation wrapped: %q", args)
		}
	}
	if managedStockCodexArguments(nil, "") {
		t.Fatal("non-Relay shell launch wrapped")
	}
}

func TestManagedStockCodexPassesResumedThreadSavedPermissionsToBackend(t *testing.T) {
	home := t.TempDir()
	thread := "01a13c87-83d1-76f3-a38a-1b2f0953416e"
	directory := filepath.Join(home, "sessions", "2026", "10", "15")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	rollout := `{"type":"session_meta","payload":{"id":"` + thread + `"}}` + "\n" +
		`{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}` + "\n"
	if err := os.WriteFile(filepath.Join(directory, "rollout-2026-10-15T00-27-56-"+thread+".jsonl"), []byte(rollout), 0o600); err != nil {
		t.Fatal(err)
	}
	environment := []string{"CODEX_HOME=" + home}
	_, got, err := agentlaunch.ManagedCodexLaunchPolicy(codexHome(environment), []string{"--cd", "/work", "--model", "gpt-rosalind-5.5", "resume", thread})
	if err != nil || !reflect.DeepEqual(got.AppServerArguments(), []string{"-c", `sandbox_mode="danger-full-access"`, "-c", `approval_policy="never"`}) {
		t.Fatalf("saved permissions not forwarded: %+v %v", got, err)
	}
	for _, args := range [][]string{{"--model", "gpt-6.1-sol"}, {"resume", "01a12f1b-7c35-7681-9f90-9ef906a1a59e"}} {
		if _, got, err := agentlaunch.ManagedCodexLaunchPolicy(codexHome(environment), args); err != nil || len(got.AppServerArguments()) != 0 {
			t.Fatalf("%q forwarded %+v %v", args, got, err)
		}
	}
	if codexHome([]string{"CODEX_HOME=relative"}) == "relative" {
		t.Fatal("relative CODEX_HOME used")
	}
}

// An account's model defaults are prepended as -c pairs; they never change
// whether a launch is managed or the permissions its backend gets.
func TestAccountModelDefaultsKeepManagedCodexLaunchesUnchanged(t *testing.T) {
	home := t.TempDir()
	defaults := agentaccounts.ModelDefaults{Version: 1, Model: "gpt-rosalind-5.5", Effort: "xhigh"}
	for _, args := range [][]string{nil, {"--dangerously-bypass-approvals-and-sandbox"}, {"--model", "fixture", "Explain this project"},
		{"exec", "task"}, {"-a", "never", "-s", "workspace-write"}, {"login"}, {"resume", "exact-thread"}} {
		with := agentaccounts.WithCodexDefaults(defaults, args)
		if managedStockCodexArguments(with, "existing-pane") != managedStockCodexArguments(args, "existing-pane") {
			t.Fatalf("defaults changed whether %q is managed (%q)", args, with)
		}
		frontend, permissions, err := agentlaunch.ManagedCodexLaunchPolicy(home, with)
		_, expected, expectedErr := agentlaunch.ManagedCodexLaunchPolicy(home, args)
		if err != nil || expectedErr != nil || !reflect.DeepEqual(permissions, expected) {
			t.Fatalf("defaults changed the permissions of %q: %+v %+v %v %v", args, permissions, expected, err, expectedErr)
		}
		if added := with[:len(with)-len(args)]; len(added) > 0 && !reflect.DeepEqual(frontend[:len(added)], added) {
			t.Fatalf("defaults did not reach the frontend: %q", frontend)
		}
	}
}
