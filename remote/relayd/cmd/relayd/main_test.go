package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestClaudeHookSettings(t *testing.T) {
	if !json.Valid([]byte(claudeHookSettings)) {
		t.Fatal("Claude hook settings are not valid JSON")
	}
	for _, event := range []string{"PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"} {
		if !strings.Contains(claudeHookSettings, `"`+event+`"`) {
			t.Fatalf("Claude hook settings are missing %s", event)
		}
	}
}

func TestHookEventUnavailableDaemonDoesNotFailClaude(t *testing.T) {
	if os.Getenv("RELAY_EVENT_TEST_HELPER") == "1" {
		runEvent([]string{
			"--socket", os.Getenv("RELAY_EVENT_TEST_SOCKET"),
			"--session", "00000000-0000-4000-8000-000000000000",
			"--agent", "claude", "--source", os.Getenv("RELAY_EVENT_TEST_SOURCE"),
		})
		return
	}
	for _, test := range []struct {
		source  string
		wantErr bool
	}{
		{source: "hook"},
		{source: "provider-native", wantErr: true},
	} {
		command := exec.Command(os.Args[0], "-test.run=^TestHookEventUnavailableDaemonDoesNotFailClaude$")
		command.Env = append(os.Environ(),
			"RELAY_EVENT_TEST_HELPER=1",
			"RELAY_EVENT_TEST_SOCKET="+filepath.Join(t.TempDir(), "missing.sock"),
			"RELAY_EVENT_TEST_SOURCE="+test.source,
		)
		command.Stdin = strings.NewReader(`{"hook_event_name":"Stop"}`)
		output, err := command.CombinedOutput()
		if (err != nil) != test.wantErr {
			t.Fatalf("source %s: error %v, output %q", test.source, err, output)
		}
	}
}

func TestFindRealAgentExecutableSkipsRelayShim(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", root)
	t.Setenv("RELAY_CODEX_BIN", "")
	shimDirectory := filepath.Join(root, "shims")
	realDirectory := filepath.Join(root, "real")
	if err := os.MkdirAll(shimDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(realDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, filepath.Join(shimDirectory, "codex")); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(realDirectory, "codex")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDirectory+string(os.PathListSeparator)+realDirectory)

	found, err := findRealAgentExecutable("codex")
	if err != nil {
		t.Fatal(err)
	}
	if found != real {
		t.Fatalf("found %q, want %q", found, real)
	}
}

func TestFindRealAgentExecutableSkipsRelayOwnedWrapper(t *testing.T) {
	home := t.TempDir()
	t.Setenv("RELAY_CLAUDE_BIN", "")
	shimDirectory := filepath.Join(home, ".local", "share", "relay", "shims")
	realDirectory := filepath.Join(home, "real")
	if err := os.MkdirAll(shimDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(realDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(shimDirectory, "claude")
	if err := os.WriteFile(shim, []byte("#!/bin/sh\nexec relayd \"$@\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(realDirectory, "claude")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("PATH", shimDirectory+string(os.PathListSeparator)+realDirectory)

	found, err := findRealAgentExecutable("claude")
	if err != nil {
		t.Fatal(err)
	}
	if found != real {
		t.Fatalf("found %q, want non-Relay executable %q", found, real)
	}
}

func TestFindRealAgentExecutableHonorsExplicitRelayBinary(t *testing.T) {
	root := t.TempDir()
	configured := filepath.Join(root, "codex-local")
	if err := os.WriteFile(configured, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CODEX_BIN", configured)
	t.Setenv("PATH", "")

	found, err := findRealAgentExecutable("codex")
	if err != nil {
		t.Fatal(err)
	}
	if found != configured {
		t.Fatalf("found %q, want configured binary %q", found, configured)
	}
}

func TestAgentExecEnvironmentRemovesShimMarker(t *testing.T) {
	got := agentExecEnvironment([]string{
		"PATH=/usr/bin",
		"RELAY_INVOKED_AS=claude",
		"RELAY_SESSION=pane-1",
	})
	want := []string{"PATH=/usr/bin", "RELAY_SESSION=pane-1"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("agent environment = %#v, want %#v", got, want)
	}
}

func TestCodexHookProfile(t *testing.T) {
	profile := codexHookProfile("/home/test/.codex/relay-terminal.config.toml")
	if !strings.Contains(profile, "[tui]\nterminal_resize_reflow_max_rows = 256") {
		t.Fatal("Codex hook profile does not bound resize transcript reflow for Relay")
	}
	for _, event := range []string{"SessionStart", "PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"} {
		if !strings.Contains(profile, "[[hooks."+event+"]]") {
			t.Fatalf("Codex hook profile is missing %s", event)
		}
	}
	if !strings.Contains(profile, "--agent codex") {
		t.Fatal("Codex hook profile does not forward events to Relay")
	}
	if !strings.Contains(profile, `[hooks.state."/home/test/.codex/relay-terminal.config.toml:session_start:0:0"]`) {
		t.Fatal("Codex hook trust is not scoped to its generated SessionStart hook")
	}
	if got := codexHookHash("session_start", &codexWildcardMatcher); got != "sha256:0947938d6af2c56fe7cdf8b745e79997e0caaee90cd6d607a8a193f9eae6b30e" {
		t.Fatalf("Codex hook trust hash changed: %s", got)
	}
}

func TestParseObservedSessionsPreservesEventCursors(t *testing.T) {
	sessions := parseObservedSessions("pane-a:42,pane-b,pane-a:99")
	if len(sessions) != 2 || sessions[0].id != "pane-a" || sessions[0].lastEventSequence != 42 ||
		sessions[1].id != "pane-b" || sessions[1].lastEventSequence != 0 {
		t.Fatalf("unexpected observed sessions: %#v", sessions)
	}
}

func TestDefaultSocketNeverUsesSharedHome(t *testing.T) {
	// This is the no-existing-supervisor branch. A live private socket under
	// /run/user must not turn the fallback fixture into the adoption branch.
	saved := defaultSocketRuntimeProbe
	t.Cleanup(func() { defaultSocketRuntimeProbe = saved })
	defaultSocketRuntimeProbe = func(string, int) string { return "" }
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("HOME", "/shared/home/test")
	want := filepath.Join("/tmp", "relay-"+strconv.Itoa(os.Getuid()), "relayd.sock")
	if got := defaultSocket(); got != want {
		t.Fatalf("default socket = %q, want node-local %q", got, want)
	}

	t.Setenv("XDG_RUNTIME_DIR", "/run/user/123")
	if got := defaultSocket(); got != "/run/user/123/relayd.sock" {
		t.Fatalf("runtime socket = %q", got)
	}
}

func TestDesiredMaxProcsKeepsPerPaneRuntimeSmall(t *testing.T) {
	values := map[string]string{}
	lookup := func(key string) string { return values[key] }
	if got := desiredMaxProcs(lookup); got != 2 {
		t.Fatalf("default GOMAXPROCS = %d, want 2", got)
	}
	values["RELAYD_MAX_PROCS"] = "4"
	if got := desiredMaxProcs(lookup); got != 4 {
		t.Fatalf("Relay override = %d, want 4", got)
	}
	values["GOMAXPROCS"] = "8"
	if got := desiredMaxProcs(lookup); got != 0 {
		t.Fatalf("explicit Go setting was overridden: %d", got)
	}
}

// relayd keeps the RELAY_CLAUDE_BIN it started with; after Claude's updater
// deletes that version, the shim launches the version ~/.local/bin points to.
// A configured file that exists but cannot run is still refused.
func TestFindRealAgentExecutableFallsBackWhenTheConfiguredVersionIsGone(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", "")
	versions := filepath.Join(home, ".local", "share", "claude", "versions")
	bin := filepath.Join(home, ".local", "bin")
	for _, directory := range []string{versions, bin} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	current := filepath.Join(versions, "2.1.308")
	if err := os.WriteFile(current, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(current, filepath.Join(bin, "claude")); err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(current)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CLAUDE_BIN", filepath.Join(versions, "2.1.301"))
	if found, err := findRealAgentExecutable("claude"); err != nil || found != want {
		t.Fatalf("found %q %v, want %q", found, err, want)
	}

	broken := filepath.Join(home, "claude-broken")
	if err := os.WriteFile(broken, []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CLAUDE_BIN", broken)
	if found, err := findRealAgentExecutable("claude"); err == nil || !strings.Contains(err.Error(), "not runnable") {
		t.Fatalf("found %q %v, want the configured-path error", found, err)
	}
}
