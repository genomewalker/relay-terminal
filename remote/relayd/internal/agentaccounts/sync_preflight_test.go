package agentaccounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHostSyncRequiresAReviewedPreview(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "[mcp_servers.a]\ncommand = \"node\"\n")
	if _, err := Handle(Request{Action: "sync", Provider: "codex", Label: "personal"}, nil); err == nil ||
		!strings.Contains(err.Error(), "review") {
		t.Fatalf("sync without a reviewed preview: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex-personal")); !os.IsNotExist(err) {
		t.Fatal("a sync without a preview created the account directory")
	}
	if _, err := SyncReviewed(home, Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}, time.Unix(1, 0), ""); err == nil {
		t.Fatal("SyncReviewed accepted an empty fingerprint")
	}
}

func TestSyncRefusesTOMLBeforeChangingAnyClaudeOrHistoryPath(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal", ShareHistory: true}
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "when = 1979-05-27\n")
	writeFile(t, filepath.Join(home, ".codex", "sessions", "a.jsonl"), "{}\n")
	if err := os.MkdirAll(filepath.Join(account.Root(home), "sessions"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Sync(home, account, time.Unix(1, 0)); err == nil {
		t.Fatal("a date value in the main config was accepted")
	}
	if info, err := os.Lstat(filepath.Join(account.Root(home), "sessions")); err != nil || !info.IsDir() {
		t.Fatal("the account's empty sessions directory was replaced before the refusal")
	}
}

func TestSyncWritePhaseRechecksEachPath(t *testing.T) {
	home := t.TempDir()
	source, destination := filepath.Join(home, "main", "AGENTS.md"), filepath.Join(home, "account", "AGENTS.md")
	writeFile(t, source, "shared")
	writeFile(t, destination, "own")
	before := observe(destination)
	writeFile(t, destination, "own, edited after the preflight")
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(destination, later, later); err != nil {
		t.Fatal(err)
	}
	if link := linkShared(source, destination, before, "s"); link.State != LinkChanged {
		t.Fatalf("a destination changed after the preflight was replaced: %+v", link)
	}
	if data, _ := os.ReadFile(destination); string(data) != "own, edited after the preflight" {
		t.Fatal("the changed destination was modified")
	}

	main, target := filepath.Join(home, "codex", "config.toml"), filepath.Join(home, "codex-personal", "config.toml")
	writeFile(t, main, "[mcp_servers.a]\ncommand = \"node\"\n")
	writeFile(t, target, "forced_login_method = \"api\"\n")
	plan, err := planCodexConfig(main, target, Account{Provider: "codex"})
	if err != nil || plan.link {
		t.Fatalf("plan: %v link=%v", err, plan.link)
	}
	writeFile(t, main, "[mcp_servers.b]\ncommand = \"other\"\n")
	var result SyncResult
	if err := plan.write("s", &result); err == nil || result.MCP != MergeRefused {
		t.Fatalf("a main config changed after the preflight was merged: %v %s", err, result.MCP)
	}
	plan, err = planCodexConfig(main, target, Account{Provider: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, target, "forced_login_method = \"chatgpt\"\n")
	if err := plan.write("s", &result); err == nil {
		t.Fatal("an account config changed after the preflight was replaced")
	}
	if data, _ := os.ReadFile(target); string(data) != "forced_login_method = \"chatgpt\"\n" {
		t.Fatal("the changed account config was modified")
	}
}

func TestCodexMergeKeepsOrRefusesTheTargetsAccountKeys(t *testing.T) {
	home := t.TempDir()
	main, target := filepath.Join(home, "codex", "config.toml"), filepath.Join(home, "codex-personal", "config.toml")
	writeFile(t, main, "model = \"m\"\n[mcp_servers.a]\ncommand = \"node\"\n")
	// Linked earlier, before the account had keys of its own: still a link.
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	var result SyncResult
	if err := syncCodexConfig(main, target, "s1", Account{Provider: "codex"}, &result); err != nil || result.MCP != CodexConfigLink {
		t.Fatalf("plain configs: %v %s", err, result.MCP)
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	own := "[profiles.p]\nforced_chatgpt_workspace_id = \"w\"\n"
	writeFile(t, target, own)
	result = SyncResult{}
	if err := syncCodexConfig(main, target, "s2", Account{Provider: "codex"}, &result); err != nil || result.MCP != CodexConfigMerge {
		t.Fatalf("target with a nested account key: %v %s", err, result.MCP)
	}
	data, _ := os.ReadFile(target)
	if !strings.HasPrefix(string(data), own) || !strings.Contains(string(data), "[mcp_servers.a]") || strings.Contains(string(data), "model") {
		t.Fatalf("merged config:\n%s", data)
	}
	// An account key inside the target's own MCP server would be lost.
	writeFile(t, target, "[mcp_servers.own.env]\nCODEX_HOME = \"/srv/own\"\n")
	result = SyncResult{}
	if err := syncCodexConfig(main, target, "s3", Account{Provider: "codex"}, &result); err == nil || result.MCP != MergeRefused {
		t.Fatalf("an account key inside the target's MCP servers: %v %s", err, result.MCP)
	}
	if data, _ := os.ReadFile(target); string(data) != "[mcp_servers.own.env]\nCODEX_HOME = \"/srv/own\"\n" {
		t.Fatal("the refused target was modified")
	}
}

// treeSnapshot records every path under root (mode, link target, contents).
func treeSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	snapshot := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		entry := info.Mode().String()
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, _ := os.Readlink(path)
			entry += " -> " + target
		case info.Mode().IsRegular():
			data, _ := os.ReadFile(path)
			entry += " " + string(data)
		}
		snapshot[path] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func TestMalformedClaudeJSONIsRefusedBeforeAnyChange(t *testing.T) {
	servers := `{"synthetic":{"command":"fixture"}}`
	for _, broken := range []string{
		`{"mcpServers":` + servers,                        // the outer object is never closed
		`{"mcpServers":` + servers + `,`,                  // cut after a member
		`{"mcpServers":` + servers + `,"later":`,          // cut inside a later member
		`{"mcpServers":` + servers + `,"later":[1,}`,      // a later member is malformed
		`{"mcpServers":` + servers + `}x`,                 // trailing garbage
		`{"mcpServers":` + servers + `}{}`,                // a second document
		`{"mcpServers":` + servers + ",\"bad\":\"\x01\"}", // a raw control character
		`{"mcpServers":` + servers + `,"later":"cut off}`, // an unterminated string
	} {
		if json.Valid([]byte(broken)) {
			t.Fatalf("fixture is valid JSON: %q", broken)
		}
		home := t.TempDir()
		account := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
		writeFile(t, filepath.Join(home, ".claude.json"), broken)
		writeFile(t, filepath.Join(home, ".claude", "CLAUDE.md"), "shared")
		writeFile(t, filepath.Join(account.Root(home), "CLAUDE.md"), "own instructions")
		writeFile(t, filepath.Join(account.Root(home), ".claude.json"), `{"mcpServers":{"own":{"command":"x"}}}`)
		before := treeSnapshot(t, home)
		if preview, err := PreviewMCP(home, account); err == nil {
			t.Fatalf("%q: the preview accepted malformed JSON (%d servers)", broken, len(preview.Servers))
		}
		// The fingerprint a valid file with the same servers would give.
		valid := t.TempDir()
		writeFile(t, filepath.Join(valid, ".claude.json"), `{"mcpServers":`+servers+`}`)
		preview, err := PreviewMCP(valid, account)
		if err != nil {
			t.Fatal(err)
		}
		for _, fingerprint := range []string{preview.Fingerprint, "stale"} {
			if result, err := SyncReviewed(home, account, time.Unix(123, 0), fingerprint); err == nil {
				t.Fatalf("%q: sync accepted malformed JSON: %+v", broken, result)
			}
		}
		if _, err := Sync(home, account, time.Unix(124, 0)); err == nil {
			t.Fatalf("%q: an unreviewed sync accepted malformed JSON", broken)
		}
		after := treeSnapshot(t, home)
		if len(after) != len(before) {
			t.Fatalf("%q: paths were added or removed: %d -> %d", broken, len(before), len(after))
		}
		for path, entry := range before {
			if after[path] != entry {
				t.Fatalf("%q: %s changed", broken, path)
			}
		}
	}
}
