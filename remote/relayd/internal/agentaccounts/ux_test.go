package agentaccounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func claudeReport(email, orgID, orgName, plan string) []byte {
	data, _ := json.Marshal(map[string]any{"loggedIn": true, "email": email, "orgId": orgID, "orgName": orgName,
		"subscriptionType": plan})
	return data
}

func TestWorkspaceKeyComparesOrganizationsNotEmails(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{".claude", ".claude-a", ".claude-b"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	reports := map[string][]byte{
		"":                               claudeReport("ana@example.org", "org-team", "AEGIS-micro", "team"),
		filepath.Join(home, ".claude-a"): claudeReport("ana@example.org", "org-personal", "ana's Organization", "max"),
		filepath.Join(home, ".claude-b"): claudeReport("bo@example.org", "org-team", "AEGIS-micro", "team"),
	}
	probe := func(ctx context.Context, provider, override string) ([]byte, error) { return reports[override], nil }
	registry := Registry{Version: 1, Accounts: []Account{
		{Provider: "claude", Label: "business"},
		{Provider: "claude", Label: "personal", Dir: "~/.claude-a"},
		{Provider: "claude", Label: "other", Dir: "~/.claude-b"},
	}}
	statuses := List(home, registry, probe)
	business, personal, other := statuses[0], statuses[1], statuses[2]
	if business.Workspace != "AEGIS-micro" || business.Plan != "team" || personal.Workspace != "ana's Organization" {
		t.Fatalf("workspace or plan missing: %+v %+v", business, personal)
	}
	// Same email, different organization: distinct workspaces.
	if business.Email != personal.Email || business.WorkspaceKey == "" || business.WorkspaceKey == personal.WorkspaceKey {
		t.Fatalf("same email in two organizations must be distinct: %q %q", business.WorkspaceKey, personal.WorkspaceKey)
	}
	// Different email, same organization: the same workspace.
	if business.Email == other.Email || business.WorkspaceKey != other.WorkspaceKey {
		t.Fatalf("two emails in one organization must share the workspace: %q %q", business.WorkspaceKey, other.WorkspaceKey)
	}
	if strings.Contains(business.WorkspaceKey, "org-team") {
		t.Fatal("the provider's organization id was forwarded")
	}
	// Codex: the workspace is its account id, reported with usage.
	team := []byte(`{"id":2,"result":{"accountId":"acct-team"}}` + "\n" +
		`{"id":3,"result":{"account":{"type":"chatgpt","email":"ana@example.org","planType":"team"}}}`)
	pro := []byte(`{"id":2,"result":{"accountId":"acct-pro"}}` + "\n" +
		`{"id":3,"result":{"account":{"type":"chatgpt","email":"ana@example.org","planType":"pro"}}}`)
	if a, b := parseCodexIdentity(team), parseCodexIdentity(pro); a.WorkspaceKey == "" || a.WorkspaceKey == b.WorkspaceKey ||
		a.Email != b.Email || a.Plan != "team" || b.Plan != "pro" {
		t.Fatalf("codex workspaces: %+v %+v", a, b)
	}
}

func TestExpectationsAreValidatedEchoedAndKeptAcrossConfigure(t *testing.T) {
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"line\nbreak", strings.Repeat("x", 65), " padded"} {
		if _, err := SetExpectation(home, registry, "claude", "work", bad, "", ""); err == nil {
			t.Fatalf("accepted expectation %q", bad)
		}
	}
	if _, err := SetExpectation(home, registry, "claude", "work", "", "", "NOT-A-KEY"); err == nil {
		t.Fatal("accepted a malformed workspace key")
	}
	registry, err = SetExpectation(home, registry, "claude", "work", "AEGIS-micro", "team", "0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	status := AccountStatus(home, registry.Accounts[0], nil)
	if status.ExpectWorkspace != "AEGIS-micro" || status.ExpectPlan != "team" || status.ExpectKey != "0123456789abcdef" {
		t.Fatalf("expectation not echoed: %+v", status)
	}
	// An older client's configure (no expectations) keeps them.
	incoming := KeepExpectations(registry, DefaultRegistry())
	if incoming.Accounts[0].ExpectWorkspace != "AEGIS-micro" || incoming.Accounts[1].ExpectWorkspace != "" {
		t.Fatalf("expectations not carried over: %+v", incoming.Accounts)
	}
}

func TestRenameKeepsFolderAndRefusesTakenOrInvalidLabels(t *testing.T) {
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Rename(home, registry, "codex", "personal", "work"); err == nil {
		t.Fatal("rename onto a taken label")
	}
	if _, err := Rename(home, registry, "codex", "personal", "Bad Label"); err == nil {
		t.Fatal("rename to an invalid label")
	}
	renamed, err := Rename(home, registry, "codex", "personal", "pro")
	if err != nil {
		t.Fatal(err)
	}
	account, ok := renamed.Find("codex", "pro")
	if !ok || account.Dir != "~/.codex-personal" {
		t.Fatalf("rename changed the folder: %+v", account)
	}
	if loaded, _ := Load(home); !reflect.DeepEqual(loaded, renamed) {
		t.Fatal("rename was not saved")
	}
}

func removeFixture(t *testing.T) (string, Registry, string) {
	t.Helper()
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(home, ".claude-personal")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	original, originalProbe := logoutRunner, removeProbe
	t.Cleanup(func() { logoutRunner, removeProbe = original, originalProbe })
	logoutRunner = func(ctx context.Context, provider, override string) error { return nil }
	removeProbe = func(ctx context.Context, provider, override string) ([]byte, error) {
		return nil, errors.New("no probe in tests")
	}
	return home, registry, root
}

func TestRemoveSignsOutMovesFolderAndNeverFollowsLinks(t *testing.T) {
	home, registry, root := removeFixture(t)
	// Links inside the account point at the main folder and elsewhere.
	target := filepath.Join(home, "precious")
	writeFile(t, filepath.Join(target, "data.txt"), "keep me")
	if err := os.Symlink(target, filepath.Join(root, "linked")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(home, ".claude", "CLAUDE.md"), "main")
	if err := os.Symlink(filepath.Join(home, ".claude", "CLAUDE.md"), filepath.Join(root, "CLAUDE.md")); err != nil {
		t.Fatal(err)
	}
	var signedOut []string
	logoutRunner = func(ctx context.Context, provider, override string) error {
		signedOut = append(signedOut, provider+":"+override)
		return nil
	}
	now := time.Date(2026, 10, 18, 9, 30, 0, 0, time.Local)
	saved, removed, err := Remove(home, registry, "claude", "personal", now)
	if err != nil {
		t.Fatal(err)
	}
	// The provider signs out in the folder set aside under its private name.
	if len(signedOut) != 1 || !strings.HasPrefix(signedOut[0], "claude:"+filepath.Join(home, ".claude-personal.removing-")) {
		t.Fatalf("sign-out did not use the account's set-aside folder: %v", signedOut)
	}
	if _, ok := saved.Find("claude", "personal"); ok {
		t.Fatal("slot still registered")
	}
	retired := filepath.Join(home, ".local", "share", "relay", "retired-accounts-20261018")
	if filepath.Dir(removed.MovedTo) != retired || !strings.HasPrefix(filepath.Base(removed.MovedTo), "claude-personal-093000-") {
		t.Fatalf("moved to %q", removed.MovedTo)
	}
	if info, err := os.Stat(retired); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("retired folder is not owner-only: %v %v", info, err)
	}
	if _, err := os.Lstat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("account folder still in place")
	}
	if info, err := os.Lstat(filepath.Join(removed.MovedTo, "linked")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("a link inside the account did not move as a link")
	}
	if string(mustRead(t, filepath.Join(target, "data.txt"))) != "keep me" ||
		string(mustRead(t, filepath.Join(home, ".claude", "CLAUDE.md"))) != "main" {
		t.Fatal("a link target changed")
	}
}

func TestRemoveRefusals(t *testing.T) {
	t.Run("default folder", func(t *testing.T) {
		home, registry, _ := removeFixture(t)
		if _, _, err := Remove(home, registry, "codex", "work", time.Now()); err == nil {
			t.Fatal("removed the default folder's account")
		}
	})
	t.Run("folder is a link", func(t *testing.T) {
		home, registry, root := removeFixture(t)
		target := filepath.Join(home, "elsewhere")
		writeFile(t, filepath.Join(target, "keep"), "x")
		if err := os.Remove(root); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, root); err != nil {
			t.Fatal(err)
		}
		called := false
		logoutRunner = func(ctx context.Context, provider, override string) error { called = true; return nil }
		if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); err == nil || !strings.Contains(err.Error(), "link") {
			t.Fatalf("removed a linked folder: %v", err)
		}
		if called || string(mustRead(t, filepath.Join(target, "keep"))) != "x" {
			t.Fatal("a refused remove signed out or touched the target")
		}
		if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) {
			t.Fatal("a refused remove changed the registry")
		}
	})
	t.Run("sign-out fails", func(t *testing.T) {
		home, registry, root := removeFixture(t)
		logoutRunner = func(ctx context.Context, provider, override string) error { return errors.New("network down") }
		if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); err == nil || !strings.Contains(err.Error(), "network down") {
			t.Fatalf("remove went on after a failed sign-out: %v", err)
		}
		if _, err := os.Stat(root); err != nil {
			t.Fatal("folder moved after a failed sign-out")
		}
	})
	t.Run("not signed in", func(t *testing.T) {
		home, registry, _ := removeFixture(t)
		logoutRunner = func(ctx context.Context, provider, override string) error { return errors.New("not logged in") }
		removeProbe = func(ctx context.Context, provider, override string) ([]byte, error) {
			return []byte(`{"loggedIn":false}`), nil
		}
		if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); err != nil {
			t.Fatalf("a signed-out account could not be removed: %v", err)
		}
	})
	t.Run("in use", func(t *testing.T) {
		home, registry, root := removeFixture(t)
		original := agentProcessName
		t.Cleanup(func() { agentProcessName = original })
		self := filepath.Base(os.Args[0])
		agentProcessName = func(name string) bool { return strings.HasPrefix(self, name) || strings.HasPrefix(name, self) }
		command := exec.Command(os.Args[0], "-test.run=^TestAccountProcessHelper$")
		command.Env = []string{"RELAY_ACCOUNT_SYNC_HELPER=1", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + root}
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
			if vars, err := agentlaunch.ProcessEnvironment(command.Process.Pid, "RELAY_ACCOUNT_SYNC_HELPER"); err == nil && vars["RELAY_ACCOUNT_SYNC_HELPER"] == "1" {
				break
			}
		}
		called := false
		logoutRunner = func(ctx context.Context, provider, override string) error { called = true; return nil }
		_, _, err := Remove(home, registry, "claude", "personal", time.Now())
		if err == nil || !strings.Contains(err.Error(), "pids "+strconv.Itoa(command.Process.Pid)) {
			t.Fatalf("removed an account in use: %v", err)
		}
		if called {
			t.Fatal("signed out an account in use")
		}
		if _, err := os.Stat(root); err != nil {
			t.Fatal("moved an account in use")
		}
	})
}

func TestModelDefaultsValidateWriteAndRemove(t *testing.T) {
	root := t.TempDir()
	for _, bad := range [][3]string{{"claude", "", "minimal"}, {"codex", "", "max"}, {"codex", "bad model", ""}, {"codex", "-x", ""}} {
		if err := WriteModelDefaults(bad[0], root, bad[1], bad[2]); err == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
	if err := WriteModelDefaults("codex", root, "gpt-rosalind-5.5", "xhigh"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(root, modelDefaultsName))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("defaults file not private: %v %v", info, err)
	}
	if defaults, err := ReadModelDefaults("codex", root); err != nil || defaults.Model != "gpt-rosalind-5.5" || defaults.Effort != "xhigh" {
		t.Fatalf("read back %+v %v", defaults, err)
	}
	// The launch policy file is separate and stays absent.
	if _, err := os.Lstat(filepath.Join(root, "relay-launch-defaults.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("model defaults wrote the launch policy file")
	}
	if err := WriteModelDefaults("codex", root, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, modelDefaultsName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("empty defaults did not remove the file")
	}
	// A link in the file's place is never written through.
	elsewhere := filepath.Join(t.TempDir(), "target")
	if err := os.Symlink(elsewhere, filepath.Join(root, modelDefaultsName)); err != nil {
		t.Fatal(err)
	}
	if err := WriteModelDefaults("codex", root, "gpt-5", ""); err == nil {
		t.Fatal("wrote through a link")
	}
	if _, err := ReadModelDefaults("codex", root); err == nil {
		t.Fatal("read through a link")
	}
}

func TestLaunchDefaultsApplyOnlyToNewConversations(t *testing.T) {
	defaults := ModelDefaults{Version: 1, Model: "opus", Effort: "xhigh"}
	cases := []struct{ in, want []string }{
		{nil, []string{"--model", "opus", "--effort", "xhigh"}},
		{[]string{"fix the bug"}, []string{"--model", "opus", "--effort", "xhigh", "fix the bug"}},
		{[]string{"--model", "sonnet"}, []string{"--effort", "xhigh", "--model", "sonnet"}},
		{[]string{"--effort=low"}, []string{"--model", "opus", "--effort=low"}},
		{[]string{"--continue"}, []string{"--continue"}},
		{[]string{"-r", "abc"}, []string{"-r", "abc"}},
		{[]string{"auth", "status"}, []string{"auth", "status"}},
		{[]string{"--version"}, []string{"--version"}},
	}
	for _, c := range cases {
		if got := WithClaudeDefaults(defaults, c.in); !reflect.DeepEqual(got, c.want) && !(len(got) == 0 && len(c.want) == 0) {
			t.Errorf("claude %v: got %v want %v", c.in, got, c.want)
		}
	}
	codex := ModelDefaults{Version: 1, Model: "gpt-rosalind-5.5", Effort: "xhigh"}
	prefix := []string{"-c", `model="gpt-rosalind-5.5"`, "-c", `model_reasoning_effort="xhigh"`}
	codexCases := []struct{ in, want []string }{
		{nil, prefix},
		{[]string{"exec", "do it"}, append(append([]string{}, prefix...), "exec", "do it")},
		{[]string{"-m", "gpt-5"}, []string{"-c", `model_reasoning_effort="xhigh"`, "-m", "gpt-5"}},
		{[]string{"-c", "model_reasoning_effort=low"}, []string{"-c", `model="gpt-rosalind-5.5"`, "-c", "model_reasoning_effort=low"}},
		{[]string{"resume", "--last"}, []string{"resume", "--last"}},
		{[]string{"exec", "resume", "--last"}, []string{"exec", "resume", "--last"}},
		{[]string{"login", "--device-auth"}, []string{"login", "--device-auth"}},
		{[]string{"-p", "login", "hello"}, append(append([]string{}, prefix...), "-p", "login", "hello")},
		{[]string{"app-server"}, []string{"app-server"}},
	}
	for _, c := range codexCases {
		if got := WithCodexDefaults(codex, c.in); !reflect.DeepEqual(got, c.want) && !(len(got) == 0 && len(c.want) == 0) {
			t.Errorf("codex %v: got %v want %v", c.in, got, c.want)
		}
	}
	if got := WithCodexDefaults(ModelDefaults{}, []string{"exec"}); !reflect.DeepEqual(got, []string{"exec"}) {
		t.Errorf("no defaults changed the launch: %v", got)
	}
}

// A provider whose child keeps stdout open past the time limit must not
// hang the check: the whole process group ends and the read stops. The
// timeout reason does no file system work.
func TestProbesEndAtTheirLimitEvenWhenAChildHoldsOutput(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "codex")
	writeFile(t, script, "#!/bin/sh\nsleep 30 &\nexec sleep 30\n")
	if err := os.Chmod(script, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CODEX_BIN", script)
	root := filepath.Join(directory, "account")
	for name, run := range map[string]func(context.Context) error{
		"usage": func(ctx context.Context) error { _, err := ProviderUsage(ctx, "codex", root); return err },
		"probe": func(ctx context.Context) error { _, err := ProviderProbe(ctx, "codex", root); return err },
	} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		started := time.Now()
		err := run(ctx)
		cancel()
		if elapsed := time.Since(started); elapsed > 5*time.Second {
			t.Fatalf("%s took %v", name, elapsed)
		}
		if err == nil || !strings.Contains(err.Error(), "codex did not answer in 1 s") ||
			!strings.Contains(err.Error(), "tmp/arg0 folder") {
			t.Fatalf("%s reason: %v", name, err)
		}
	}
}

// A leader that exits while its child keeps output open must not leave the
// child running, on the usage and sign-out paths as on the probe path.
func TestEveryProviderCommandEndsItsProcessGroup(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		for _, path := range []string{"usage", "logout"} {
			directory := t.TempDir()
			pidFile := filepath.Join(directory, "child-pid")
			script := filepath.Join(directory, provider)
			writeFile(t, script, "#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > '"+pidFile+"'\nexit 0\n")
			if err := os.Chmod(script, 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("RELAY_"+strings.ToUpper(provider)+"_BIN", script)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			if path == "usage" {
				_, _ = ProviderUsage(ctx, provider, filepath.Join(directory, "account"))
			} else {
				_ = ProviderLogout(ctx, provider, filepath.Join(directory, "account"))
			}
			cancel()
			data, err := os.ReadFile(pidFile)
			if err != nil {
				t.Fatal(err)
			}
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil {
				t.Fatal(err)
			}
			if syscall.Kill(pid, 0) == nil {
				state, _ := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
				if s := strings.TrimSpace(string(state)); s != "" && !strings.HasPrefix(s, "Z") {
					_ = syscall.Kill(pid, syscall.SIGKILL)
					t.Errorf("%s %s left its child %d running (%s)", provider, path, pid, s)
				}
			}
		}
	}
}

// Failure reasons are fixed texts: nothing a provider prints is forwarded.
func TestFailureReasonsAreFixedTexts(t *testing.T) {
	directory := t.TempDir()
	sentinel := "eyJhbGciOiJub25lIn0.eyJzdWIiOiJmaXh0dXJlIn0.SYNTHETIC"
	printed := "error: unable to reach the service\nsk-ant-synthetic-value\n" + sentinel
	for _, provider := range []string{"claude", "codex"} {
		script := filepath.Join(directory, provider)
		writeFile(t, script, "#!/bin/sh\nprintf '%s\\n' '"+strings.ReplaceAll(printed, "\n", "' '")+"' >&2\nprintf '%s\\n' '"+sentinel+"'\nexit 3\n")
		if err := os.Chmod(script, 0o700); err != nil {
			t.Fatal(err)
		}
		t.Setenv("RELAY_"+strings.ToUpper(provider)+"_BIN", script)
	}
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude-x"), 0o700); err != nil {
		t.Fatal(err)
	}
	account := Account{Provider: "claude", Label: "x", Dir: "~/.claude-x"}
	status := AccountStatus(home, account, ProviderProbe)
	if status.Probe != "failed" || status.ProbeReason != "the provider's status answer was not recognized" {
		t.Fatalf("status %+v", status)
	}
	usage := ReadUsage(home, []Account{account}, ProviderUsage, time.Now())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	logout := ProviderLogout(ctx, "codex", filepath.Join(home, ".codex-x"))
	if logout == nil || logout.Error() != "codex exited with status 3" {
		t.Fatalf("logout reason %v", logout)
	}
	for _, reason := range []string{status.ProbeReason, usage[0].Reason, logout.Error()} {
		for _, leaked := range []string{"unable to reach", "sk-ant", "eyJ", "SYNTHETIC"} {
			if strings.Contains(reason, leaked) {
				t.Errorf("a reason forwarded provider text %q: %q", leaked, reason)
			}
		}
	}
	for _, text := range []string{"Bearer abc.def", "key sk-abcdefgh12345", sentinel,
		"blob " + strings.Repeat("Ab3+", 12)} {
		if got := withheld(text); strings.Contains(got, "abc") || strings.Contains(got, "sk-") || strings.Contains(got, "eyJ") || strings.Contains(got, "Ab3") {
			t.Errorf("backstop kept %q as %q", text, got)
		}
	}
	for _, kept := range []string{"claude exited with status 3",
		"rename /home/ana/.claude-personal-account-label /home/ana/.local/share/relay/retired-accounts-20261018/claude-personal-account-label-093000-a1b2c3: invalid"} {
		if got := withheld(kept); got != printable(kept, 160) {
			t.Errorf("backstop changed a plain reason: %q", got)
		}
	}
}

// Removal is refused before any sign-out, move or registry change unless it
// comes from the user; the native Settings origin removes.
func TestRemoveNeedsTheUsersOriginBeforeAnyChange(t *testing.T) {
	for _, origin := range []string{"", "mcp", "assistant", "maintenance", "USER", "user ", "native"} {
		home, registry, root := removeFixture(t)
		t.Setenv("HOME", home)
		called := false
		logoutRunner = func(ctx context.Context, provider, override string) error { called = true; return nil }
		if _, err := Handle(Request{Action: "remove", Provider: "claude", Label: "personal", Origin: origin}, nil); err == nil {
			t.Fatalf("origin %q removed an account", origin)
		}
		if called {
			t.Fatalf("origin %q signed the account out", origin)
		}
		if _, err := os.Lstat(root); err != nil {
			t.Fatalf("origin %q moved the folder", origin)
		}
		if retired, _ := filepath.Glob(filepath.Join(home, ".local", "share", "relay", "retired-accounts-*")); len(retired) > 0 {
			t.Fatalf("origin %q created a retired folder", origin)
		}
		if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) {
			t.Fatalf("origin %q changed the registry", origin)
		}
	}
	home, _, root := removeFixture(t)
	t.Setenv("HOME", home)
	response, err := Handle(Request{Action: "remove", Provider: "claude", Label: "personal", Origin: "user"}, nil)
	if err != nil || response.Removed == nil || response.Removed.MovedTo == "" {
		t.Fatalf("the user's removal failed: %v", err)
	}
	if _, err := os.Lstat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the user's removal kept the folder")
	}
}
