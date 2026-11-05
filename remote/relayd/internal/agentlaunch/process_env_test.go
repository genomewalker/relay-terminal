package agentlaunch

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A helper child with an exact environment. Only this test's own child is
// ever stopped, by its exact PID.
func TestAccountEnvironmentHelperProcess(t *testing.T) {
	if os.Getenv("RELAY_ACCOUNT_ENV_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(60 * time.Second)
}

func startAccountEnvironmentChild(t *testing.T, environment ...string) int {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestAccountEnvironmentHelperProcess$")
	command.Env = append([]string{"RELAY_ACCOUNT_ENV_HELPER=1"}, environment...)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	pid := command.Process.Pid
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if vars, err := ProcessEnvironment(pid, "RELAY_ACCOUNT_ENV_HELPER"); err == nil && vars["RELAY_ACCOUNT_ENV_HELPER"] == "1" {
			return pid
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("helper environment never became readable")
	return 0
}

func TestProcessConfigDirectoryReadsTheAgentsOwnAccount(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	pid := startAccountEnvironmentChild(t, "HOME="+home, "CLAUDE_CONFIG_DIR="+personal, "OTHER_SECRET=never-read")
	root, override, err := ProcessConfigDirectory(pid, "claude")
	if err != nil || root != personal || override != personal {
		t.Fatalf("personal Claude account = %q %q %v", root, override, err)
	}
	vars, err := ProcessEnvironment(pid, "HOME", "CLAUDE_CONFIG_DIR")
	if err != nil || len(vars) != 2 || vars["OTHER_SECRET"] != "" {
		t.Fatalf("only the requested variables may be returned: %v %v", vars, err)
	}
	codexHome := filepath.Join(home, ".codex-personal")
	codex := startAccountEnvironmentChild(t, "HOME="+home, "CODEX_HOME="+codexHome)
	if root, override, err := ProcessConfigDirectory(codex, "codex"); err != nil || root != codexHome || override != codexHome {
		t.Fatalf("personal Codex account = %q %q %v", root, override, err)
	}
	fallback := startAccountEnvironmentChild(t, "HOME="+home)
	if root, override, err := ProcessConfigDirectory(fallback, "claude"); err != nil || root != filepath.Join(home, ".claude") || override != "" {
		t.Fatalf("default Claude account = %q %q %v", root, override, err)
	}
}

func TestAccountEnvironmentFailsClosed(t *testing.T) {
	if _, err := selectEnvironment([]byte("HOME=/a\x00CODEX_HOME=/b\x00CODEX_HOME=/c\x00"), []string{"CODEX_HOME"}); err == nil {
		t.Fatal("duplicate account variable accepted")
	}
	vars, err := selectEnvironment([]byte("HOME=/a\x00TOKEN=x\x00"), []string{"HOME"})
	if err != nil || len(vars) != 1 || vars["HOME"] != "/a" {
		t.Fatalf("unexpected selection %v %v", vars, err)
	}
	for _, vars := range []map[string]string{
		{"HOME": "/home/u", "CLAUDE_CONFIG_DIR": "relative"},
		{"HOME": "/home/u", "CLAUDE_CONFIG_DIR": "/home/u/../x"},
		{"HOME": ""},
	} {
		if _, err := ProviderConfigRoot("claude", vars); err == nil {
			t.Fatalf("invalid account directory accepted: %v", vars)
		}
	}
	if _, err := ProviderConfigRoot("shell", map[string]string{"HOME": "/home/u"}); err == nil {
		t.Fatal("unknown provider accepted")
	}
}

func TestLaunchSnapshotRecordsTheAccountDirectory(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "launches")
	personal := filepath.Join(t.TempDir(), ".claude-personal")
	t.Setenv("CLAUDE_CONFIG_DIR", personal)
	path, err := Save(directory, "claude", "/bin/claude", "/", "pane", "", []string{"--resume", "x"}, []string{"--resume", "x"})
	if err != nil {
		t.Fatal(err)
	}
	snapshot := readSnapshotForTest(t, path)
	if !snapshot.ConfigDirRecorded || snapshot.ConfigDir != personal {
		t.Fatalf("account not recorded: %+v", snapshot)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	path, err = Save(directory, "claude", "/bin/claude", "/", "pane", "", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot := readSnapshotForTest(t, path); !snapshot.ConfigDirRecorded || snapshot.ConfigDir != "" {
		t.Fatalf("default account not recorded as default: %+v", snapshot)
	}
}

func TestLaunchConfigDirectoryUsesTheRecordForAnExitedSource(t *testing.T) {
	exited := Snapshot{Client: "claude", PID: 1 << 30, ProcessStart: "1"}
	if _, known, err := LaunchConfigDirectory(exited); err != nil || known {
		t.Fatalf("a legacy snapshot must leave the environment alone: %v %v", known, err)
	}
	exited.ConfigDir, exited.ConfigDirRecorded = "/home/u/.claude-personal", true
	if override, known, err := LaunchConfigDirectory(exited); err != nil || !known || override != exited.ConfigDir {
		t.Fatalf("recorded account not kept: %q %v %v", override, known, err)
	}
	exited.ConfigDir = ""
	if override, known, err := LaunchConfigDirectory(exited); err != nil || !known || override != "" {
		t.Fatalf("recorded default account not kept: %q %v %v", override, known, err)
	}
}

func readSnapshotForTest(t *testing.T, path string) Snapshot {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot Snapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func TestSameConfigDirectoryComparesResolvedRealPaths(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{".claude", ".claude-personal", ".codex"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	personal := filepath.Join(home, ".claude-personal")
	alias := filepath.Join(home, "personal-alias")
	if err := os.Symlink(personal, alias); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct {
		provider, a, b string
		same           bool
	}{
		{"claude", "", filepath.Join(home, ".claude"), false},
		{"codex", "", filepath.Join(home, ".codex"), true},
		{"claude", personal, alias, true},
		{"claude", personal, "", false},
		{"claude", "", "", true},
		{"claude", "relative", "relative", false},
	} {
		if got := SameConfigDirectory(check.provider, home, check.a, check.b); got != check.same {
			t.Fatalf("SameConfigDirectory(%s, %q, %q) = %v", check.provider, check.a, check.b, got)
		}
	}
	// Claude's explicit ~/.claude differs from its default only by the
	// .claude.json it uses, and says so.
	err := ConfigDirectoryMismatch("claude", home, filepath.Join(home, ".claude"), "")
	if !errors.Is(err, ErrClaudeExplicitDefault) || !errors.Is(err, ErrConfigDirMismatch) ||
		!strings.Contains(err.Error(), "explicit ~/.claude uses a different .claude.json") {
		t.Fatalf("Claude explicit default = %v", err)
	}
	if err := ConfigDirectoryMismatch("codex", home, filepath.Join(home, ".codex"), ""); err != nil {
		t.Fatalf("Codex explicit default = %v", err)
	}
}
