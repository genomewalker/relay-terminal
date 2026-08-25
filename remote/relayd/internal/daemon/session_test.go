package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClassifyAgentProcess(t *testing.T) {
	tests := []struct {
		command   string
		arguments string
		want      string
	}{
		{"codex", "/home/me/.local/bin/codex\x00resume\x00thr_1", "codex"},
		{"node", "/opt/tools/claude --dangerously-skip-permissions", "claude"},
		{"bash", "bash -l", ""},
	}
	for _, test := range tests {
		if got := classifyAgentProcess(test.command, test.arguments); got != test.want {
			t.Fatalf("classifyAgentProcess(%q, %q) = %q, want %q", test.command, test.arguments, got, test.want)
		}
	}
}

func TestReplayStartUsesLatestFullScreenRedrawOnlyForFreshRenderer(t *testing.T) {
	replay := []record{
		{sequence: 1, data: []byte("old output\x1b[2Jfirst redraw")},
		{sequence: 2, data: []byte("more\x1b[2Jcurrent screen")},
		{sequence: 3, data: []byte(" tail")},
	}

	recordIndex, byteOffset := replayStart(replay, 0)
	if recordIndex != 1 || byteOffset != len("more") {
		t.Fatalf("fresh replay starts at (%d, %d), want (1, %d)", recordIndex, byteOffset, len("more"))
	}
	recordIndex, byteOffset = replayStart(replay, 1)
	if recordIndex != 0 || byteOffset != 0 {
		t.Fatalf("incremental replay must remain exact, got (%d, %d)", recordIndex, byteOffset)
	}
}

func TestEnvironmentOverridesReplaceHotPathVariables(t *testing.T) {
	environment := environmentWithOverrides(
		[]string{"PATH=/old", "TERM=old", "UNCHANGED=yes"},
		map[string]string{"PATH": "/relay:/old", "TERM": "xterm-256color"},
	)
	values := make(map[string]string)
	for _, entry := range environment {
		for index := range entry {
			if entry[index] == '=' {
				values[entry[:index]] = entry[index+1:]
				break
			}
		}
	}
	if values["PATH"] != "/relay:/old" || values["TERM"] != "xterm-256color" || values["UNCHANGED"] != "yes" {
		t.Fatalf("unexpected environment: %#v", values)
	}
}

func TestBashIntegrationKeepsRelayShimsAheadOfUserPathChanges(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	home := t.TempDir()
	realDirectory := filepath.Join(home, "real")
	shimDirectory := filepath.Join(home, "relay shims")
	for _, directory := range []string{realDirectory, shimDirectory} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, directory := range []string{realDirectory, shimDirectory} {
		if err := os.WriteFile(filepath.Join(directory, "codex"), []byte("#!/bin/sh\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, ".bashrc"), []byte("export PATH='"+realDirectory+":'$PATH\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rcPath, err := writeBashIntegration(home, shimDirectory)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(bash, "--rcfile", rcPath, "-i", "-c", "command -v codex")
	command.Env = append(os.Environ(), "HOME="+home, "PATH="+realDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("bash integration failed: %v: %s", err, output)
	}
	if !strings.Contains(string(output), filepath.Join(shimDirectory, "codex")) {
		t.Fatalf("Relay shim did not win command lookup: %s", output)
	}
}

func TestExitedSessionIsReplacedOnNextAttach(t *testing.T) {
	first, err := startSession("restart-test", "exit 0", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !first.hasExited() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !first.hasExited() {
		t.Fatal("first session did not exit")
	}

	second, err := startSession("restart-test", "sleep 5", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("exited session was reused")
	}
	_ = second.signal(15)
}
