package agentaccounts

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
)

const movePaneDir = "/work/repos/project"

// moveSourceState is a main account that finished onboarding and trusts the
// pane's folder; it also holds identity, credential and unrelated keys that a
// move must never copy.
const moveSourceState = `{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.302",
  "hasSeenTasksHint": true,
  "shiftEnterKeyBindingInstalled": true,
  "autoUpdates": false,
  "oauthAccount": {"emailAddress": "source@example.invalid", "accountUuid": "source-uuid"},
  "userID": "source-user",
  "primaryApiKey": "sk-source-secret",
  "customApiKeyResponses": {"approved": ["source"]},
  "numStartups": 900,
  "mcpServers": {"source": {"command": "x"}},
  "projects": {
    "/work/repos/project": {"hasTrustDialogAccepted": true, "hasClaudeMdExternalIncludesWarningShown": true,
      "hasClaudeMdExternalIncludesApproved": true, "allowedTools": ["Bash"], "history": ["secret prompt"], "lastCost": 3.5},
    "/work/repos/other": {"hasTrustDialogAccepted": true, "history": ["other prompt"]}
  }
}`

// moveFixture is a home with the default registry, moveSourceState as the
// main account and target (if not empty) as the personal account's file.
func moveFixture(t *testing.T, target string, mode os.FileMode) (home, path string) {
	t.Helper()
	home = t.TempDir()
	if _, err := Save(home, DefaultRegistry()); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(home, ".claude.json"), moveSourceState)
	root := filepath.Join(home, ".claude-personal")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path = filepath.Join(root, ".claude.json")
	if target != "" {
		writeFile(t, path, target)
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
	}
	return home, path
}

func moveDocument(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	document := map[string]any{}
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	return document
}

func keysOf(value map[string]any) []string {
	var keys []string
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func inode(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return uint64(info.Sys().(*syscall.Stat_t).Ino)
}

func TestMoveOnboardingCopiesOnlyTheAllowlist(t *testing.T) {
	home, path := moveFixture(t, `{"numStartups": 1, "oauthAccount": {"emailAddress": "target@example.invalid"}, "userID": "target-user", "tipsHistory": {"x": 1}}`, 0o600)
	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err != nil || result.Status != MoveOnboardingUpdated || result.Copied == 0 {
		t.Fatalf("result %+v, %v", result, err)
	}
	document := moveDocument(t, path)
	want := []string{"autoUpdates", "hasCompletedOnboarding", "hasSeenTasksHint", "lastOnboardingVersion", "numStartups",
		"oauthAccount", "projects", "shiftEnterKeyBindingInstalled", "tipsHistory", "userID"}
	if got := keysOf(document); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("keys %v, want %v", got, want)
	}
	// The target's identity and other keys are its own, unchanged.
	if document["userID"] != "target-user" || document["oauthAccount"].(map[string]any)["emailAddress"] != "target@example.invalid" ||
		document["numStartups"].(float64) != 1 {
		t.Fatalf("target identity or state changed: %v", document)
	}
	data, _ := os.ReadFile(path)
	for _, secret := range []string{"sk-source-secret", "source-user", "source-uuid", "source@example.invalid", "customApiKeyResponses",
		"primaryApiKey", "mcpServers", "secret prompt", "allowedTools", "lastCost"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatalf("%q was copied into the target: %s", secret, data)
		}
	}
	if document["hasCompletedOnboarding"] != true || document["lastOnboardingVersion"] != "2.1.302" {
		t.Fatalf("onboarding not copied: %v", document)
	}
}

func TestMoveOnboardingMergesOnlyThePaneFolderProjectEntry(t *testing.T) {
	home, path := moveFixture(t, `{"projects": {"/elsewhere": {"history": ["mine"]}}}`, 0o600)
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil {
		t.Fatal(err)
	}
	projects := moveDocument(t, path)["projects"].(map[string]any)
	if got := keysOf(projects); strings.Join(got, ",") != "/elsewhere,"+movePaneDir {
		t.Fatalf("projects %v", got)
	}
	entry := projects[movePaneDir].(map[string]any)
	if got := keysOf(entry); strings.Join(got, ",") != "hasClaudeMdExternalIncludesApproved,hasClaudeMdExternalIncludesWarningShown,hasTrustDialogAccepted" ||
		entry["hasTrustDialogAccepted"] != true {
		t.Fatalf("pane entry %v", entry)
	}
	if mine := projects["/elsewhere"].(map[string]any); len(mine) != 1 {
		t.Fatalf("an unrelated project changed: %v", mine)
	}
}

func TestMoveOnboardingCreatesAMissingTargetFile(t *testing.T) {
	home, path := moveFixture(t, "", 0)
	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err != nil || result.Status != MoveOnboardingUpdated {
		t.Fatalf("result %+v, %v", result, err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Perm() != 0o600 || !info.Mode().IsRegular() {
		t.Fatalf("created file %v, %v", info, err)
	}
	document := moveDocument(t, path)
	if got := keysOf(document); strings.Join(got, ",") != "autoUpdates,hasCompletedOnboarding,hasSeenTasksHint,lastOnboardingVersion,projects,shiftEnterKeyBindingInstalled" {
		t.Fatalf("keys %v", got)
	}
}

func TestMoveOnboardingRefusesInvalidJSONAndLinks(t *testing.T) {
	home, path := moveFixture(t, `{"hasCompletedOnboarding": tru`, 0o600)
	before, _ := os.ReadFile(path)
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Fatalf("invalid JSON was accepted: %v", err)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Fatal("an invalid target file was changed")
	}
	// A link (here to the main file itself) is never followed or replaced.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, ".claude.json"), path); err != nil {
		t.Fatal(err)
	}
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err == nil || !strings.Contains(err.Error(), "link") {
		t.Fatalf("a linked target was accepted: %v", err)
	}
	if link, err := os.Readlink(path); err != nil || link != filepath.Join(home, ".claude.json") {
		t.Fatalf("the link changed: %q %v", link, err)
	}
}

func TestMoveOnboardingLeavesAnOnboardedTargetUnchanged(t *testing.T) {
	ready := `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.191", "userID": "target",
	  "projects": {"/work/repos/project": {"hasTrustDialogAccepted": true, "hasClaudeMdExternalIncludesWarningShown": true}}}`
	home, path := moveFixture(t, ready, 0o640)
	before, _ := os.Lstat(path)
	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err != nil || result.Status != MoveOnboardingReady || result.Copied != 0 {
		t.Fatalf("result %+v, %v", result, err)
	}
	after, _ := os.Lstat(path)
	if data, _ := os.ReadFile(path); string(data) != ready || !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("an onboarded target was rewritten")
	}
}

func TestMoveOnboardingReplacesAtomicallyKeepingPermissions(t *testing.T) {
	home, path := moveFixture(t, `{"userID": "target"}`, 0o640)
	before := inode(t, path)
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Lstat(path)
	if info.Mode().Perm() != 0o640 || inode(t, path) == before {
		t.Fatalf("mode %v, same inode %v: not replaced by a new file", info.Mode(), inode(t, path) == before)
	}
	if moveDocument(t, path)["hasCompletedOnboarding"] != true {
		t.Fatal("not merged")
	}
	if leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".relay-account-*")); len(leftovers) != 0 {
		t.Fatalf("temporary files left: %v", leftovers)
	}
}

// moveWithoutExchange makes the file system report no atomic exchange, as NFS does
// (dandy-07's home: renameat2 RENAME_EXCHANGE returns EINVAL).
func moveWithoutExchange(t *testing.T) {
	t.Helper()
	saved := launchStateExchange
	launchStateExchange = func(a, b string) (bool, error) { return false, syscall.EINVAL }
	t.Cleanup(func() { launchStateExchange = saved })
}

func TestMoveOnboardingWithoutExchangeRefusesAndLeavesAnExistingFile(t *testing.T) {
	home, path := moveFixture(t, `{"userID": "target", "projects": {"/work/repos/project": {"hasTrustDialogAccepted": false}}}`, 0o640)
	moveWithoutExchange(t)
	data, _ := os.ReadFile(path)
	before, _ := os.Lstat(path)
	_, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err == nil || !strings.Contains(err.Error(), "personal has not finished Claude setup for this folder") ||
		!strings.Contains(err.Error(), "hasCompletedOnboarding") || !strings.Contains(err.Error(), "hasTrustDialogAccepted") ||
		!strings.Contains(err.Error(), "open Claude once with that account here") {
		t.Fatalf("an unsupported exchange did not refuse with the account and keys: %v", err)
	}
	after, _ := os.Lstat(path)
	now, _ := os.ReadFile(path)
	if !bytes.Equal(data, now) || !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) || after.Mode() != before.Mode() {
		t.Fatal("the existing target file changed")
	}
	if leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".relay-account-*")); len(leftovers) != 0 {
		t.Fatalf("temporary files left: %v", leftovers)
	}
}

func TestMoveOnboardingWithoutExchangeStillMovesToAReadyTargetAndCreatesAMissingFile(t *testing.T) {
	ready := `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.191",
	  "projects": {"/work/repos/project": {"hasTrustDialogAccepted": true, "hasClaudeMdExternalIncludesWarningShown": true}}}`
	home, path := moveFixture(t, ready, 0o600)
	moveWithoutExchange(t)
	if result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil || result.Status != MoveOnboardingReady {
		t.Fatalf("ready target: %+v, %v", result, err)
	}
	if data, _ := os.ReadFile(path); string(data) != ready {
		t.Fatal("a ready target was rewritten")
	}
	// A missing file is created with link(2), which never replaces anything.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil || result.Status != MoveOnboardingUpdated {
		t.Fatalf("missing target: %+v, %v", result, err)
	}
	if info, err := os.Lstat(path); err != nil || info.Mode().Perm() != 0o600 || moveDocument(t, path)["hasCompletedOnboarding"] != true {
		t.Fatalf("missing target not created: %v %v", info, err)
	}
}

func TestMoveOnboardingRefusesWhenTheWrittenFileDoesNotVerify(t *testing.T) {
	home, path := moveFixture(t, `{"userID": "target"}`, 0o600)
	saved := afterMoveOnboardingWrite
	afterMoveOnboardingWrite = func(path string) { writeFile(t, path, `{"userID": "target", "numStartups": 2}`) }
	t.Cleanup(func() { afterMoveOnboardingWrite = saved })
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err == nil || !strings.Contains(err.Error(), "did not verify") {
		t.Fatalf("an unverified target was accepted: %v", err)
	}
	_ = path
}

func TestMoveOnboardingReplacesClaudesDefaultFalse(t *testing.T) {
	// Claude writes hasTrustDialogAccepted: false for every folder it starts
	// in; an earlier resume that stopped at the dialog leaves exactly this.
	home, path := moveFixture(t, `{"hasCompletedOnboarding": false, "autoUpdates": true,
	  "projects": {"/work/repos/project": {"hasTrustDialogAccepted": false, "hasClaudeMdExternalIncludesWarningShown": false,
	    "hasClaudeMdExternalIncludesApproved": false, "history": ["mine"]}}}`, 0o600)
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil {
		t.Fatal(err)
	}
	document := moveDocument(t, path)
	entry := document["projects"].(map[string]any)[movePaneDir].(map[string]any)
	if document["hasCompletedOnboarding"] != true || entry["hasTrustDialogAccepted"] != true ||
		entry["hasClaudeMdExternalIncludesWarningShown"] != true || entry["hasClaudeMdExternalIncludesApproved"] != true {
		t.Fatalf("default false answers were kept: %v", document)
	}
	// A preference the target chose itself is kept.
	if document["autoUpdates"] != true || len(entry["history"].([]any)) != 1 {
		t.Fatalf("the target's own values changed: %v", document)
	}
}

func TestMoveOnboardingAcceptsAndCopiesAParentFolderTrust(t *testing.T) {
	home, path := moveFixture(t, `{"userID": "target"}`, 0o600)
	writeFile(t, filepath.Join(home, ".claude.json"), `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.12",
	  "projects": {"/work/repos": {"hasTrustDialogAccepted": true}, "/work/repos/sibling": {"hasTrustDialogAccepted": true}}}`)
	if _, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir); err != nil {
		t.Fatal(err)
	}
	projects := moveDocument(t, path)["projects"].(map[string]any)
	if got := keysOf(projects); strings.Join(got, ",") != "/work/repos" {
		t.Fatalf("projects %v", got)
	}
}

func TestMoveOnboardingRefusesWithoutAnswersToCopy(t *testing.T) {
	home, path := moveFixture(t, `{"userID": "target"}`, 0o600)
	writeFile(t, filepath.Join(home, ".claude.json"), `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.12", "projects": {}}`)
	before, _ := os.ReadFile(path)
	_, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err == nil || !strings.Contains(err.Error(), "hasTrustDialogAccepted") {
		t.Fatalf("an untrusted folder was accepted: %v", err)
	}
	// What can be copied is not written when the target would still fail.
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Fatalf("a target that cannot pass was changed: %s", after)
	}
}

func TestMoveOnboardingNeedsRegisteredAccountsAndAFolder(t *testing.T) {
	home, _ := moveFixture(t, `{}`, 0o600)
	for _, c := range []struct{ source, target, dir, want string }{
		{"", "~/.claude-unknown", movePaneDir, "target Claude account is not registered"},
		{"~/.claude-unknown", "~/.claude-personal", movePaneDir, "source Claude account is not registered"},
		{"", "", movePaneDir, "same account"},
		{"", "~/.claude-personal", "relative/dir", "absolute"},
		{"", "~/.claude-personal", "/work/../etc", "absolute"},
	} {
		if _, err := PrepareClaudeMove(home, c.source, c.target, c.dir); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%+v: %v", c, err)
		}
	}
}
