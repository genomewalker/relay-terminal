package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

// Only the exact link Relay's opt-in history sync creates is followed; every
// other link, target or file shape stays refused.
func TestSharedHistoryFollowsOnlyTheExactSyncLink(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	main := filepath.Join(home, ".claude", "projects")
	personal := filepath.Join(home, ".claude-personal")
	relative := filepath.Join("p", "11111111-1111-4111-8111-111111111111.jsonl")
	writeTranscript(t, filepath.Join(main, relative), "{}\n")
	other := filepath.Join(home, "elsewhere", "projects")
	writeTranscript(t, filepath.Join(other, relative), "{}\n")
	if err := os.MkdirAll(personal, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(personal, "projects")
	logical := filepath.Join(link, relative)
	relink := func(target string) {
		t.Helper()
		_ = os.Remove(link)
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}

	relink(main)
	if err := validateAccountTranscript(logical, "claude", personal); err != nil {
		t.Fatalf("exact shared-history link refused: %v", err)
	}
	if err := ValidateAccountTranscript(filepath.Join(main, relative), "claude", personal); err != nil {
		t.Fatalf("canonical main path through the exact link refused: %v", err)
	}
	// A link to any other directory, or the right directory named another
	// way, is not the link Relay creates.
	relink(other)
	if validateAccountTranscript(logical, "claude", personal) == nil {
		t.Fatal("a link to another directory was followed")
	}
	if os.Symlink(home, filepath.Join(home, "alias")) != nil {
		t.Fatal("alias")
	}
	relink(filepath.Join(home, "alias", ".claude", "projects"))
	if validateAccountTranscript(logical, "claude", personal) == nil {
		t.Fatal("a differently written link was followed")
	}
	relink("../.claude/projects")
	if validateAccountTranscript(logical, "claude", personal) == nil {
		t.Fatal("a relative link was followed")
	}
	// Below the exact link, the strict walk is unchanged: no further links,
	// no hard links.
	relink(main)
	hardlinked := filepath.Join(main, "p", "22222222-2222-4222-8222-222222222222.jsonl")
	if err := os.Link(filepath.Join(main, relative), hardlinked); err != nil {
		t.Fatal(err)
	}
	if validateAccountTranscript(filepath.Join(link, "p", filepath.Base(hardlinked)), "claude", personal) == nil {
		t.Fatal("a hard-linked transcript was accepted through the shared link")
	}
	nested := filepath.Join(main, "q")
	if err := os.Symlink(filepath.Join(main, "p"), nested); err != nil {
		t.Fatal(err)
	}
	if validateAccountTranscript(filepath.Join(link, "q", filepath.Base(relative)), "claude", personal) == nil {
		t.Fatal("a link below the shared history was followed")
	}
	// The default account never follows a history link.
	if err := os.Remove(filepath.Join(main, "p", filepath.Base(hardlinked))); err != nil {
		t.Fatal(err)
	}
	if sharedHistoryDirectory("claude", filepath.Join(home, ".claude"), "projects") != "" {
		t.Fatal("the default account resolved a shared-history link")
	}
}

// A Claude binding record carries the process's own override: an explicit
// CLAUDE_CONFIG_DIR=~/.claude stays explicit, unset stays unset.
func TestClaudeRecordsCarryTheProcessOverride(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	main := filepath.Join(home, ".claude")
	explicit := startAccountAgent(t, "HOME="+home, "CLAUDE_CONFIG_DIR="+main)
	if override, err := claudeRecordOverride(explicit, main); err != nil || override != main {
		t.Fatalf("explicit ~/.claude recorded as %q (%v)", override, err)
	}
	unset := startAccountAgent(t, "HOME="+home)
	if override, err := claudeRecordOverride(unset, main); err != nil || override != "" {
		t.Fatalf("unset override recorded as %q (%v)", override, err)
	}
	personal := startAccountAgent(t, "HOME="+home, "CLAUDE_CONFIG_DIR="+filepath.Join(home, ".claude-personal"))
	if _, err := claudeRecordOverride(personal, main); err == nil {
		t.Fatal("a registration read from another account directory was accepted")
	}
	if accountOverride("codex", filepath.Join(home, ".codex")) != "" || accountOverride("claude", main) != main {
		t.Fatal("accountOverride folds Claude's explicit default or keeps Codex's")
	}
}
