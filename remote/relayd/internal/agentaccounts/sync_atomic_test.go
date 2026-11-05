package agentaccounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// noExchange makes the account's file system lack atomic exchange (NFS).
func noExchange(t *testing.T) {
	swapSeams(t)
	launchStateExchange = func(string, string) (bool, error) { return false, unix.EINVAL }
}

func noBackups(t *testing.T, root string) {
	t.Helper()
	if matches, _ := filepath.Glob(filepath.Join(root, "*relay-backup*")); len(matches) != 0 {
		t.Fatalf("backups left for a skipped merge: %v", matches)
	}
}

func TestClaudeMCPSyncSkipsAnExistingFileWithoutAtomicExchange(t *testing.T) {
	noExchange(t)
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	root := personal.Root(home)
	own := `{"numStartups":3,"mcpServers":{"old":{"command":"old"}}}`
	writeFile(t, filepath.Join(root, ".claude.json"), own)
	result, err := Sync(home, personal, time.Date(2026, 10, 18, 0, 0, 0, 0, time.UTC))
	if err != nil || result.MCP != MergeSkipped || result.MCPBackup != "" {
		t.Fatalf("sync: %+v %v", result, err)
	}
	if string(mustRead(t, filepath.Join(root, ".claude.json"))) != own {
		t.Fatal("the account's .claude.json was changed without atomic exchange")
	}
	notes := strings.Join(result.Notes, "\n")
	for _, want := range []string{"atomic exchange unsupported on this filesystem; merge skipped", "claude mcp add",
		"MCP servers were not copied"} {
		if !strings.Contains(notes, want) {
			t.Fatalf("notes lack %q:\n%s", want, notes)
		}
	}
	// Shared links (creating entries, not replacing a file) still happen.
	if !strings.Contains(strings.Join(func() []string {
		var names []string
		for _, link := range result.Links {
			if link.State == LinkLinked {
				names = append(names, link.Name)
			}
		}
		return names
	}(), ","), "settings.json") {
		t.Fatalf("shared links were not made: %+v", result.Links)
	}
	noBackups(t, root)
	noRelayTemps(t, filepath.Join(root, ".claude.json"))
}

func TestClaudeMCPSyncCreatesAMissingFileWithoutAtomicExchange(t *testing.T) {
	noExchange(t)
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	result, err := Sync(home, personal, time.Date(2026, 10, 18, 0, 0, 0, 0, time.UTC))
	if err != nil || result.MCP != MergeUpdated {
		t.Fatalf("sync: %+v %v", result, err)
	}
	if servers := readJSON(t, filepath.Join(personal.Root(home), ".claude.json"))["mcpServers"]; servers == nil {
		t.Fatal("the new .claude.json has no mcpServers")
	}
}

func TestCodexConfigMergeSkipsAnExistingFileWithoutAtomicExchange(t *testing.T) {
	noExchange(t)
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".codex", "config.toml"),
		"forced_chatgpt_workspace_id = \"MAIN\"\n\n[mcp_servers.relay]\ncommand = \"relay-mcp\"\n")
	personal := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	accountConfig := filepath.Join(personal.Root(home), "config.toml")
	own := "model = \"personal-model\"\n"
	writeFile(t, accountConfig, own)
	result, err := Sync(home, personal, time.Date(2026, 10, 18, 0, 0, 0, 0, time.UTC))
	if err != nil || result.MCP != MergeSkipped || result.MCPBackup != "" {
		t.Fatalf("sync: %+v %v", result, err)
	}
	if string(mustRead(t, accountConfig)) != own {
		t.Fatal("the account's config.toml was changed without atomic exchange")
	}
	if notes := strings.Join(result.Notes, "\n"); !strings.Contains(notes, "codex mcp add") || !strings.Contains(notes, "config.toml was not changed") {
		t.Fatalf("notes: %s", notes)
	}
	noBackups(t, personal.Root(home))
	noRelayTemps(t, accountConfig)
}

// codexLinkedAccount: an account config.toml that an earlier sync linked to
// the main file, which now sets an account key, so the link is replaced.
func codexLinkedAccount(t *testing.T) (codexConfigPlan, string, string) {
	t.Helper()
	home := t.TempDir()
	mainPath := filepath.Join(home, ".codex", "config.toml")
	writeFile(t, mainPath, "forced_chatgpt_workspace_id = \"MAIN\"\n\n[mcp_servers.relay]\ncommand = \"relay-mcp\"\n")
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	accountPath := filepath.Join(account.Root(home), "config.toml")
	if err := os.MkdirAll(filepath.Dir(accountPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(mainPath, accountPath); err != nil {
		t.Fatal(err)
	}
	plan, err := planCodexConfig(mainPath, accountPath, account)
	if err != nil || !plan.linked || plan.link {
		t.Fatalf("plan: %+v %v", plan, err)
	}
	return plan, mainPath, accountPath
}

func TestCodexLinkReplacementKeepsAProviderSaveThatTookTheLinksPlace(t *testing.T) {
	swapSeams(t)
	plan, _, accountPath := codexLinkedAccount(t)
	saved := "model = \"x\"\nproviderNewState = \"keep-me\"\n"
	// The provider renames its save over the link after Relay's check and
	// before the exchange.
	launchStateExchange = func(a, b string) (bool, error) {
		launchStateExchange = renameExchange
		providerSave(t, accountPath, saved)
		return renameExchange(a, b)
	}
	var result SyncResult
	err := plan.write("20261018T000000Z", &result)
	if err == nil || result.MCP != MergeRefused || string(mustRead(t, accountPath)) != saved {
		t.Fatalf("err=%v mcp=%s file=%q", err, result.MCP, mustRead(t, accountPath))
	}
	noRelayTemps(t, accountPath)
}

func TestCodexLinkReplacementWithoutAtomicExchangeKeepsTheLink(t *testing.T) {
	noExchange(t)
	plan, mainPath, accountPath := codexLinkedAccount(t)
	var result SyncResult
	if err := plan.write("20261018T000000Z", &result); err != nil || result.MCP != MergeSkipped {
		t.Fatalf("err=%v %+v", err, result)
	}
	if !isLinkTo(accountPath, mainPath) {
		t.Fatal("the link was removed without atomic exchange")
	}
	noRelayTemps(t, accountPath)
}

func TestCodexLinkReplacementMergesWithAtomicExchange(t *testing.T) {
	swapSeams(t)
	plan, _, accountPath := codexLinkedAccount(t)
	var result SyncResult
	if err := plan.write("20261018T000000Z", &result); err != nil || result.MCP != CodexConfigMerge {
		t.Fatalf("err=%v %+v", err, result)
	}
	if info, _ := os.Lstat(accountPath); !info.Mode().IsRegular() || !strings.Contains(string(mustRead(t, accountPath)), "[mcp_servers.relay]") {
		t.Fatal("the link was not replaced by the merged file")
	}
	noRelayTemps(t, accountPath)
}
