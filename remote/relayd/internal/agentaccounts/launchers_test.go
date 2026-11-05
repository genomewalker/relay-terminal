package agentaccounts

import (
	"os"
	"path/filepath"
	"testing"
)

// The launchers the remote installer wrote and the one written by hand on
// a Mac before Relay installed them there. A repair must leave all three
// byte-for-byte as they are.
const (
	linuxClaudeLauncher = "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=claude\nexport RELAY_INVOKED_AS\nexec \"$HOME/.local/bin/relayd\" \"$@\"\n"
	linuxCodexLauncher  = "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=codex\nexport RELAY_INVOKED_AS\nexec \"$HOME/.local/bin/relayd\" \"$@\"\n"
	macCodexLauncher    = "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=codex\nexport RELAY_INVOKED_AS\nexec /Applications/Relay.app/Contents/MacOS/relayd \"$@\"\n"
	macBundleRelayd     = "/Applications/Relay.app/Contents/MacOS/relayd"
)

func launcherStates(statuses []LauncherStatus) map[string]string {
	states := map[string]string{}
	for _, status := range statuses {
		states[status.Provider] = status.State
	}
	return states
}

func linuxLauncherHost(t *testing.T) LauncherHost {
	t.Helper()
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".local", "bin", "relayd"), "#!/bin/sh\n")
	if err := os.Chmod(filepath.Join(home, ".local", "bin", "relayd"), 0o700); err != nil {
		t.Fatal(err)
	}
	return LauncherHost{Home: home, GOOS: "linux"}
}

func writeLauncherFile(t *testing.T, host LauncherHost, provider, content string) string {
	t.Helper()
	path := filepath.Join(host.ShimsDir(), provider)
	if err := os.MkdirAll(host.ShimsDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLauncherContentMatchesExistingInstalls(t *testing.T) {
	if got := LauncherContent("claude", linuxRelaydReference); got != linuxClaudeLauncher {
		t.Fatalf("linux claude launcher %q", got)
	}
	if got := LauncherContent("codex", linuxRelaydReference); got != linuxCodexLauncher {
		t.Fatalf("linux codex launcher %q", got)
	}
	target, problem := LauncherHost{GOOS: "darwin", Relayd: macBundleRelayd}.target()
	if problem != "" || LauncherContent("codex", target) != macCodexLauncher {
		t.Fatalf("mac codex launcher %q %q", LauncherContent("codex", target), problem)
	}
	quoted, _ := LauncherHost{GOOS: "darwin", Relayd: "/Applications/My Relay's.app/Contents/MacOS/relayd"}.target()
	if quoted != `'/Applications/My Relay'\''s.app/Contents/MacOS/relayd'` {
		t.Fatalf("quoted target %q", quoted)
	}
}

func TestRepairInstallsMissingLaunchersOnLinux(t *testing.T) {
	host := linuxLauncherHost(t)
	if states := launcherStates(Launchers(host)); states["claude"] != LauncherMissing || states["codex"] != LauncherMissing {
		t.Fatalf("report %v", states)
	}
	if _, err := os.Lstat(host.ShimsDir()); !os.IsNotExist(err) {
		t.Fatal("a report must not create the shims directory")
	}
	if states := launcherStates(RepairLaunchers(host)); states["claude"] != LauncherInstalled || states["codex"] != LauncherInstalled {
		t.Fatalf("repair %v", states)
	}
	for provider, want := range map[string]string{"claude": linuxClaudeLauncher, "codex": linuxCodexLauncher} {
		path := filepath.Join(host.ShimsDir(), provider)
		if got := string(mustRead(t, path)); got != want {
			t.Fatalf("%s launcher %q", provider, got)
		}
		if info, _ := os.Stat(path); info.Mode().Perm() != 0o700 {
			t.Fatalf("%s launcher mode %v", provider, info.Mode())
		}
	}
	if info, _ := os.Stat(host.ShimsDir()); info.Mode().Perm() != 0o700 {
		t.Fatalf("shims directory mode %v", info.Mode())
	}
	if states := launcherStates(RepairLaunchers(host)); states["claude"] != LauncherCurrent || states["codex"] != LauncherCurrent {
		t.Fatalf("second repair %v", states)
	}
	entries, _ := os.ReadDir(host.ShimsDir())
	if len(entries) != 2 {
		t.Fatalf("temporary files left behind: %v", entries)
	}
}

func TestLinuxLaunchersNeedRelaydInPlace(t *testing.T) {
	host := LauncherHost{Home: t.TempDir(), GOOS: "linux"}
	for _, status := range RepairLaunchers(host) {
		if status.State != LauncherUnavailable || status.Detail == "" {
			t.Fatalf("%+v", status)
		}
	}
	if _, err := os.Lstat(filepath.Join(host.ShimsDir(), "claude")); !os.IsNotExist(err) {
		t.Fatal("no launcher may be written without relayd")
	}
}

func TestMacRepairKeepsCurrentAndFixesStaleLaunchers(t *testing.T) {
	host := LauncherHost{Home: t.TempDir(), GOOS: "darwin", Relayd: macBundleRelayd}
	codex := writeLauncherFile(t, host, "codex", macCodexLauncher)
	claude := writeLauncherFile(t, host, "claude", LauncherContent("claude", "/private/tmp/old-build/relayd"))
	before, _ := os.Stat(codex)
	statuses := RepairLaunchers(host)
	if states := launcherStates(statuses); states["codex"] != LauncherCurrent || states["claude"] != LauncherRepaired {
		t.Fatalf("repair %+v", statuses)
	}
	if after, _ := os.Stat(codex); !os.SameFile(before, after) || string(mustRead(t, codex)) != macCodexLauncher {
		t.Fatal("a current launcher must not be rewritten")
	}
	if got := string(mustRead(t, claude)); got != LauncherContent("claude", macBundleRelayd) {
		t.Fatalf("repaired claude launcher %q", got)
	}
	// A Linux-style launcher on a Mac names a relayd that is not there.
	writeLauncherFile(t, host, "claude", linuxClaudeLauncher)
	if states := launcherStates(Launchers(host)); states["claude"] != LauncherStale {
		t.Fatalf("report %v", states)
	}
}

func TestRepairNeverTouchesFilesRelayDidNotWrite(t *testing.T) {
	host := linuxLauncherHost(t)
	custom := writeLauncherFile(t, host, "claude",
		"#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=claude\nexport RELAY_INVOKED_AS\nexec \"$HOME/.local/bin/relayd\" --settings \"$HOME/.config/relay/claude-hooks-status.json\" \"$@\"\n")
	foreign := writeLauncherFile(t, host, "codex", "#!/bin/sh\nexec /opt/codex/bin/codex \"$@\"\n")
	backup := writeLauncherFile(t, host, "claude.before-continuation-20261007", "anything\n")
	statuses := RepairLaunchers(host)
	if states := launcherStates(statuses); states["claude"] != LauncherCustom || states["codex"] != LauncherForeign {
		t.Fatalf("repair %+v", statuses)
	}
	if len(statuses) != 2 {
		t.Fatalf("only the two launcher names are examined: %+v", statuses)
	}
	if string(mustRead(t, foreign)) != "#!/bin/sh\nexec /opt/codex/bin/codex \"$@\"\n" || string(mustRead(t, backup)) != "anything\n" ||
		len(mustRead(t, custom)) == len(linuxClaudeLauncher) {
		t.Fatal("a file Relay did not write was changed")
	}
	// A provider's launcher under the other provider's name is not Relay's.
	writeLauncherFile(t, host, "codex", linuxClaudeLauncher)
	if states := launcherStates(RepairLaunchers(host)); states["codex"] != LauncherForeign {
		t.Fatalf("crossed launcher %v", states)
	}
}

func TestRepairNeverFollowsLinks(t *testing.T) {
	host := linuxLauncherHost(t)
	elsewhere := filepath.Join(t.TempDir(), "target")
	writeFile(t, elsewhere, LauncherContent("claude", "/old/relayd"))
	if err := os.MkdirAll(host.ShimsDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(host.ShimsDir(), "claude")); err != nil {
		t.Fatal(err)
	}
	if states := launcherStates(RepairLaunchers(host)); states["claude"] != LauncherForeign {
		t.Fatalf("linked launcher %v", states)
	}
	if string(mustRead(t, elsewhere)) != LauncherContent("claude", "/old/relayd") {
		t.Fatal("a link target was written")
	}
}

func TestRepairRefusesAnUnsafeShimsDirectory(t *testing.T) {
	host := linuxLauncherHost(t)
	if err := os.MkdirAll(host.ShimsDir(), 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(host.ShimsDir(), 0o777); err != nil {
		t.Fatal(err)
	}
	for _, status := range RepairLaunchers(host) {
		if status.State != LauncherUnavailable {
			t.Fatalf("%+v", status)
		}
	}
	if entries, _ := os.ReadDir(host.ShimsDir()); len(entries) != 0 {
		t.Fatalf("wrote into a world-writable directory: %v", entries)
	}
}

func TestRepairLeavesALauncherThatChangedMeanwhile(t *testing.T) {
	host := linuxLauncherHost(t)
	stale := LauncherContent("claude", "/old/relayd")
	path := writeLauncherFile(t, host, "claude", stale)
	status, _ := inspectLauncher("claude", path, linuxRelaydReference)
	if status.State != LauncherStale {
		t.Fatalf("%+v", status)
	}
	writeFile(t, path, "#!/bin/sh\necho mine\n")
	result := writeLauncher("claude", path, linuxClaudeLauncher, status, []byte(stale))
	if result.State != LauncherStale || string(mustRead(t, path)) != "#!/bin/sh\necho mine\n" {
		t.Fatalf("%+v", result)
	}
	if entries, _ := os.ReadDir(host.ShimsDir()); len(entries) != 1 {
		t.Fatalf("temporary files left behind: %v", entries)
	}
}

// relayd started by launchd (This Mac) or a supervisor has a minimal PATH;
// a CLI in ~/.local/bin is still found, and Relay's own launcher never is.
func TestProviderExecutableFindsUserInstalledCLIsOutsidePATH(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("RELAY_CLAUDE_BIN", "")
	t.Setenv("PATH", filepath.Join(home, ".local", "share", "relay", "shims")+string(os.PathListSeparator)+"/nonexistent")
	writeLauncherFile(t, LauncherHost{Home: home, GOOS: "linux"}, "claude", linuxClaudeLauncher)
	cli := filepath.Join(home, ".local", "bin", "claude")
	writeFile(t, cli, "#!/bin/sh\n")
	if err := os.Chmod(cli, 0o700); err != nil {
		t.Fatal(err)
	}
	if found, err := ProviderExecutable("claude"); err != nil || found != cli {
		t.Fatalf("%q %v", found, err)
	}
}

// Relay's launcher with the right bytes but a wrong mode is repaired in
// place (same file, content untouched); a custom or foreign file keeps its mode.
func TestRepairFixesTheModeOfRelaysOwnLauncherOnly(t *testing.T) {
	for _, mode := range []os.FileMode{0o600, 0o644, 0o720, 0o707, 0o777} {
		host := linuxLauncherHost(t)
		path := writeLauncherFile(t, host, "claude", linuxClaudeLauncher)
		custom := writeLauncherFile(t, host, "codex",
			"#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=codex\nexport RELAY_INVOKED_AS\nexec \"$HOME/.local/bin/relayd\" --settings \"$HOME/.config/relay/claude-hooks-status.json\" \"$@\"\n")
		for _, file := range []string{path, custom} {
			if err := os.Chmod(file, mode); err != nil {
				t.Fatal(err)
			}
		}
		before, _ := os.Stat(path)
		report := Launchers(host)
		if launcherStates(report)["claude"] != LauncherWrongMode {
			t.Fatalf("%04o: report %+v", mode, report)
		}
		if launcherStates(RepairLaunchers(host))["claude"] != LauncherRepaired {
			t.Fatalf("%04o: repair did not fix the mode", mode)
		}
		after, _ := os.Stat(path)
		if after.Mode().Perm() != 0o700 || !os.SameFile(before, after) || string(mustRead(t, path)) != linuxClaudeLauncher {
			t.Fatalf("%04o: after repair mode %04o, same file %v", mode, after.Mode().Perm(), os.SameFile(before, after))
		}
		if info, _ := os.Stat(custom); info.Mode().Perm() != mode {
			t.Fatalf("%04o: a custom launcher's mode changed to %04o", mode, info.Mode().Perm())
		}
		if states := launcherStates(Launchers(host)); states["claude"] != LauncherCurrent {
			t.Fatalf("%04o: after repair %v", mode, states)
		}
	}
}

func TestModeRepairLeavesALauncherThatChangedMeanwhile(t *testing.T) {
	host := linuxLauncherHost(t)
	path := writeLauncherFile(t, host, "claude", linuxClaudeLauncher)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	status, observed := inspectLauncher("claude", path, linuxRelaydReference)
	writeFile(t, path, "#!/bin/sh\necho mine\n")
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if result := fixLauncherMode(path, status, observed); result.State != LauncherWrongMode {
		t.Fatalf("%+v", result)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatal("a changed file's mode was set")
	}
}
