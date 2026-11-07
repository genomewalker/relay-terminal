package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// markClaudeTestProcesses names test processes as Claude ancestors for the
// duration of one test. Their real identity is the test binary's.
func markClaudeTestProcesses(t *testing.T, pids ...int) {
	t.Helper()
	named := map[int]bool{}
	for _, pid := range pids {
		named[pid] = true
	}
	previous := claudeAncestorIsClaude
	claudeAncestorIsClaude = func(pid int) bool { return named[pid] }
	t.Cleanup(func() { claudeAncestorIsClaude = previous })
}

// A shell wrapper between the client and Claude has a withheld environment; it
// is skipped and the Claude ancestor's desktop session is still attributed.
func TestClaudeSessionWalkSkipsWithheldEnvironmentWrapper(t *testing.T) {
	home := claudeTestConfig(t)
	t.Setenv("HOME", home)
	acct := claudeTestConfig(t)
	owner, _ := spawnAccountOwner(t, []string{"CLAUDE_CONFIG_DIR=" + acct})
	markClaudeTestProcesses(t, owner)
	writeClaudeRegistration(t, acct, owner, nil)
	shell := exec.Command("/bin/sh", "-c", "sleep 30")
	if err := shell.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { shell.Process.Kill(); shell.Wait() })
	start, err := processStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	actor, err := readClaudeSessionActorFrom([]int{shell.Process.Pid, owner}, os.Getpid(), start)
	if err != nil || actor.PID != owner || actor.AccountRoot != acct {
		t.Fatalf("wrapper blocked attribution: %+v %v", actor, err)
	}
}

// A Claude ancestor whose account cannot be read refuses the observation,
// even when the default account holds a registration for it.
func TestClaudeSessionWalkRefusesUnreadableClaudeAncestor(t *testing.T) {
	home := claudeTestConfig(t)
	t.Setenv("HOME", home)
	sleeper := spawnPlatformSleeper(t)
	markClaudeTestProcesses(t, sleeper)
	writeClaudeRegistration(t, filepath.Join(home, ".claude"), sleeper, nil)
	start, err := processStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if actor, err := readClaudeSessionActorFrom([]int{sleeper}, os.Getpid(), start); err == nil {
		t.Fatalf("unreadable Claude ancestor attributed: %+v", actor)
	}
}
