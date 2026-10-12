//go:build linux

package agentlaunch

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestClaudeEffectiveArgumentsReplaceOnlyChangedSelectors(t *testing.T) {
	fresh := []string{"--settings", "/private/hooks.json", "--model", "sonnet", "--permission-mode=default", "--effort", "low", "--add-dir", "/work/shared"}
	got, err := effectiveClaudeArguments(fresh, "claude-opus-5", "high", "auto")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"--settings", "/private/hooks.json", "--add-dir", "/work/shared", "--model", "claude-opus-5", "--permission-mode", "auto", "--effort", "high"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("configuration drift: got %q want %q", got, want)
	}
	if _, err := effectiveClaudeArguments(fresh, "claude-opus-5", "high", "unknown"); err == nil {
		t.Fatal("unknown permission mode accepted")
	}
}

func TestClaudeTranscriptPermissionUsesExactSessionLastRecord(t *testing.T) {
	config := t.TempDir()
	dir := filepath.Join(config, "projects", "project")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	id := "12345678-1234-4234-8234-123456789abc"
	path := filepath.Join(dir, id+".jsonl")
	rows := []string{
		`{"type":"permission-mode","sessionId":"` + id + `","permissionMode":"default"}`,
		`{"type":"permission-mode","sessionId":"other","permissionMode":"bypassPermissions"}`,
		`{"type":"permission-mode","sessionId":"` + id + `","permissionMode":"auto"}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(rows, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mode, err := claudeTranscriptPermission(config, id)
	if err != nil || mode != "auto" {
		t.Fatalf("got %q, %v", mode, err)
	}
}
