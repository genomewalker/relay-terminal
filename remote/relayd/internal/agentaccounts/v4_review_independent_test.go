package agentaccounts

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestV4ReviewSyncMustValidateBeforeSharedFileChanges(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	writeFile(t, filepath.Join(home, ".codex", "AGENTS.md"), "new shared source")
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "[mcp_servers.fixture]\ncommand = \"unterminated\n")
	target := filepath.Join(account.Root(home), "AGENTS.md")
	writeFile(t, target, "own file must survive refused input")
	_, err := Sync(home, account, time.Unix(1, 0))
	if err == nil {
		t.Fatal("invalid main TOML was not refused")
	}
	info, statErr := os.Lstat(target)
	if statErr != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("Sync changed a shared item before rejecting invalid main TOML")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "own file must survive refused input" {
		t.Fatal("Sync changed the target file before rejecting invalid TOML")
	}
}

func TestV4ReviewRegistryMustKeepPerProviderRootSets(t *testing.T) {
	home := t.TempDir()
	shared := filepath.Join(home, "shared-account")
	registry := Registry{Version: 1, Accounts: []Account{
		{Provider: "claude", Label: "work", Dir: ""}, {Provider: "codex", Label: "work", Dir: ""},
		{Provider: "claude", Label: "first", Dir: shared}, {Provider: "codex", Label: "other", Dir: shared},
		{Provider: "claude", Label: "duplicate", Dir: shared},
	}}
	if _, err := Normalize(registry, home); err == nil {
		t.Fatal("a Codex row hid a duplicate same-provider Claude account root")
	}
}

func TestV4ReviewParserMustRefuseInvalidCalendarDate(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "[mcp_servers.fixture]\ncommand=\"node\"\ninvalid_date=2000-99-99\n")
	target := filepath.Join(account.Root(home), "config.toml")
	writeFile(t, target, "model = \"fixture\"\n")
	result, err := Sync(home, account, time.Unix(1, 0))
	if err == nil {
		t.Fatalf("Sync accepted invalid TOML and replaced a good account config: MCP state=%s", result.MCP)
	}
}

func TestV4ReviewSyncMustPreserveTargetAccountSettings(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "model = \"fixture\"\n[mcp_servers.fixture]\ncommand = \"node\"\n")
	target := filepath.Join(account.Root(home), "config.toml")
	writeFile(t, target, "forced_chatgpt_workspace_id = \"synthetic-personal-workspace\"\n")
	if _, err := Sync(home, account, time.Unix(1, 0)); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	document, err := parseTOML(string(data))
	if err != nil {
		t.Fatal(err)
	}
	if document.root.values["forced_chatgpt_workspace_id"] != "synthetic-personal-workspace" {
		t.Fatal("Sync removed the target account's own workspace restriction when main had no account keys")
	}
}
