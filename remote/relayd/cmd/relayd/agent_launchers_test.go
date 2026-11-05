package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// mainHelper runs relayd's main() in a child test process with the given
// arguments and environment, as a launcher's exec would.
func runMainHelper(t *testing.T, test string, arguments []string, environment ...string) ([]byte, error) {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^"+test+"$")
	command.Env = append(os.Environ(), environment...)
	command.Env = append(command.Env, "RELAY_MAIN_TEST_HELPER=1", "RELAY_MAIN_TEST_ARGS="+strings.Join(arguments, "\x1f"))
	return command.CombinedOutput()
}

func mainHelper() bool {
	if os.Getenv("RELAY_MAIN_TEST_HELPER") != "1" {
		return false
	}
	os.Args = append([]string{os.Args[0]}, strings.Split(os.Getenv("RELAY_MAIN_TEST_ARGS"), "\x1f")...)
	os.Unsetenv("RELAY_MAIN_TEST_HELPER")
	main()
	os.Exit(0)
	return true
}

// A launcher sets RELAY_INVOKED_AS and execs relayd under its own name.
// This holds on every platform relayd runs on, macOS included: relayd
// starts the real CLI with Relay's settings and the marker removed.
func TestLauncherInvocationStartsClaudeOnThisPlatform(t *testing.T) {
	if mainHelper() {
		return
	}
	home := t.TempDir()
	record := filepath.Join(t.TempDir(), "record")
	fake := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\nprintf '%s|%s\\n' \"${RELAY_INVOKED_AS-unset}\" \"$*\" > " + record + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	output, err := runMainHelper(t, "TestLauncherInvocationStartsClaudeOnThisPlatform", []string{"--print", "hello"},
		"HOME="+home, "RELAY_INVOKED_AS=claude", "RELAY_CLAUDE_BIN="+fake, "RELAY_SESSION=", "RELAY_PROMPT_EDITOR_ENABLE=")
	if err != nil {
		t.Fatalf("%s: %v %s", runtime.GOOS, err, output)
	}
	got, err := os.ReadFile(record)
	if err != nil {
		t.Fatalf("the real claude did not run: %v %s", err, output)
	}
	settings := filepath.Join(home, ".relay", "claude-hooks.json")
	if want := "unset|--settings " + settings + " --print hello\n"; string(got) != want {
		t.Fatalf("%s: claude ran as %q, want %q", runtime.GOOS, got, want)
	}
}

func TestAgentLaunchersRepairInstallsBothLaunchers(t *testing.T) {
	if mainHelper() {
		return
	}
	home := t.TempDir()
	if runtime.GOOS != "darwin" {
		relayd := filepath.Join(home, ".local", "bin", "relayd")
		if err := os.MkdirAll(filepath.Dir(relayd), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(relayd, []byte("#!/bin/sh\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, step := range []struct {
		arguments []string
		state     string
		failed    bool
	}{{[]string{}, "missing", true}, {[]string{"--repair"}, "installed", false}, {[]string{}, "current", false}} {
		output, err := runMainHelper(t, "TestAgentLaunchersRepairInstallsBothLaunchers", append([]string{"agent-launchers"}, step.arguments...), "HOME="+home)
		if (err != nil) != step.failed {
			t.Fatalf("%v: %v %s", step.arguments, err, output)
		}
		var report struct {
			Launchers []struct{ Provider, State string }
		}
		line := output[:strings.IndexByte(string(output), '\n')+1]
		if json.Unmarshal(line, &report) != nil || len(report.Launchers) != 2 {
			t.Fatalf("%v: %s", step.arguments, output)
		}
		for _, launcher := range report.Launchers {
			if launcher.State != step.state {
				t.Fatalf("%v: %+v", step.arguments, report.Launchers)
			}
		}
	}
	content, _ := os.ReadFile(filepath.Join(home, ".local", "share", "relay", "shims", "claude"))
	if !strings.HasPrefix(string(content), "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=claude\n") {
		t.Fatalf("launcher %q", content)
	}
}

// The codex launcher outside a Relay pane session passes a subcommand such as
// login straight to the real CLI, with the marker removed.
func TestLauncherInvocationStartsCodexOnThisPlatform(t *testing.T) {
	if mainHelper() {
		return
	}
	home := t.TempDir()
	record := filepath.Join(t.TempDir(), "record")
	fake := filepath.Join(t.TempDir(), "codex")
	script := "#!/bin/sh\nprintf '%s|%s\\n' \"${RELAY_INVOKED_AS-unset}\" \"$*\" > " + record + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	output, err := runMainHelper(t, "TestLauncherInvocationStartsCodexOnThisPlatform", []string{"login", "status"},
		"HOME="+home, "RELAY_INVOKED_AS=codex", "RELAY_CODEX_BIN="+fake, "RELAY_SESSION=", "RELAY_PROMPT_EDITOR_ENABLE=")
	if err != nil {
		t.Fatalf("%s: %v %s", runtime.GOOS, err, output)
	}
	if got, err := os.ReadFile(record); err != nil || string(got) != "unset|login status\n" {
		t.Fatalf("%s: codex ran as %q (%v) %s", runtime.GOOS, got, err, output)
	}
}
