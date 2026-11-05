package peernet

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Contract: Claude's documented inbound classification counts interactive
// terminal plan mode as bypassing when bypass permissions are available.
// A flags-only classifier without terminal evidence must keep it unknown,
// rather than assert the prompting class for every plan process.
func TestReviewerPlanWithBypassAvailableIsNotAssertedPrompting(t *testing.T) {
	for _, args := range [][]string{
		{"claude", "--permission-mode", "plan", "--allow-dangerously-skip-permissions"},
		{"claude", "--dangerously-skip-permissions", "--permission-mode", "plan"},
	} {
		if got := launchPermissionClass(t.TempDir(), args); got == "prompting" {
			t.Errorf("%v asserted prompting despite the interactive plan/bypass policy; need observed correct class or unknown", args)
		}
	}
}

// Contract: since Claude 2.1.211 the local settings file in a git repo
// is loaded at the root, even for a session started in a subdirectory.
func TestReviewerSettingsLayersIncludeRepositoryLocalFile(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "init", "--quiet", root)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git fixture: %v %s", err, out)
	}
	local := filepath.Join(root, ".claude", "settings.local.json")
	if err := os.MkdirAll(filepath.Dir(local), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, []byte(`{"crossSessionInbound":"hold"}`), 0600); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(root, "src", "nested")
	if err := os.MkdirAll(sub, 0700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(sub)
	layers, err := claudeSettingsLayers(t.TempDir(), os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	for _, layer := range layers {
		if layer.path == local {
			return
		}
	}
	t.Errorf("root local policy %s is absent for recipient cwd %s; layers=%+v", local, sub, layers)
}
