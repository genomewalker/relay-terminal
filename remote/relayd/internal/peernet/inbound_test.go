package peernet

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudeLaunchPermissionModeFlags(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"claude", "--permission-mode", "bypassPermissions"}, "bypass"},
		{[]string{"claude", "--permission-mode=bypassPermissions"}, "bypass"},
		{[]string{"claude", "--permission-mode", "default"}, "prompting"},
		{[]string{"claude", "--permission-mode=acceptEdits"}, "prompting"},
		// Plan is bypass-class for an interactive session with bypass available,
		// which settings can also grant: never asserted from process evidence.
		{[]string{"claude", "--permission-mode", "plan"}, ""},
		{[]string{"claude", "--permission-mode", "plan", "--allow-dangerously-skip-permissions"}, ""},
		{[]string{"claude", "--dangerously-skip-permissions", "--permission-mode", "plan"}, ""},
		{[]string{"claude", "-p", "--permission-mode", "plan"}, ""},
		// Claude applies these in order; the last one wins.
		{[]string{"claude", "--dangerously-skip-permissions", "--permission-mode", "default"}, "prompting"},
		{[]string{"claude", "--permission-mode", "default", "--dangerously-skip-permissions"}, "bypass"},
		// An inherited mode applies only without an explicit one.
		{[]string{"claude", "--inherit-permission-mode", "bypassPermissions"}, "bypass"},
		{[]string{"claude", "--inherit-permission-mode", "bypassPermissions", "--permission-mode", "default"}, "prompting"},
		// Unknown or incomplete modes, allow-only flags and prompt text assert nothing.
		{[]string{"claude", "--permission-mode", "dontAsk"}, ""},
		{[]string{"claude", "--permission-mode"}, ""},
		{[]string{"claude", "--allow-dangerously-skip-permissions"}, ""},
		{[]string{"claude", "--", "--dangerously-skip-permissions"}, ""},
		{[]string{"codex", "--permission-mode", "bypassPermissions"}, ""},
	} {
		if got := launchPermissionClass(t.TempDir(), tc.args); got != tc.want {
			t.Errorf("launchPermissionClass(%q) = %q, want %q", tc.args, got, tc.want)
		}
	}
}

func TestCrossSessionInboundSettingMakesThePredictionUnknown(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	for _, tc := range []struct {
		layer settingsLayer
		set   bool
		fails bool
	}{
		{settingsLayer{path: filepath.Join(dir, "missing.json")}, false, false},
		{settingsLayer{path: write("plain.json", `{"permissions":{"defaultMode":"bypassPermissions"},"env":{"TOKEN":"never-read"}}`)}, false, false},
		{settingsLayer{path: write("accept.json", `{"crossSessionInbound":"accept"}`)}, true, false},
		{settingsLayer{path: write("hold.json", `{"crossSessionInbound":"hold"}`)}, true, false},
		{settingsLayer{path: write("broken.json", `{"crossSessionInbound":`)}, false, true},
		{settingsLayer{path: dir}, false, true},
		{settingsLayer{inline: []byte(`{"crossSessionInbound":"refuse"}`)}, true, false},
	} {
		set, err := setsCrossSessionInbound(tc.layer)
		if set != tc.set || (err != nil) != tc.fails {
			t.Errorf("%+v: set=%v err=%v", tc.layer, set, err)
		}
	}
	layers, err := settingsArgumentLayers([]string{"claude", "--settings", "relative.json", "--settings={\"a\":1}",
		"--settings", "/abs/hooks.json"}, "/work")
	if err != nil || len(layers) != 3 || layers[0].path != "/work/relative.json" || string(layers[1].inline) != `{"a":1}` ||
		layers[2].path != "/abs/hooks.json" {
		t.Fatalf("settings arguments: %+v %v", layers, err)
	}
	if _, err := settingsArgumentLayers([]string{"claude", "--settings"}, "/work"); err == nil {
		t.Fatal("incomplete --settings accepted")
	}
}

func TestRecipientInboundClassIsUnknownForAnUnclassifiedProcess(t *testing.T) {
	if class, reason := RecipientInboundClass(t.TempDir(), os.Getpid(), "00000000-0000-4000-8000-000000000000"); class != "" || reason != "class_unknown" {
		t.Fatal(class, reason)
	}
}

func gitFixture(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture",
		"-c", "commit.gpgsign=false"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("git fixture unavailable: %v %s", err, out)
	}
}

// Claude keeps the local file at the repository root, and a linked worktree's
// at the main checkout's root; the starting directory's file still counts.
func TestProjectSettingsCoverRepositoryRootAndMainCheckout(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	main := filepath.Join(root, "main")
	if err := os.MkdirAll(filepath.Join(main, "src", "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	gitFixture(t, main, "init", "--quiet")
	gitFixture(t, main, "commit", "--quiet", "--allow-empty", "-m", "fixture")
	worktree := filepath.Join(root, "linked")
	gitFixture(t, main, "worktree", "add", "--quiet", worktree)
	if err := os.MkdirAll(filepath.Join(worktree, "src", "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		cwd  string
		want []string
	}{
		{filepath.Join(main, "src", "nested"), []string{filepath.Join(main, "src", "nested"), filepath.Join(main, "src"), main}},
		{main, []string{main}},
		{filepath.Join(worktree, "src", "nested"), []string{filepath.Join(worktree, "src", "nested"), filepath.Join(worktree, "src"), worktree, main}},
		{root, []string{root}},
	} {
		got, err := claudeProjectDirectories(tc.cwd)
		if err != nil || strings.Join(got, "|") != strings.Join(tc.want, "|") {
			t.Errorf("%s: %v (%v), want %v", tc.cwd, got, err, tc.want)
		}
	}
	// A root-local policy in the main checkout makes a worktree recipient unknown.
	if err := os.MkdirAll(filepath.Join(main, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(main, ".claude", "settings.local.json"), []byte(`{"crossSessionInbound":"accept"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(filepath.Join(worktree, "src", "nested"))
	layers, err := claudeSettingsLayers(t.TempDir(), os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, layer := range layers {
		if layer.path == filepath.Join(main, ".claude", "settings.local.json") {
			set, err := setsCrossSessionInbound(layer)
			found = set && err == nil
		}
	}
	if !found {
		t.Fatalf("main checkout local policy missing for a worktree recipient: %+v", layers)
	}
}

func TestUnresolvableGitMetadataIsUnknown(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"bad pointer": "not a pointer", "missing gitdir": "gitdir: does/not/exist",
		"empty": "gitdir: "} {
		if err := os.WriteFile(filepath.Join(dir, ".git"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := claudeProjectDirectories(dir); err == nil {
			t.Errorf("%s: unresolved git metadata accepted", name)
		}
	}
	if _, err := claudeProjectDirectories("relative/path"); err == nil {
		t.Error("relative working directory accepted")
	}
}
