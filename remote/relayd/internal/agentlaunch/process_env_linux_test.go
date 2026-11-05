//go:build linux

package agentlaunch

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func liveAccountSnapshot(t *testing.T, configDir string) Snapshot {
	t.Helper()
	cwd, _ := os.Getwd()
	executable, err := filepath.Abs(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	pid := startAccountEnvironmentChild(t, "HOME="+t.TempDir(), "RELAY_SESSION=account-pane", "CLAUDE_CONFIG_DIR="+configDir)
	start, err := startFor(pid)
	if err != nil {
		t.Fatal(err)
	}
	return Snapshot{Client: "claude", PID: pid, ProcessStart: start, Executable: executable, CWD: cwd,
		RelayPaneID: "account-pane", EffectiveArgs: []string{"-test.run=^TestAccountEnvironmentHelperProcess$"}}
}

func TestLaunchConfigDirectoryReportsALiveMismatch(t *testing.T) {
	personal := filepath.Join(t.TempDir(), ".claude-personal")
	snapshot := liveAccountSnapshot(t, personal)
	if err := VerifyProcess(snapshot); err != nil {
		t.Fatalf("helper snapshot does not verify: %v", err)
	}
	snapshot.ConfigDir, snapshot.ConfigDirRecorded = personal, true
	if override, known, err := LaunchConfigDirectory(snapshot); err != nil || !known || override != personal {
		t.Fatalf("live account = %q %v %v", override, known, err)
	}
	snapshot.ConfigDir = ""
	if _, _, err := LaunchConfigDirectory(snapshot); !errors.Is(err, ErrConfigDirMismatch) {
		t.Fatalf("a changed account must be reported, got %v", err)
	}
}

func TestLaunchConfigDirectoryReportsClaudesExplicitDefault(t *testing.T) {
	home := t.TempDir()
	main := filepath.Join(home, ".claude")
	if err := os.MkdirAll(main, 0o700); err != nil {
		t.Fatal(err)
	}
	cwd, _ := os.Getwd()
	executable, _ := filepath.Abs(os.Args[0])
	pid := startAccountEnvironmentChild(t, "HOME="+home, "RELAY_SESSION=account-pane", "CLAUDE_CONFIG_DIR="+main)
	start, err := startFor(pid)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := Snapshot{Client: "claude", PID: pid, ProcessStart: start, Executable: executable, CWD: cwd,
		RelayPaneID: "account-pane", EffectiveArgs: []string{"-test.run=^TestAccountEnvironmentHelperProcess$"},
		ConfigDirRecorded: true}
	// Recorded default, live explicit ~/.claude: the same directory but a
	// different .claude.json, so a mismatch with that reason.
	if _, _, err := LaunchConfigDirectory(snapshot); !errors.Is(err, ErrClaudeExplicitDefault) {
		t.Fatalf("explicit ~/.claude against the default = %v", err)
	}
	// A symlinked alias of the recorded explicit directory is the same account.
	alias := filepath.Join(home, "alias")
	if err := os.Symlink(main, alias); err != nil {
		t.Fatal(err)
	}
	snapshot.ConfigDir = alias
	if override, known, err := LaunchConfigDirectory(snapshot); err != nil || !known || override != main {
		t.Fatalf("alias = %q %v %v", override, known, err)
	}
	snapshot.ConfigDir = filepath.Join(home, ".claude-personal")
	if _, _, err := LaunchConfigDirectory(snapshot); !errors.Is(err, ErrConfigDirMismatch) ||
		errors.Is(err, ErrClaudeExplicitDefault) {
		t.Fatalf("recorded personal vs live ~/.claude must be a plain mismatch, got %v", err)
	}
}

func TestClaudeSourceDirectoriesFollowThePersonalAccount(t *testing.T) {
	personal := filepath.Join(t.TempDir(), ".claude-personal")
	snapshot := liveAccountSnapshot(t, personal)
	_, config, err := claudeSourceDirectories(snapshot)
	if err != nil || config != personal {
		t.Fatalf("Claude source config = %q %v", config, err)
	}
}
