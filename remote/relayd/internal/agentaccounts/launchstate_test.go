package agentaccounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const mainClaudeState = `{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.0",
  "hasSeenTasksHint": true,
  "shiftEnterKeyBindingInstalled": true,
  "autoUpdates": false,
  "theme": "dark",
  "userID": "main-user-id",
  "oauthAccount": {"emailAddress": "main@example.invalid", "accountUuid": "main-uuid"},
  "mcpServers": {"local": {"command": "true"}},
  "projects": {
    "/work/trusted": {"hasTrustDialogAccepted": true, "hasClaudeMdExternalIncludesWarningShown": true,
      "hasClaudeMdExternalIncludesApproved": false, "history": [{"display": "main prompt"}], "lastCost": 3},
    "/work/own": {"hasTrustDialogAccepted": true}
  }
}`

func launchStateFixture(t *testing.T, account string) (string, Account, string) {
	t.Helper()
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(home, ".claude.json"), mainClaudeState)
	found, _ := registry.Find("claude", "personal")
	root := found.Root(home)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, ".claude.json")
	if account != "" {
		writeFile(t, path, account)
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return home, found, path
}

func jsonObject(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(mustRead(t, path), &document); err != nil {
		t.Fatal(err)
	}
	return document
}

func TestLaunchStateAddsOnlyMissingFirstRunAndTrustAnswers(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID": "account-user-id",
  "oauthAccount": {"emailAddress": "max@example.invalid"}, "autoUpdates": true, "numStartups": 4,
  "projects": {"/work/own": {"hasTrustDialogAccepted": false, "history": [{"display": "own prompt"}]}}}`)
	before := jsonObject(t, path)
	state, added, err := mergeLaunchState(home, account)
	if err != nil || state != LaunchStateUpdated {
		t.Fatalf("merge: %s %v", state, err)
	}
	after := jsonObject(t, path)
	// Every key the account had is unchanged, including an explicit false.
	for key, value := range before {
		if key != "projects" && !equalJSON(after[key], value) {
			t.Errorf("%s changed: %s -> %s", key, value, after[key])
		}
	}
	for _, key := range []string{"hasCompletedOnboarding", "lastOnboardingVersion", "hasSeenTasksHint", "shiftEnterKeyBindingInstalled"} {
		if after[key] == nil {
			t.Errorf("%s was not added", key)
		}
	}
	// Nothing but the allow-listed keys comes from the main file.
	for _, key := range []string{"theme", "mcpServers"} {
		if _, ok := after[key]; ok {
			t.Errorf("%s was copied", key)
		}
	}
	if !strings.Contains(string(after["userID"]), "account-user-id") || !strings.Contains(string(after["oauthAccount"]), "max@") ||
		strings.Contains(string(mustRead(t, path)), "main-uuid") || strings.Contains(string(mustRead(t, path)), "main-user-id") {
		t.Fatal("identity values were copied or changed")
	}
	var projects map[string]map[string]json.RawMessage
	if err := json.Unmarshal(after["projects"], &projects); err != nil {
		t.Fatal(err)
	}
	trusted := projects["/work/trusted"]
	if string(trusted["hasTrustDialogAccepted"]) != "true" || string(trusted["hasClaudeMdExternalIncludesWarningShown"]) != "true" ||
		string(trusted["hasClaudeMdExternalIncludesApproved"]) != "false" || len(trusted) != 3 {
		t.Fatalf("trusted project: %v", trusted)
	}
	own := projects["/work/own"]
	if string(own["hasTrustDialogAccepted"]) != "false" || !strings.Contains(string(own["history"]), "own prompt") {
		t.Fatalf("the account's own project answer was changed: %v", own)
	}
	if added != 7 {
		t.Errorf("added = %d, want 7", added)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode: %v %v", info, err)
	}
	// A second merge changes nothing.
	data := mustRead(t, path)
	if state, _, err := mergeLaunchState(home, account); err != nil || state != LaunchStateUnchanged {
		t.Fatalf("second merge: %s %v", state, err)
	}
	if string(mustRead(t, path)) != string(data) {
		t.Fatal("a second merge rewrote the file")
	}
}

func TestLaunchStateCreatesAMissingAccountFileWithOnlyTheAnswers(t *testing.T) {
	home, account, path := launchStateFixture(t, "")
	if state, _, err := mergeLaunchState(home, account); err != nil || state != LaunchStateUpdated {
		t.Fatalf("merge: %s %v", state, err)
	}
	after := jsonObject(t, path)
	if len(after) != 6 || after["oauthAccount"] != nil || after["userID"] != nil {
		t.Fatalf("created file: %s", mustRead(t, path))
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	// A file that appears between the read and the write is never replaced.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	original := beforeLaunchStateWrite
	t.Cleanup(func() { beforeLaunchStateWrite = original })
	beforeLaunchStateWrite = func(path string) { writeFile(t, path, `{"userID": "provider"}`) }
	if state, _, err := mergeLaunchState(home, account); err == nil || state != LaunchStateRefused ||
		string(mustRead(t, path)) != `{"userID": "provider"}` {
		t.Fatalf("appeared file: %s %v", state, err)
	}
	beforeLaunchStateWrite = original
	// A registered account whose folder does not exist yet: nothing is
	// created and nothing is reported.
	if err := os.RemoveAll(account.Root(home)); err != nil {
		t.Fatal(err)
	}
	if note := PrepareLaunch(home, "claude", account.Root(home)); note != "" || present(account.Root(home)) {
		t.Fatalf("missing folder: %q", note)
	}
}

func TestLaunchStateRefusesLinksMalformedFilesAndAChangedFile(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"projects": []}`)
	if state, _, err := mergeLaunchState(home, account); err == nil || state != LaunchStateRefused || string(mustRead(t, path)) != `{"projects": []}` {
		t.Fatalf("projects not an object: %s %v", state, err)
	}
	writeFile(t, path, `{"userID": "x"`)
	if _, _, err := mergeLaunchState(home, account); err == nil {
		t.Fatal("a truncated file was merged")
	}
	target := filepath.Join(home, "elsewhere.json")
	writeFile(t, target, `{}`)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, _, err := mergeLaunchState(home, account); err == nil || string(mustRead(t, target)) != `{}` {
		t.Fatal("a linked account file was followed")
	}
	// The file changes between the read and the write: it is left as the
	// other writer made it.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, `{"userID": "account"}`)
	original := beforeLaunchStateWrite
	t.Cleanup(func() { beforeLaunchStateWrite = original })
	beforeLaunchStateWrite = func(path string) {
		time.Sleep(10 * time.Millisecond)
		writeFile(t, path, `{"userID": "account", "numStartups": 5}`)
	}
	if state, _, err := mergeLaunchState(home, account); err == nil || state != LaunchStateRefused ||
		string(mustRead(t, path)) != `{"userID": "account", "numStartups": 5}` {
		t.Fatalf("changed file: %s %v %s", state, err, mustRead(t, path))
	}
}

func TestPrepareLaunchSkipsTheMainAccountUnknownFoldersAndALockedAccount(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID": "account"}`)
	if note := PrepareLaunch(home, "claude", filepath.Join(home, ".claude")); note != "" {
		t.Fatal(note)
	}
	if note := PrepareLaunch(home, "claude", filepath.Join(home, ".claude-unknown")); note != "" || jsonObject(t, path)["hasCompletedOnboarding"] != nil {
		t.Fatalf("unknown folder: %q", note)
	}
	// The accounts lock is held by an accounts request.
	unlock, err := lockAccounts(home, true)
	if err != nil {
		t.Fatal(err)
	}
	note := PrepareLaunch(home, "claude", account.Root(home))
	unlock()
	if !strings.Contains(note, "accounts change is in progress") || jsonObject(t, path)["hasCompletedOnboarding"] != nil {
		t.Fatalf("locked: %q", note)
	}
	if note := PrepareLaunch(home, "claude", account.Root(home)+"/"); note != "" || string(jsonObject(t, path)["hasCompletedOnboarding"]) != "true" {
		t.Fatalf("free account: %q", note)
	}
}

// startLiveAgent runs a helper process that the running-agent scan reports
// as an agent using the account.
func startLiveAgent(t *testing.T, home string, account Account) {
	t.Helper()
	original := agentProcessName
	t.Cleanup(func() { agentProcessName = original })
	agentProcessName = func(name string) bool { return true }
	startHolder(t, "HOME="+home, "RELAY_REMOVAL_HOLDER="+account.Root(home), "CLAUDE_CONFIG_DIR="+account.Root(home))
	if running, err := runningAgents("claude", account.Root(home)); err != nil || len(running) == 0 {
		t.Fatalf("the helper agent is not seen: %v %v", running, err)
	}
}

// The user's choice: the merge runs while another agent uses the account.
// A save by that agent between Relay's read and its write is kept as the
// agent wrote it, and the merge is made again at the next launch.
func TestPrepareLaunchMergesWhileAnotherAgentUsesTheAccount(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID": "account"}`)
	startLiveAgent(t, home, account)
	original := beforeLaunchStateWrite
	t.Cleanup(func() { beforeLaunchStateWrite = original })
	live := `{"userID": "account", "numStartups": 9}`
	beforeLaunchStateWrite = func(path string) {
		time.Sleep(10 * time.Millisecond)
		writeFile(t, path, live)
	}
	note := PrepareLaunch(home, "claude", account.Root(home))
	if !strings.Contains(note, "changed while Relay read it") || string(mustRead(t, path)) != live {
		t.Fatalf("live save: %q %s", note, mustRead(t, path))
	}
	beforeLaunchStateWrite = original
	if note := PrepareLaunch(home, "claude", account.Root(home)); note != "" {
		t.Fatalf("busy account: %q", note)
	}
	after := jsonObject(t, path)
	if string(after["hasCompletedOnboarding"]) != "true" || string(after["numStartups"]) != "9" || string(after["userID"]) != `"account"` {
		t.Fatalf("after merge: %s", mustRead(t, path))
	}
}

// Sync still refuses its links and MCP servers while an agent runs, but
// copies the first-run and trust answers.
func TestSyncWhileAnAgentRunsCopiesOnlyFirstRunAnswers(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID": "account"}`)
	writeFile(t, filepath.Join(home, ".claude", "CLAUDE.md"), "main instructions")
	startLiveAgent(t, home, account)
	result, err := Sync(home, account, time.Now())
	if err == nil || !strings.Contains(err.Error(), "Stop the claude agents") || !strings.Contains(err.Error(), "Only the first-run and trust settings were copied") ||
		result.FirstRun != LaunchStateUpdated {
		t.Fatalf("sync: %+v %v", result, err)
	}
	after := jsonObject(t, path)
	if string(after["hasCompletedOnboarding"]) != "true" || after["mcpServers"] != nil {
		t.Fatalf("after sync: %s", mustRead(t, path))
	}
	if _, err := os.Lstat(filepath.Join(account.Root(home), "CLAUDE.md")); err == nil {
		t.Fatal("a shared file was linked while an agent runs")
	}
	// Nothing more to copy: the refusal is the one Sync always gave.
	if _, err := Sync(home, account, time.Now()); err == nil || strings.Contains(err.Error(), "Only the first-run") {
		t.Fatalf("second sync: %v", err)
	}
	// The host request refuses before its preview check, after the same merge.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	_, err = Handle(Request{Action: "sync", Provider: "claude", Label: "personal", PreviewFingerprint: "reviewed"}, nil)
	if err == nil || !strings.Contains(err.Error(), "Only the first-run and trust settings were copied") ||
		string(jsonObject(t, path)["hasCompletedOnboarding"]) != "true" {
		t.Fatalf("host request: %v", err)
	}
}

func TestSyncAlsoCopiesFirstRunAnswers(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID": "account"}`)
	result, err := Sync(home, account, time.Now())
	if err != nil || result.FirstRun != LaunchStateUpdated || result.FirstRunAdded != 9 {
		t.Fatalf("sync: %+v %v", result, err)
	}
	after := jsonObject(t, path)
	if string(after["hasCompletedOnboarding"]) != "true" || string(after["userID"]) != `"account"` || after["mcpServers"] == nil {
		t.Fatalf("after sync: %s", mustRead(t, path))
	}
}

const mainCodexConfig = `model = "gpt-main"

[projects."/work/trusted"]
trust_level = "trusted"

[projects."/work/own"]
trust_level = "trusted"

[projects.'/work/with "quote"']
trust_level = "untrusted"
`

func TestCodexTrustIsAppendedWithoutChangingTheAccountsText(t *testing.T) {
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	account, _ := registry.Find("codex", "personal")
	writeFile(t, filepath.Join(home, ".codex", "config.toml"), mainCodexConfig)
	path := filepath.Join(account.Root(home), "config.toml")
	own := "# own settings\nforced_login_method = \"chatgpt\"\n\n[projects.\"/work/own\"]\ntrust_level = \"untrusted\"\n"
	writeFile(t, path, own)
	if state, added, err := mergeLaunchState(home, account); err != nil || state != LaunchStateUpdated || added != 2 {
		t.Fatalf("merge: %s %d %v", state, added, err)
	}
	text := string(mustRead(t, path))
	if !strings.HasPrefix(text, own) {
		t.Fatalf("the account's own text changed:\n%s", text)
	}
	document, err := parseTOML(text)
	if err != nil {
		t.Fatal(err)
	}
	projects := document.root.table("projects")
	if projects.table("/work/trusted").values["trust_level"] != "trusted" ||
		projects.table("/work/own").values["trust_level"] != "untrusted" ||
		projects.table(`/work/with "quote"`).values["trust_level"] != "untrusted" {
		t.Fatalf("projects:\n%s", text)
	}
	if strings.Contains(text, "gpt-main") {
		t.Fatal("a main setting other than project trust was copied")
	}
	if state, _, err := mergeLaunchState(home, account); err != nil || state != LaunchStateUnchanged {
		t.Fatalf("second merge: %s %v", state, err)
	}
	// An inline projects table cannot be extended: nothing changes.
	inline := "projects = { \"/x\" = { trust_level = \"trusted\" } }\n"
	writeFile(t, path, inline)
	if state, _, err := mergeLaunchState(home, account); err == nil || state != LaunchStateRefused || string(mustRead(t, path)) != inline {
		t.Fatalf("inline projects: %s %v", state, err)
	}
	// A config.toml linked to the main file already shares it.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, ".codex", "config.toml"), path); err != nil {
		t.Fatal(err)
	}
	if state, _, err := mergeLaunchState(home, account); err != nil || state != LaunchStateUnchanged {
		t.Fatalf("linked: %s %v", state, err)
	}
}
