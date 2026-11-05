package agentaccounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReviewMCPPreviewMustNeverEmitValueFragments(t *testing.T) {
	home := t.TempDir()
	// Valid TOML: the escaped quote, comma and equals all belong to TOKEN's value.
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), `[mcp_servers.db]
command = "node"
env = { TOKEN = "prefix\", SYNTHETIC_PRIVATE_VALUE = suffix" }
`)
	preview, err := PreviewMCP(home, Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"})
	if err != nil {
		t.Fatal(err)
	}
	output, err := json.Marshal(preview)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(output), "SYNTHETIC_PRIVATE_VALUE") {
		t.Fatal("MCP key-only preview emitted text taken from inside a configuration value")
	}
}

func TestReviewInlineCodexHomeMustNotSelectMain(t *testing.T) {
	home := t.TempDir()
	main := filepath.Join(home, ".codex", "config.toml")
	target := filepath.Join(home, ".codex-personal", "config.toml")
	writeFile(t, main, "forced_login_method = \"chatgpt\"\n[mcp_servers.node_repl]\ncommand = \"node\"\nenv = { CODEX_HOME = \"/synthetic/main-codex\", KEEP = \"fixture\" }\n")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	var result SyncResult
	if err := syncCodexConfig(main, target, "fixture", Account{Provider: "codex"}, &result); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "/synthetic/main-codex") {
		t.Fatal("MCP inline env retained the main account CODEX_HOME in the personal config")
	}
}

func TestReviewRegistryMustCanonicalizeDefaultAliases(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(home, ".codex", "AGENTS.md"), "fixture-main")
	alias := filepath.Join(home, "alias")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatal(err)
	}
	registry, err := Normalize(Registry{Version: 1, Accounts: []Account{
		{Provider: "codex", Label: "work", Dir: ""},
		{Provider: "codex", Label: "personal", Dir: filepath.Join(alias, ".codex")},
	}}, home)
	if err == nil && registry.Accounts[1].Dir != "" {
		t.Fatal("Registry accepted a second account that resolves to the default directory")
	}
}

func TestReviewSyncAliasMustNotMutateMain(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	main := filepath.Join(home, ".codex", "AGENTS.md")
	writeFile(t, main, "fixture-main")
	alias := filepath.Join(home, "alias")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatal(err)
	}
	_, _ = Sync(home, Account{Provider: "codex", Label: "personal", Dir: filepath.Join(alias, ".codex")}, time.Unix(1, 0))
	got, err := os.ReadFile(main)
	if err != nil || string(got) != "fixture-main" {
		t.Fatalf("Sync changed its own main AGENTS.md via an accepted parent alias: read error=%v", err)
	}
}
