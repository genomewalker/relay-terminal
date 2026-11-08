package agentaccounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Pane 57c1 moved to the business account (2026-11-08) and restarted without
// its status line, hooks, plugins or permissions: that account's settings.json
// was its own three-key file, not a link to the main one, because the account
// had never been synced. Every Claude account move now links the shared
// configuration into the target first, keeping any own file as a backup, so a
// moved or restarted agent always starts with the user's configuration.
func TestMoveLinksSharedConfigurationIntoTheTarget(t *testing.T) {
	home, _ := moveFixture(t, moveSourceState, 0o600)
	main, root := filepath.Join(home, ".claude"), filepath.Join(home, ".claude-personal")
	for _, dir := range []string{"plugins", "skills"} {
		if err := os.MkdirAll(filepath.Join(main, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(main, "settings.json"), `{"statusLine":{"type":"command","command":"x"}}`)
	writeFile(t, filepath.Join(main, "CLAUDE.md"), "rules")
	// The target's own settings, created by Claude or another tool.
	writeFile(t, filepath.Join(root, "settings.json"), `{"crossSessionInbound":"accept"}`)
	// A link the user pointed elsewhere is theirs and stays.
	elsewhere := filepath.Join(home, "my-skills")
	if err := os.MkdirAll(elsewhere, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(root, "skills")); err != nil {
		t.Fatal(err)
	}

	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err != nil || result.Status != MoveOnboardingReady {
		t.Fatalf("result %+v, %v", result, err)
	}
	for _, name := range []string{"settings.json", "CLAUDE.md", "plugins"} {
		if target, err := os.Readlink(filepath.Join(root, name)); err != nil || target != filepath.Join(main, name) {
			t.Errorf("%s not linked to the main account: %q %v", name, target, err)
		}
	}
	if target, _ := os.Readlink(filepath.Join(root, "skills")); target != elsewhere {
		t.Errorf("the user's own skills link was replaced: %q", target)
	}
	backups, _ := filepath.Glob(filepath.Join(root, "settings.json.relay-backup-*"))
	if len(backups) != 1 {
		t.Fatalf("own settings not backed up: %v", backups)
	}
	if data, _ := os.ReadFile(backups[0]); !strings.Contains(string(data), "crossSessionInbound") {
		t.Fatalf("backup content changed: %s", data)
	}
	states := map[string]string{}
	for _, link := range result.Links {
		states[link.Name] = link.State
	}
	if states["settings.json"] != LinkBackedUp || states["CLAUDE.md"] != LinkLinked || states["skills"] != LinkForeign || states["agents"] != LinkMissingMain {
		t.Fatalf("link report = %v", states)
	}

	// A second move finds everything linked and changes nothing.
	again, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, link := range again.Links {
		if link.Backup != "" {
			t.Errorf("second move backed up %s again", link.Name)
		}
	}
	if more, _ := filepath.Glob(filepath.Join(root, "*.relay-backup-*")); len(more) != 1 {
		t.Fatalf("second move made more backups: %v", more)
	}
}

// A move into the main account itself has nothing to link.
func TestMoveIntoTheMainAccountLinksNothing(t *testing.T) {
	home, _ := moveFixture(t, moveSourceState, 0o600)
	main := filepath.Join(home, ".claude")
	if err := os.MkdirAll(main, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(main, "settings.json"), `{}`)
	writeFile(t, filepath.Join(main, ".claude.json"), moveSourceState)
	result, err := PrepareClaudeMove(home, "~/.claude-personal", "", movePaneDir)
	if err != nil && !strings.Contains(err.Error(), "first run") {
		t.Fatal(err)
	}
	if len(result.Links) != 0 {
		t.Fatalf("main account got links: %+v", result.Links)
	}
	if info, err := os.Lstat(filepath.Join(main, "settings.json")); err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("main settings changed: %v", err)
	}
}
