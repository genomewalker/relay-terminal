package peernet

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLaunchPermissionClassRecognisesNativeClaudeAndCodexBypass(t *testing.T) {
	home := t.TempDir()
	versions := filepath.Join(home, ".local", "share", "claude", "versions")
	if err := os.MkdirAll(versions, 0o700); err != nil {
		t.Fatal(err)
	}
	native := filepath.Join(versions, "2.1.295")
	elsewhere := filepath.Join(home, "2.1.295")
	for _, path := range []string{native, elsewhere} {
		if err := os.WriteFile(path, nil, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"claude", "--dangerously-skip-permissions"}, "bypass"},
		{[]string{native, "--session-id", "x", "--dangerously-skip-permissions"}, "bypass"},
		{[]string{native, "--session-id", "x"}, ""},
		{[]string{"/opt/bin/codex", "--dangerously-bypass-approvals-and-sandbox"}, "bypass"},
		// A flag belongs to its own harness; the other harness's flag asserts nothing.
		{[]string{"codex", "--dangerously-skip-permissions"}, ""},
		{[]string{"claude", "--dangerously-bypass-approvals-and-sandbox"}, ""},
		// A same-named file outside the installer, or a missing version, is not Claude.
		{[]string{elsewhere, "--dangerously-skip-permissions"}, ""},
		{[]string{filepath.Join(versions, "9.9.9"), "--dangerously-skip-permissions"}, ""},
		{[]string{"bash", "--dangerously-skip-permissions"}, ""},
		{nil, ""},
	} {
		if got := launchPermissionClass(home, tc.args); got != tc.want {
			t.Errorf("launchPermissionClass(%q) = %q, want %q", tc.args, got, tc.want)
		}
	}
}

// A recorded runtime mode, including one Relay does not classify such as
// Claude's "auto" or plan (bypass-class when bypass is available), supersedes the launch flags and is never upgraded to bypass.
func TestRuntimePermissionModeSupersedesLaunchFlags(t *testing.T) {
	start, err := processStart(os.Getpid())
	if err != nil {
		t.Skip("process start unavailable:", err)
	}
	for mode, want := range map[string]string{"auto": "", "bypassPermissions": "bypass", "default": "prompting",
		"acceptEdits": "prompting", "plan": "", "dontAsk": ""} {
		home := t.TempDir()
		session := "fixture-" + mode
		dir := filepath.Join(home, ".claude", "projects", "fixture")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		row := `{"type":"permission-mode","permissionMode":"` + mode + `","sessionId":"` + session + `"}` + "\n"
		if err := os.WriteFile(filepath.Join(dir, session+".jsonl"), []byte(row), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := runtimePermissionClass(home, Record{PID: os.Getpid(), Start: start, Session: session}); got != want {
			t.Errorf("%s: got %q, want %q", mode, got, want)
		}
	}
}
