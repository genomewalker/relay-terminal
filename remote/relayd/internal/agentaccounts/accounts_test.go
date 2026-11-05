package agentaccounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestDefaultRegistryKeepsMainDirectoriesAsWork(t *testing.T) {
	home := t.TempDir()
	registry, err := Load(home)
	if err != nil {
		t.Fatal(err)
	}
	work, _ := registry.Find("claude", "work")
	personal, _ := registry.Find("codex", "personal")
	if work.Override(home) != "" || work.Root(home) != filepath.Join(home, ".claude") {
		t.Fatalf("work must be the unset default: %+v", work)
	}
	if personal.Override(home) != filepath.Join(home, ".codex-personal") {
		t.Fatalf("personal Codex directory: %q", personal.Override(home))
	}
	if label, ok := registry.LabelFor(home, "claude", filepath.Join(home, ".claude-personal")); !ok || label != "personal" {
		t.Fatalf("label for personal directory: %q %v", label, ok)
	}
	if label, ok := registry.LabelFor(home, "claude", ""); !ok || label != "work" {
		t.Fatalf("label for default directory: %q %v", label, ok)
	}
}

func TestRegistryValidationAndEditableMapping(t *testing.T) {
	home := t.TempDir()
	// The main directory can be relabelled when it actually holds the
	// personal login; an explicit ~/.codex folds back to the default.
	swapped := Registry{Version: 1, Accounts: []Account{
		{Provider: "codex", Label: "personal", Dir: "~/.codex"},
		{Provider: "codex", Label: "work", Dir: "~/.codex-work"},
	}}
	saved, err := Save(home, swapped)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Accounts[0].Dir != "" {
		t.Fatalf("explicit main directory was not folded to the default: %+v", saved.Accounts[0])
	}
	info, err := os.Stat(Path(home))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("registry must be owner-only: %v %v", info.Mode(), err)
	}
	loaded, err := Load(home)
	if err != nil || !reflect.DeepEqual(loaded.Accounts, saved.Accounts) {
		t.Fatalf("round trip: %+v %v", loaded, err)
	}
	if _, err := Normalize(Registry{Version: 1, Accounts: []Account{{Provider: "claude", Label: "work", Dir: "~/.claude"}}}, home); err == nil ||
		!strings.Contains(err.Error(), "explicit ~/.claude uses a different .claude.json") {
		t.Fatalf("Claude's explicit ~/.claude must be refused with its reason: %v", err)
	}
	for _, bad := range [][]Account{
		{{Provider: "claude", Label: "a", Dir: "~/.x"}, {Provider: "claude", Label: "a", Dir: "~/.y"}},
		{{Provider: "claude", Label: "a", Dir: "~/.x"}, {Provider: "claude", Label: "b", Dir: "~/.x"}},
		{{Provider: "claude", Label: "a", Dir: ""}, {Provider: "claude", Label: "b", Dir: "~/.claude"}},
		{{Provider: "claude", Label: "a", Dir: "~/.claude"}},
		{{Provider: "claude", Label: "Work", Dir: ""}},
		{{Provider: "claude", Label: "a", Dir: "relative"}},
		{{Provider: "claude", Label: "a", Dir: "~/../etc"}},
		{{Provider: "claude", Label: "a", Dir: "~/has space"}},
		{{Provider: "claude", Label: "a", Dir: "~/$(x)"}},
		{{Provider: "gemini", Label: "a", Dir: ""}},
	} {
		if _, err := Normalize(Registry{Version: 1, Accounts: bad}, home); err == nil {
			t.Fatalf("invalid registry accepted: %+v", bad)
		}
	}
}

// claudeMain creates a main ~/.claude with shared items and credentials.
func claudeMain(t *testing.T, home string) {
	writeFile(t, filepath.Join(home, ".claude", "CLAUDE.md"), "# shared\n")
	writeFile(t, filepath.Join(home, ".claude", "settings.json"), `{"hooks":{}}`)
	writeFile(t, filepath.Join(home, ".claude", "skills", "a", "SKILL.md"), "skill\n")
	writeFile(t, filepath.Join(home, ".claude", ".credentials.json"), "MAIN-CREDENTIAL")
	writeFile(t, filepath.Join(home, ".claude", "history.jsonl"), "MAIN-HISTORY")
	writeFile(t, filepath.Join(home, ".claude", "projects", "p", "s.jsonl"), "MAIN-TRANSCRIPT")
	writeFile(t, filepath.Join(home, ".claude.json"),
		`{"oauthAccount":{"emailAddress":"MAIN-ACCOUNT"},"userID":"MAIN-USER","projects":{"/x":{}},"mcpServers":{"relay":{"command":"relay-mcp"},"chitta":{"command":"chitta","args":["mcp"]}}}`)
}

func TestClaudeSyncLinksSharedConfigAndMergesOnlyMCPServers(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	root := personal.Root(home)
	// The personal account already has its own state and an older server list.
	writeFile(t, filepath.Join(root, ".claude.json"),
		`{"oauthAccount":{"emailAddress":"PERSONAL-ACCOUNT"},"numStartups":3,"mcpServers":{"old":{"command":"old"}}}`)
	stamp := time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC)
	result, err := Sync(home, personal, stamp)
	if err != nil || result.Error != "" {
		t.Fatalf("sync: %v %+v", err, result)
	}
	for _, link := range result.Links {
		want := LinkLinked
		if link.Name == "agents" || link.Name == "commands" || link.Name == "plugins" {
			want = LinkMissingMain
		}
		if link.State != want {
			t.Fatalf("%s = %s, want %s", link.Name, link.State, want)
		}
	}
	if target, err := os.Readlink(filepath.Join(root, "settings.json")); err != nil || target != filepath.Join(home, ".claude", "settings.json") {
		t.Fatalf("settings.json link: %q %v", target, err)
	}
	merged := readJSON(t, filepath.Join(root, ".claude.json"))
	if merged["numStartups"] != float64(3) || merged["oauthAccount"].(map[string]any)["emailAddress"] != "PERSONAL-ACCOUNT" {
		t.Fatalf("the account's own state changed: %v", merged)
	}
	if _, leaked := merged["userID"]; leaked {
		t.Fatal("a main-account key other than mcpServers was copied")
	}
	if _, leaked := merged["projects"]; leaked {
		t.Fatal("main project state was copied")
	}
	servers := merged["mcpServers"].(map[string]any)
	if len(servers) != 2 || servers["relay"] == nil || servers["old"] != nil {
		t.Fatalf("mcpServers not replaced from main: %v", servers)
	}
	if result.MCP != MergeUpdated || result.MCPCount != 2 || result.MCPBackup == "" {
		t.Fatalf("merge result: %+v", result)
	}
	backup, err := os.ReadFile(filepath.Join(root, result.MCPBackup))
	if err != nil || strings.Contains(string(backup), "ACCOUNT") || !strings.Contains(string(backup), `"old"`) {
		t.Fatalf("the backup must hold only the previous mcpServers value: %q %v", backup, err)
	}
	// Credentials, history and transcripts are never linked or copied.
	for _, name := range []string{".credentials.json", "history.jsonl", "projects", "sessions", "auth.json"} {
		if _, err := os.Lstat(filepath.Join(root, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s must not be created in the account directory", name)
		}
	}
	assertNoContent(t, root, "MAIN-CREDENTIAL", "MAIN-HISTORY", "MAIN-TRANSCRIPT", "MAIN-ACCOUNT", "MAIN-USER")

	again, err := Sync(home, personal, stamp.Add(time.Minute))
	if err != nil || again.MCP != MergeUnchanged || again.MCPBackup != "" {
		t.Fatalf("second sync must be a no-op: %+v %v", again, err)
	}
	for _, link := range again.Links {
		if link.State != LinkLinked && link.State != LinkMissingMain {
			t.Fatalf("second sync changed %s: %s", link.Name, link.State)
		}
	}
}

func assertNoContent(t *testing.T, root string, secrets ...string) {
	t.Helper()
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil
		}
		data, _ := os.ReadFile(path)
		for _, secret := range secrets {
			if strings.Contains(string(data), secret) {
				t.Fatalf("%s copied into %s", secret, path)
			}
		}
		return nil
	})
}

func TestSyncBacksUpARealFileAndNeverReplacesAForeignLink(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	root := personal.Root(home)
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "personal notes\n")
	if err := os.Symlink("/elsewhere/settings.json", filepath.Join(root, "settings.json")); err != nil {
		t.Fatal(err)
	}
	result, err := Sync(home, personal, time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	states := map[string]LinkResult{}
	for _, link := range result.Links {
		states[link.Name] = link
	}
	if states["CLAUDE.md"].State != LinkBackedUp || states["CLAUDE.md"].Backup != "CLAUDE.md.relay-backup-20260102T030405Z" {
		t.Fatalf("real file: %+v", states["CLAUDE.md"])
	}
	if data, err := os.ReadFile(filepath.Join(root, states["CLAUDE.md"].Backup)); err != nil || string(data) != "personal notes\n" {
		t.Fatalf("backup content: %q %v", data, err)
	}
	if states["settings.json"].State != LinkForeign {
		t.Fatalf("foreign link: %+v", states["settings.json"])
	}
	if target, _ := os.Readlink(filepath.Join(root, "settings.json")); target != "/elsewhere/settings.json" {
		t.Fatal("a foreign link was replaced")
	}
}

func TestClaudeMergeRefusesALinkedAccountConfig(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	if err := os.MkdirAll(personal.Root(home), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, ".claude.json"), filepath.Join(personal.Root(home), ".claude.json")); err != nil {
		t.Fatal(err)
	}
	result, err := Sync(home, personal, time.Now())
	if err == nil || result.MCP != MergeRefused {
		t.Fatalf("merging through a link must be refused: %+v %v", result, err)
	}
	if !strings.Contains(string(mustRead(t, filepath.Join(home, ".claude.json"))), "MAIN-USER") {
		t.Fatal("the main configuration was changed")
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestMainDirectoryIsNeverASyncTarget(t *testing.T) {
	home := t.TempDir()
	if _, err := Sync(home, Account{Provider: "claude", Label: "work"}, time.Now()); err == nil {
		t.Fatal("syncing the main directory into itself was accepted")
	}
}

func TestSharedListsNeverContainAccountState(t *testing.T) {
	for _, name := range append(append([]string{"config.toml"}, claudeLinks...), codexLinks...) {
		if slices.Contains(neverShared, name) {
			t.Fatalf("%s is account state and must never be shared", name)
		}
	}
}

func TestCodexConfigIsLinkedWithoutAccountKeys(t *testing.T) {
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), "model = \"x\"\n\n[mcp_servers.relay]\ncommand = \"relay-mcp\"\n")
	writeFile(t, filepath.Join(home, ".codex", "AGENTS.md"), "agents\n")
	writeFile(t, filepath.Join(home, ".codex", "auth.json"), "MAIN-CODEX-AUTH")
	writeFile(t, filepath.Join(home, ".codex", "sessions", "2026", "x.jsonl"), "MAIN-ROLLOUT")
	personal := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	result, err := Sync(home, personal, time.Now())
	if err != nil || result.MCP != CodexConfigLink {
		t.Fatalf("config.toml should be linked: %+v %v", result, err)
	}
	if target, _ := os.Readlink(filepath.Join(personal.Root(home), "config.toml")); target != filepath.Join(home, ".codex", "config.toml") {
		t.Fatalf("config.toml link target %q", target)
	}
	for _, name := range []string{"auth.json", "sessions", "history.jsonl"} {
		if _, err := os.Lstat(filepath.Join(personal.Root(home), name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s must not exist in the account directory", name)
		}
	}
	assertNoContent(t, personal.Root(home), "MAIN-CODEX-AUTH", "MAIN-ROLLOUT")
}

func TestCodexConfigWithAccountKeysMergesOnlyMCPTables(t *testing.T) {
	home := t.TempDir()
	main := strings.Join([]string{
		`model = "gpt"`,
		`forced_chatgpt_workspace_id = "MAIN-WORKSPACE"`,
		``,
		`[projects."/work"]`,
		`trust_level = "trusted"`,
		``,
		`[mcp_servers.node_repl]`,
		`command = "node"`,
		``,
		`[mcp_servers.node_repl.env]`,
		`CODEX_HOME = "/home/u/.codex"`,
		`OTHER = "kept"`,
		``,
		`[mcp_servers.relay]`,
		`command = "relay-mcp"`,
		``,
	}, "\n")
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), main)
	personal := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	accountConfig := filepath.Join(personal.Root(home), "config.toml")
	writeFile(t, accountConfig, "model = \"personal-model\"\n\n[mcp_servers.stale]\ncommand = \"stale\"\n")
	result, err := Sync(home, personal, time.Date(2026, 10, 17, 0, 0, 0, 0, time.UTC))
	if err != nil || result.MCP != CodexConfigMerge || result.MCPCount != 2 || result.MCPBackup == "" || len(result.Notes) != 1 {
		t.Fatalf("merge: %+v %v", result, err)
	}
	merged := string(mustRead(t, accountConfig))
	for _, want := range []string{`model = "personal-model"`, `[mcp_servers.node_repl]`, `[mcp_servers.relay]`, `OTHER = "kept"`} {
		if !strings.Contains(merged, want) {
			t.Fatalf("merged config lacks %q:\n%s", want, merged)
		}
	}
	// Project trust is the one other main setting copied (first-run answers,
	// see mergeLaunchState), as its own table.
	if !strings.Contains(merged, "[projects.\"/work\"]\ntrust_level = \"trusted\"\n") {
		t.Fatalf("merged config lacks the main project trust:\n%s", merged)
	}
	for _, unwanted := range []string{"MAIN-WORKSPACE", "CODEX_HOME", "stale", `model = "gpt"`} {
		if strings.Contains(merged, unwanted) {
			t.Fatalf("merged config contains %q:\n%s", unwanted, merged)
		}
	}
	again, err := Sync(home, personal, time.Date(2026, 10, 17, 0, 1, 0, 0, time.UTC))
	if err != nil || again.MCP != MergeUnchanged || string(mustRead(t, accountConfig)) != merged {
		t.Fatalf("second merge must be a no-op: %+v %v", again, err)
	}
}

func TestCodexMergeReplacesAnEarlierConfigLinkAndRefusesMultilineStrings(t *testing.T) {
	home := t.TempDir()
	mainPath := filepath.Join(home, ".codex", "config.toml")
	writeFile(t, mainPath, "[mcp_servers.a]\ncommand = \"a\"\n")
	personal := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	if result, err := Sync(home, personal, time.Now()); err != nil || result.MCP != CodexConfigLink {
		t.Fatalf("first sync should link: %+v %v", result, err)
	}
	writeFile(t, mainPath, "cli_auth_credentials_store = \"keyring\"\n[mcp_servers.a]\ncommand = \"a\"\n")
	result, err := Sync(home, personal, time.Now())
	if err != nil || result.MCP != CodexConfigMerge {
		t.Fatalf("account key should switch to merge: %+v %v", result, err)
	}
	info, _ := os.Lstat(filepath.Join(personal.Root(home), "config.toml"))
	if info.Mode()&os.ModeSymlink != 0 || strings.Contains(string(mustRead(t, mainPath)), "Relay") {
		t.Fatal("the link must become the account's own file without touching main")
	}
	writeFile(t, mainPath, "cli_auth_credentials_store = \"keyring\"\nnote = \"\"\"\n[x]\n\"\"\"\n")
	if result, err := Sync(home, personal, time.Now()); err == nil || result.MCP != MergeRefused {
		t.Fatalf("multi-line TOML must be refused: %+v", result)
	}
}

func TestStatusReadsOnlyExistenceAndProviderStatus(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	// An unreadable credential file still counts: only its existence is used.
	if err := os.Chmod(filepath.Join(home, ".claude", ".credentials.json"), 0); err != nil {
		t.Fatal(err)
	}
	probed := map[string]string{}
	var probedMutex sync.Mutex
	// List checks accounts at once.
	probe := func(_ context.Context, provider, override string) ([]byte, error) {
		probedMutex.Lock()
		probed[provider+":"+override] = "yes"
		probedMutex.Unlock()
		if provider == "codex" {
			return []byte("Logged in using an API key - sk-proj-***ABCD\n"), nil
		}
		return []byte(`{"loggedIn":true,"email":"person@example.org","orgName":"Org","authMethod":"claude.ai"}`), nil
	}
	if err := os.MkdirAll(filepath.Join(home, ".codex"), 0o700); err != nil {
		t.Fatal(err)
	}
	statuses := List(home, DefaultRegistry(), probe)
	byKey := map[string]Status{}
	for _, status := range statuses {
		byKey[status.Provider+":"+status.Label] = status
	}
	work := byKey["claude:work"]
	if !work.Exists || work.LoggedIn != "yes" || work.Method != "file" || work.Email != "person@example.org" {
		t.Fatalf("Claude work status: %+v", work)
	}
	codex := byKey["codex:work"]
	if codex.LoggedIn != "yes" || codex.Method != "api_key" || codex.Email != "" {
		t.Fatalf("Codex status must not forward key text: %+v", codex)
	}
	encoded, _ := json.Marshal(statuses)
	if strings.Contains(string(encoded), "ABCD") || strings.Contains(string(encoded), "MAIN-CREDENTIAL") {
		t.Fatal("status leaked credential text")
	}
	// A missing account directory is never probed: Claude's status command
	// would create files in it.
	if personal := byKey["claude:personal"]; personal.Exists || personal.LoggedIn != "no" || probed["claude:"+filepath.Join(home, ".claude-personal")] != "" {
		t.Fatalf("missing directory was probed: %+v", personal)
	}
}
