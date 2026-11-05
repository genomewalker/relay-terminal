//go:build linux || darwin

package nativemsg

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// Retains AgentAccountTests.test_messaging_uses_the_process_account_for_registry_and_codex_socket.
// The private proc fixture supplies the exact process's initial account;
// hostile ambient defaults must have no authority over a successful read.
func TestMaintenanceAccountMessagingUsesExactProcessAccount(t *testing.T) {
	root := t.TempDir()
	for pid, data := range map[string]string{"7": "HOME=/hostile/process-home\x00CLAUDE_CONFIG_DIR=/accounts/personal-claude\x00UNRELATED_SECRET=never-returned\x00", "8": "HOME=/hostile/process-home\x00CODEX_HOME=/accounts/personal-codex\x00UNRELATED_SECRET=never-returned\x00"} {
		dir := filepath.Join(root, pid)
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "environ"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	r := &runner{ctx: context.Background(), proc: procfs{root: root, uid: int64(os.Getuid())}, home: "/hostile/ambient-home", host: Host{Getenv: func(key string) (string, bool) {
		if key == "CODEX_HOME" {
			return "/hostile/ambient-codex", true
		}
		return "", false
	}}}
	got, err := r.claudeSessions(int64(7))
	if err != nil || got != "/accounts/personal-claude/sessions" {
		t.Fatalf("exact Claude registry %q: %v", got, err)
	}
	got, err = r.accountRoot(int64(8), "codex")
	if err != nil || got != "/accounts/personal-codex" {
		t.Fatalf("exact Codex account %q: %v", got, err)
	}
}
