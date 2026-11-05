package agentaccounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestRegistryKeepsHistoryAndExclusionsOnlyForOtherAccounts(t *testing.T) {
	home := t.TempDir()
	registry := DefaultRegistry()
	registry.Accounts[1].ShareHistory = true
	registry.Accounts[1].MCPExclude = []string{"zeta", "alpha", "zeta"}
	saved, err := Save(home, registry)
	if err != nil {
		t.Fatal(err)
	}
	if !saved.Accounts[1].ShareHistory || !reflect.DeepEqual(saved.Accounts[1].MCPExclude, []string{"alpha", "zeta"}) {
		t.Fatalf("history opt-in or exclusions not normalised: %+v", saved.Accounts[1])
	}
	for _, mutate := range []func(*Registry){
		func(r *Registry) { r.Accounts[0].ShareHistory = true },
		func(r *Registry) { r.Accounts[0].MCPExclude = []string{"relay"} },
		func(r *Registry) { r.Accounts[1].MCPExclude = []string{"bad\nname"} },
		func(r *Registry) { r.Accounts[1].MCPExclude = []string{""} },
		func(r *Registry) { r.Accounts[1].MCPExclude = make([]string, 65) },
	} {
		bad := DefaultRegistry()
		mutate(&bad)
		if _, err := Normalize(bad, home); err == nil {
			t.Fatalf("invalid registry accepted: %+v", bad.Accounts[:2])
		}
	}
}

func TestClaudeExcludedServersAreNeverCopied(t *testing.T) {
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".claude.json"),
		`{"mcpServers":{"relay":{"command":"relay-mcp"},"secret":{"command":"x","env":{"API_KEY":"EXCLUDED-SECRET-VALUE"}}}}`)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal", MCPExclude: []string{"secret"}}
	root := personal.Root(home)
	// An earlier sync had copied the server; excluding it removes it.
	writeFile(t, filepath.Join(root, ".claude.json"), `{"numStartups":1,"mcpServers":{"secret":{"env":{"API_KEY":"EXCLUDED-SECRET-VALUE"}}}}`)
	result, err := Sync(home, personal, time.Now())
	if err != nil || result.MCP != MergeUpdated || result.MCPCount != 1 {
		t.Fatalf("sync: %+v %v", result, err)
	}
	document := readJSON(t, filepath.Join(root, ".claude.json"))
	servers := document["mcpServers"].(map[string]any)
	if _, ok := servers["secret"]; ok || servers["relay"] == nil || document["numStartups"] != float64(1) {
		t.Fatalf("merged account config: %v", document)
	}
	if data := mustRead(t, filepath.Join(root, ".claude.json")); strings.Contains(string(data), "EXCLUDED-SECRET-VALUE") {
		t.Fatal("an excluded server's env value reached the account config")
	}
}

func TestCodexExcludedServersAreNeverCopied(t *testing.T) {
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), strings.Join([]string{
		`model = "gpt"`, ``,
		`[mcp_servers.relay]`, `command = "relay-mcp"`, ``,
		`[mcp_servers."secret.server"]`, `command = "x"`, ``,
		`[mcp_servers."secret.server".env]`, `API_KEY = "EXCLUDED-CODEX-VALUE"`, ``,
	}, "\n"))
	personal := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal", MCPExclude: []string{"secret.server"}}
	result, err := Sync(home, personal, time.Now())
	if err != nil || result.MCP != CodexConfigMerge || result.MCPCount != 1 {
		t.Fatalf("an exclusion must copy instead of link: %+v %v", result, err)
	}
	text := string(mustRead(t, filepath.Join(personal.Root(home), "config.toml")))
	if strings.Contains(text, "EXCLUDED-CODEX-VALUE") || strings.Contains(text, "secret.server") || !strings.Contains(text, "[mcp_servers.relay]") {
		t.Fatalf("codex account config:\n%s", text)
	}
}

func TestMCPPreviewListsOnlyKeyNames(t *testing.T) {
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".claude.json"),
		`{"oauthAccount":{"emailAddress":"MAIN-ACCOUNT"},"mcpServers":{"web":{"url":"https://x","headers":{"Authorization":"Bearer PREVIEW-HEADER-VALUE"}},"db":{"command":"db","env":{"DB_PASSWORD":"PREVIEW-ENV-VALUE","DB_USER":"u"}}}}`)
	claude := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal", MCPExclude: []string{"db"}}
	preview, err := PreviewMCP(home, claude)
	if err != nil {
		t.Fatal(err)
	}
	want := []MCPServerPreview{
		{Name: "db", EnvKeys: []string{"DB_PASSWORD", "DB_USER"}, Excluded: true},
		{Name: "web", HeaderKeys: []string{"Authorization"}},
	}
	if !reflect.DeepEqual(preview.Servers, want) {
		t.Fatalf("claude preview: %+v", preview.Servers)
	}
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), strings.Join([]string{
		`[mcp_servers.search]`, `command = "s"`, `env = { SEARCH_TOKEN = "PREVIEW-INLINE-VALUE", "QUOTED_KEY" = 'x, y = z' }`,
		`http_headers = { "X-Api-Key" = "PREVIEW-HEADER2" }`, ``,
		`[mcp_servers.search.env_http_headers]`, `X_Env = "PREVIEW-ENVHDR"`, ``,
		`[mcp_servers.node_repl.env]`, `CODEX_HOME = "/x"`, ``,
	}, "\n"))
	codex := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	preview, err = PreviewMCP(home, codex)
	if err != nil {
		t.Fatal(err)
	}
	want = []MCPServerPreview{
		{Name: "node_repl", EnvKeys: []string{"CODEX_HOME"}},
		{Name: "search", EnvKeys: []string{"QUOTED_KEY", "SEARCH_TOKEN"}, HeaderKeys: []string{"X-Api-Key", "X_Env"}},
	}
	if !reflect.DeepEqual(preview.Servers, want) {
		t.Fatalf("codex preview: %+v", preview.Servers)
	}
	data, _ := json.Marshal(preview)
	claudeData, _ := json.Marshal(want)
	for _, secret := range []string{"PREVIEW-", "MAIN-ACCOUNT", "Bearer", "x, y"} {
		if strings.Contains(string(data), secret) || strings.Contains(string(claudeData), secret) {
			t.Fatalf("preview leaks a value %q: %s", secret, data)
		}
	}
	if _, err := PreviewMCP(home, Account{Provider: "claude", Label: "work"}); err == nil {
		t.Fatal("the main account has no preview")
	}
}

func TestSharedHistoryIsOptInAndNeverTakesOwnConversations(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	root := personal.Root(home)
	result, err := Sync(home, personal, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, "projects")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("history linked without the opt-in")
	}
	personal.ShareHistory = true
	// An empty own projects/ is replaced by the link.
	if err := os.MkdirAll(filepath.Join(root, "projects"), 0o700); err != nil {
		t.Fatal(err)
	}
	result, err = Sync(home, personal, time.Now())
	if err != nil || syncedState(result, "projects") != LinkLinked {
		t.Fatalf("history not linked: %+v %v", result, err)
	}
	if target, _ := os.Readlink(filepath.Join(root, "projects")); target != filepath.Join(home, ".claude", "projects") {
		t.Fatalf("projects link target %q", target)
	}
	for _, name := range []string{".credentials.json", "sessions", "history.jsonl"} {
		if _, err := os.Lstat(filepath.Join(root, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s must never be linked by shared history", name)
		}
	}
	status := AccountStatus(home, personal, nil)
	if !hasLink(status.Links, "projects", LinkLinked) {
		t.Fatalf("status lacks the history link: %+v", status.Links)
	}
	// Turning the opt-in off removes only Relay's own link.
	personal.ShareHistory = false
	result, err = Sync(home, personal, time.Now())
	if err != nil || syncedState(result, "projects") != LinkHistoryUnlinked {
		t.Fatalf("history not unlinked: %+v %v", result, err)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "projects", "p", "s.jsonl")); err != nil {
		t.Fatal("unlinking touched the main history")
	}
	// A non-empty own history is kept and reported, never renamed.
	writeFile(t, filepath.Join(root, "projects", "own", "o.jsonl"), "OWN")
	personal.ShareHistory = true
	result, err = Sync(home, personal, time.Now())
	if err != nil || syncedState(result, "projects") != LinkKeptOwnHistory || len(result.Notes) == 0 {
		t.Fatalf("own history must be kept: %+v %v", result, err)
	}
	if string(mustRead(t, filepath.Join(root, "projects", "own", "o.jsonl"))) != "OWN" {
		t.Fatal("own history changed")
	}
	// Codex shares sessions and archived sessions, never auth.json.
	writeFile(t, filepath.Join(home, ".codex", "sessions", "2026", "r.jsonl"), "R")
	writeFile(t, filepath.Join(home, ".codex", "auth.json"), "MAIN-CODEX-AUTH")
	codex := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal", ShareHistory: true}
	result, err = Sync(home, codex, time.Now())
	if err != nil || syncedState(result, "sessions") != LinkLinked || syncedState(result, "archived_sessions") != LinkMissingMain {
		t.Fatalf("codex history: %+v %v", result, err)
	}
	if _, err := os.Lstat(filepath.Join(codex.Root(home), "auth.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("auth.json linked")
	}
}

func syncedState(result SyncResult, name string) string {
	state := ""
	for _, link := range result.Links {
		if link.Name == name {
			state = link.State
		}
	}
	return state
}

func hasLink(links []LinkResult, name, state string) bool {
	for _, link := range links {
		if link.Name == name && link.State == state {
			return true
		}
	}
	return false
}

func TestAccountProcessHelper(t *testing.T) {
	if os.Getenv("RELAY_ACCOUNT_SYNC_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(60 * time.Second)
}

func TestSyncRefusesWhileAnAgentUsesTheAccount(t *testing.T) {
	home := t.TempDir()
	claudeMain(t, home)
	personal := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	root := personal.Root(home)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	original := agentProcessName
	t.Cleanup(func() { agentProcessName = original })
	self := filepath.Base(os.Args[0])
	agentProcessName = func(name string) bool { return strings.HasPrefix(self, name) || strings.HasPrefix(name, self) }
	// A symlinked alias of the account root still names the same account.
	alias := filepath.Join(home, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestAccountProcessHelper$")
	command.Env = []string{"RELAY_ACCOUNT_SYNC_HELPER=1", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + alias}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	stopped := false
	stop := func() {
		if !stopped {
			stopped = true
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	}
	t.Cleanup(stop)
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if vars, err := agentlaunch.ProcessEnvironment(command.Process.Pid, "RELAY_ACCOUNT_SYNC_HELPER"); err == nil && vars["RELAY_ACCOUNT_SYNC_HELPER"] == "1" {
			break
		}
	}
	result, err := Sync(home, personal, time.Now())
	if err == nil || !strings.Contains(err.Error(), "Stop the claude agents using this account first") ||
		!strings.Contains(err.Error(), "can lose their configuration writes") {
		t.Fatalf("sync ran while an agent used the account: %+v %v", result, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "CLAUDE.md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a refused sync changed the account")
	}
	stop()
	if result, err := Sync(home, personal, time.Now()); err != nil || syncedState(result, "CLAUDE.md") != LinkLinked {
		t.Fatalf("sync after the agent stopped: %+v %v", result, err)
	}
}

func TestUsageKeepsOnlyReportedWindowsAndNeverEstimates(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{".claude", ".codex", ".claude-personal"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	claudeLine := `{"type":"control_response","response":{"subtype":"success","request_id":"u2","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":28,"resets_at":"2026-10-17T10:39:59.639615+00:00","used_dollars":12},"seven_day":{"utilization":36,"resets_at":"2026-10-21T23:59:59+00:00"}},"limits":[{"kind":"session","text":"SECRET-TEXT"}]}}}`
	codexLine := `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1792649609},"secondary":null,"credits":{"balance":"60641.0"},"planType":"pro"},"accountId":"ACCOUNT-ID-SECRET","rateLimitResetCredits":{"credits":[{"id":"RateLimitResetCredit_SECRET"}]}}}`
	var called []string
	var mutex sync.Mutex
	runner := func(ctx context.Context, provider, override string) ([]byte, error) {
		mutex.Lock()
		called = append(called, provider+":"+override)
		mutex.Unlock()
		switch {
		case provider == "claude" && override == "":
			return []byte(claudeLine), nil
		case provider == "codex":
			return []byte(codexLine), nil
		}
		return []byte("garbage{"), nil
	}
	accounts := []Account{
		{Provider: "claude", Label: "work"},
		{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"},
		{Provider: "codex", Label: "work"},
		{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"},
	}
	usage := ReadUsage(home, accounts, runner, time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC))
	if usage[0].Status != UsageOK || len(usage[0].Windows) != 2 || usage[0].Windows[0] != (UsageWindow{Name: "five_hour",
		UsedPercent: 28, ResetsAt: "2026-10-17T10:39:59Z", WindowMinutes: 300}) {
		t.Fatalf("claude usage: %+v", usage[0])
	}
	if usage[1].Status != UsageUnknown || usage[1].Windows != nil || usage[1].Reason == "" {
		t.Fatalf("garbage output must be unknown, not estimated: %+v", usage[1])
	}
	if usage[2].Status != UsageOK || usage[2].Windows[0] != (UsageWindow{Name: "primary", UsedPercent: 23,
		ResetsAt: "2026-10-22T06:13:29Z", WindowMinutes: 10080}) || len(usage[2].Windows) != 1 {
		t.Fatalf("codex usage: %+v", usage[2])
	}
	if usage[3].Status != UsageUnknown || usage[3].Reason != "account directory does not exist" || usage[3].ReadAt != "2026-10-17T09:00:00Z" {
		t.Fatalf("missing account: %+v", usage[3])
	}
	for _, call := range called {
		if strings.HasSuffix(call, ".codex-personal") {
			t.Fatal("a missing account directory was probed")
		}
	}
	data, _ := json.Marshal(usage)
	for _, secret := range []string{"ACCOUNT-ID-SECRET", "RateLimitResetCredit", "60641", "SECRET-TEXT", "used_dollars", `"max"`, `"pro"`, "planType", "subscription"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("usage kept a field outside the whitelist (%s): %s", secret, data)
		}
	}
	// A provider that reports no plan limits is unknown, as is a failure.
	unavailable := `{"type":"control_response","response":{"subtype":"success","request_id":"u2","response":{"rate_limits_available":false,"rate_limits":null}}}`
	usage = ReadUsage(home, accounts[:1], func(context.Context, string, string) ([]byte, error) { return []byte(unavailable), nil }, time.Now())
	if usage[0].Status != UsageUnknown || usage[0].Windows != nil {
		t.Fatalf("unavailable limits: %+v", usage[0])
	}
	usage = ReadUsage(home, accounts[2:3], func(context.Context, string, string) ([]byte, error) {
		return nil, errors.New("codex did not answer in time")
	}, time.Now())
	if usage[0].Status != UsageUnknown || usage[0].Reason != "codex did not answer in time" {
		t.Fatalf("timeout: %+v", usage[0])
	}
}

func TestResponseLineReaderIsBounded(t *testing.T) {
	matches := func(line []byte) bool { return strings.Contains(string(line), `"id":2`) }
	line, err := readResponseLine(strings.NewReader("noise\n{\"id\":1}\n{\"id\":2,\"result\":{}}\n"), matches)
	if err != nil || string(line) != `{"id":2,"result":{}}` {
		t.Fatalf("line %q %v", line, err)
	}
	if _, err := readResponseLine(strings.NewReader(strings.Repeat("x", 2<<20)+"\n"), matches); err == nil {
		t.Fatal("an oversized line was accepted")
	}
	if _, err := readResponseLine(strings.NewReader("{\"id\":1}\n"), matches); err == nil {
		t.Fatal("EOF without an answer must fail")
	}
}

// RELAY_LIVE_USAGE=1 reads the main accounts' real usage through the
// providers' own CLIs (no files are written; nothing secret is printed).
func TestLiveProviderUsage(t *testing.T) {
	if os.Getenv("RELAY_LIVE_USAGE") != "1" {
		t.Skip("set RELAY_LIVE_USAGE=1")
	}
	home, _ := os.UserHomeDir()
	for _, usage := range ReadUsage(home, []Account{{Provider: "claude", Label: "work"}, {Provider: "codex", Label: "work"}}, ProviderUsage, time.Now()) {
		data, _ := json.Marshal(usage)
		t.Log(string(data))
	}
}
