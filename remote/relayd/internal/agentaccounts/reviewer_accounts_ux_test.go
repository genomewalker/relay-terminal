package agentaccounts

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReviewerRemoveRequiresNativeUserOrigin(t *testing.T) {
	home, _, root := removeFixture(t)
	t.Setenv("HOME", home)
	response, err := Handle(Request{Action: "remove", Provider: "claude", Label: "personal"}, nil)
	if err == nil {
		t.Errorf("remove accepted without native user-origin proof; moved=%t", response.Removed != nil && response.Removed.MovedTo != "")
	}
	if _, err := os.Lstat(root); err != nil {
		t.Errorf("account folder moved without native user authorization")
	}
}

func TestReviewerOpaqueCredentialDiagnosticIsWithheld(t *testing.T) {
	home := t.TempDir()
	root := filepath.Join(home, ".claude-fixture")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	// Entirely synthetic JWT-shaped sentinel; no real credential is used.
	sentinel := "eyJhbGciOiJub25lIn0.eyJzdWIiOiJyZXZpZXdlci1maXh0dXJlIn0.FICTITIOUS"
	script := filepath.Join(home, "claude-fixture")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' '"+sentinel+"' >&2\nexit 3\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CLAUDE_BIN", script)
	status := AccountStatus(home, Account{Provider: "claude", Label: "fixture", Dir: root}, ProviderProbe)
	if status.Probe != "failed" {
		t.Fatalf("fixture did not fail probe: %s", status.Probe)
	}
	if strings.Contains(status.ProbeReason, sentinel) {
		t.Error("status diagnostic forwarded the complete synthetic opaque credential")
	}
	usage := ReadUsage(home, []Account{{Provider: "claude", Label: "fixture", Dir: root}}, ProviderUsage, time.Now())
	if len(usage) != 1 {
		t.Fatal("no usage result")
	}
	if strings.Contains(usage[0].Reason, sentinel) {
		t.Error("usage diagnostic forwarded the complete synthetic opaque credential")
	}
}

func TestReviewerAccountRaceHelper(t *testing.T) {
	if os.Getenv("REVIEWER_REMOVE_RACE_HELPER") != "1" {
		return
	}
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func TestReviewerRemoveRefusesAgentStartedDuringLogout(t *testing.T) {
	home, registry, root := removeFixture(t)
	original := agentProcessName
	t.Cleanup(func() { agentProcessName = original })
	self := filepath.Base(os.Args[0])
	agentProcessName = func(name string) bool { return strings.HasPrefix(self, name) || strings.HasPrefix(name, self) }
	var cmd *exec.Cmd
	var stdin io.WriteCloser
	logoutRunner = func(ctx context.Context, provider, override string) error {
		cmd = exec.Command(os.Args[0], "-test.run=^TestReviewerAccountRaceHelper$")
		cmd.Env = []string{"REVIEWER_REMOVE_RACE_HELPER=1", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + root}
		out, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		stdin, err = cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = stdin.Close(); _ = cmd.Process.Kill(); _ = cmd.Wait() })
		line, err := bufio.NewReader(out).ReadString('\n')
		if err != nil || line != "ready\n" {
			t.Fatalf("helper readiness failed: %v", err)
		}
		running, err := runningAgents(provider, root)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, p := range running {
			if p.pid == cmd.Process.Pid {
				found = true
			}
		}
		if !found {
			t.Fatal("fixture helper not visible to account scanner")
		}
		return nil
	}
	_, removed, err := Remove(home, registry, "claude", "personal", time.Now())
	if err == nil {
		t.Errorf("removed after agent started during logout; moved=%t", removed.MovedTo != "")
	}
	if _, err := os.Lstat(root); err != nil {
		t.Error("moved folder while verified agent was using it")
	}
}
