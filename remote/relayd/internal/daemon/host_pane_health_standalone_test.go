package daemon

import (
	"path/filepath"
	"testing"
)

func TestStandaloneCodexReleaseStore(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	store := filepath.Join(home, ".codex/packages/standalone/releases")
	old := filepath.Join(store, "0.164.0-aarch64-apple-darwin/bin/codex")
	current := filepath.Join(store, "0.166.0-aarch64-apple-darwin/bin/codex")
	for _, p := range []string{old, current} {
		if got := phInstallRoot(p, "codex"); got != store {
			t.Fatalf("install root %q, want %q", got, store)
		}
	}
	if phCompareVersions(phPathVersion(old, "codex"), phVersionOf([]string{"0", "164", "0"})) != 0 {
		t.Fatal("running release version not identified")
	}
	if phCompareVersions(phPathVersion(current, "codex"), phVersionOf([]string{"0", "166", "0"})) != 0 {
		t.Fatal("installed release version not identified")
	}
	for _, p := range []string{
		filepath.Join(home, "other/releases/0.166.0-aarch64-apple-darwin/bin/codex"),
		filepath.Join(store, "bad-version/bin/codex"),
		filepath.Join(store, "0.166.0/bin/codex"),
		filepath.Join(store, "0.166.0-aarch64-apple-darwin/bin/not-codex"),
		filepath.Join(store, "0.166.0-aarch64-apple-darwin/codex"),
		".codex/packages/standalone/releases/0.166.0-aarch64-apple-darwin/bin/codex",
	} {
		if root, v := phStandaloneCodexRelease(p, "codex"); root != "" || v != nil {
			t.Fatalf("accepted unrelated layout %q", p)
		}
	}
	if root, v := phStandaloneCodexRelease(old, "claude"); root != "" || v != nil {
		t.Fatal("Codex layout accepted for Claude")
	}
}
