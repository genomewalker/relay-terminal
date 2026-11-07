package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// spawnPlatformSleeper starts an Apple platform binary. The kernel withholds its
// environment, so its account can never be read.
func spawnPlatformSleeper(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("/bin/sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	return cmd.Process.Pid
}

// spawnGonePID returns a PID whose process has ended and been reaped.
func spawnGonePID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

// The Claude account of one exact process: its own CLAUDE_CONFIG_DIR, or the
// default only when unset. Every other case is refused, never defaulted.
func TestNativeClaudeAccountRootFollowsExactProcess(t *testing.T) {
	home := claudeTestConfig(t)
	t.Setenv("HOME", home)
	acct := claudeTestConfig(t)
	cases := []struct {
		name string
		env  []string
		want string // "" means refused
	}{
		{"own account", []string{"CLAUDE_CONFIG_DIR=" + acct}, acct},
		{"unset selects default", []string{"PATH=/usr/bin:/bin"}, filepath.Join(home, ".claude")},
		{"set but empty refused", []string{"CLAUDE_CONFIG_DIR="}, ""},
		{"relative refused", []string{"CLAUDE_CONFIG_DIR=rel/acct"}, ""},
		{"unclean refused", []string{"CLAUDE_CONFIG_DIR=" + acct + "/."}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pid, _ := spawnAccountOwner(t, c.env)
			got, err := nativeClaudeAccountRoot(pid)
			if c.want == "" {
				if err == nil {
					t.Fatalf("resolved %q for a refused process", got)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("account = %q, %v; want %q", got, err, c.want)
			}
		})
	}
	// A default-account registration does not make an unreadable environment resolvable.
	sleeper := spawnPlatformSleeper(t)
	writeClaudeRegistration(t, filepath.Join(home, ".claude"), sleeper, nil)
	if got, err := nativeClaudeAccountRoot(sleeper); err == nil {
		t.Fatalf("unreadable environment resolved to %q", got)
	}
	if _, err := nativeClaudeAccountRoot(spawnGonePID(t)); err == nil {
		t.Fatal("a process that is gone resolved an account")
	}
}

// The group member's registry is its own account's session directory.
func TestNativeClaudeSessionsDirectoryNeverDefaultsForMember(t *testing.T) {
	home := claudeTestConfig(t)
	t.Setenv("HOME", home)
	acct := claudeTestConfig(t)
	member, _ := spawnAccountOwner(t, []string{"CLAUDE_CONFIG_DIR=" + acct})
	if got, err := nativeClaudeSessionsDirectory(member); err != nil || got != filepath.Join(acct, "sessions") {
		t.Fatalf("member registry = %q, %v", got, err)
	}
	if got, err := nativeClaudeSessionsDirectory(spawnPlatformSleeper(t)); err == nil {
		t.Fatalf("unreadable member environment resolved to %q", got)
	}
}

// The desktop session observed for an ancestor is read from that ancestor's
// own account only. A default-account record never attributes a non-default
// owner, and an unreadable account refuses the observation.
func TestClaudeDesktopSessionAtNeverReadsDefaultAccount(t *testing.T) {
	home := claudeTestConfig(t)
	t.Setenv("HOME", home)
	acct := claudeTestConfig(t)
	self, err := processStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}

	owner, _ := spawnAccountOwner(t, []string{"CLAUDE_CONFIG_DIR=" + acct})
	writeClaudeRegistration(t, filepath.Join(home, ".claude"), owner, nil)
	if _, found, err := claudeDesktopSessionAt(owner, os.Getpid(), self); found || err != nil {
		t.Fatalf("default-account record attributed a non-default owner: found=%v err=%v", found, err)
	}

	writeClaudeRegistration(t, acct, owner, nil)
	actor, found, err := claudeDesktopSessionAt(owner, os.Getpid(), self)
	if err != nil || !found || actor.AccountRoot != acct || actor.PID != owner {
		t.Fatalf("own-account desktop session refused: %+v found=%v err=%v", actor, found, err)
	}

	sleeper := spawnPlatformSleeper(t)
	writeClaudeRegistration(t, filepath.Join(home, ".claude"), sleeper, nil)
	if actor, found, err := claudeDesktopSessionAt(sleeper, os.Getpid(), self); err == nil {
		t.Fatalf("unreadable account attributed a session: %+v found=%v", actor, found)
	}
}
