package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodexRelayProfileIsWrittenForTheTargetAccountWithoutAModel(t *testing.T) {
	home := t.TempDir()
	account := filepath.Join(home, ".codex-personal")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	status, path, err := ensureCodexRelayProfile("~/.codex-personal", home)
	if err != nil || status != "written" || path != filepath.Join(account, "relay-terminal.config.toml") {
		t.Fatalf("first write %q %q %v", status, path, err)
	}
	raw, _ := os.ReadFile(path)
	profile := string(raw)
	if !strings.HasPrefix(profile, relayCodexProfileHeader) || strings.Contains(profile, "\nmodel") ||
		!strings.Contains(profile, `[hooks.state."`+path+`:session_start:0:0"]`) {
		t.Fatalf("profile:\n%s", profile)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	if status, _, err := ensureCodexRelayProfile(account, home); err != nil || status != "current" {
		t.Fatalf("second call %q %v", status, err)
	}
	// A stale Relay-managed profile is reported, never replaced.
	stale := []byte(relayCodexProfileHeader + " old\nmodel = \"x\"\n")
	if err := os.WriteFile(path, stale, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ensureCodexRelayProfile(account, home); err == nil || !strings.Contains(err.Error(), "stale Relay profile") {
		t.Fatalf("stale profile: %v", err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != string(stale) {
		t.Fatal("a stale Relay profile was replaced")
	}
}

func TestCodexRelayProfileNeverChangesAUserProfileOrBadPaths(t *testing.T) {
	home := t.TempDir()
	account := filepath.Join(home, ".codex-personal")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(account, "relay-terminal.config.toml")
	if err := os.WriteFile(path, []byte("model = \"mine\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ensureCodexRelayProfile("~/.codex-personal", home); err == nil {
		t.Fatal("a user profile was replaced")
	}
	if raw, _ := os.ReadFile(path); string(raw) != "model = \"mine\"\n" {
		t.Fatal("user profile changed")
	}
	for _, bad := range []string{"", "relative", "~/../etc", "/a//b", "/a/b/", "~/missing-account", "/a;b"} {
		if _, _, err := ensureCodexRelayProfile(bad, home); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestCodexRelayProfileLeavesAUserAuthoredProfileByteIdentical(t *testing.T) {
	home := t.TempDir()
	account := filepath.Join(home, ".codex-personal")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(account, "relay-terminal.config.toml")
	authored := []byte("# my own profile\nmodel = \"gpt-6.1\"\n[hooks]\n\x00binary\xff tail")
	if err := os.WriteFile(path, authored, 0o640); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(path)
	if _, _, err := ensureCodexRelayProfile(account, home); err == nil || !strings.Contains(err.Error(), "not managed by Relay") {
		t.Fatalf("expected refusal, got %v", err)
	}
	after, _ := os.Stat(path)
	raw, _ := os.ReadFile(path)
	if string(raw) != string(authored) || after.Mode() != before.Mode() || !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("a user-authored profile changed")
	}
	if entries, _ := os.ReadDir(account); len(entries) != 1 {
		t.Fatalf("temporary files left: %d entries", len(entries))
	}
}

func TestCodexRelayProfileUsesEachAccountsOwnTrustKeys(t *testing.T) {
	home := t.TempDir()
	paths := map[string]string{}
	for _, name := range []string{".codex", ".codex-personal"} {
		if err := os.Mkdir(filepath.Join(home, name), 0o700); err != nil {
			t.Fatal(err)
		}
		_, path, err := ensureCodexRelayProfile("~/"+name, home)
		if err != nil {
			t.Fatal(err)
		}
		paths[name] = path
	}
	for name, path := range paths {
		raw, _ := os.ReadFile(path)
		profile := string(raw)
		for other, otherPath := range paths {
			contains := strings.Contains(profile, `[hooks.state."`+otherPath+`:`)
			if contains != (other == name) {
				t.Fatalf("%s profile trust keys for %s: %v\n%s", name, other, contains, profile)
			}
		}
	}
}

// A profile generated earlier by the same codexHookProfile for the same path,
// as on dandy-07's ~/.codex-personal, is current and not rewritten.
func TestCodexRelayProfileGeneratedForThePathIsCurrent(t *testing.T) {
	home := t.TempDir()
	account := filepath.Join(home, ".codex-personal")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(account, "relay-terminal.config.toml")
	if err := os.WriteFile(path, []byte(codexHookProfile(path)), 0o600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(path)
	status, _, err := ensureCodexRelayProfile("~/.codex-personal", home)
	after, _ := os.Stat(path)
	if err != nil || status != "current" || !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) {
		t.Fatalf("status %q err %v", status, err)
	}
}
