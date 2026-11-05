package agentaccounts

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestReviewerTimeoutDiagnosticDoesNotOpenBlockingArg0(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "tmp")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "arg0")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(root, "codex-fixture")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexec sleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CODEX_BIN", script)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := ProviderProbe(ctx, "codex", root); done <- err }()
	select {
	case <-done:
		return
	case <-time.After(2 * time.Second):
		// Release the deliberately blocked diagnostic without leaving a worker.
		f, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
		if err != nil {
			t.Fatalf("fixture FIFO reader was not waiting: %v", err)
		}
		_ = f.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("fixture could not release diagnostic")
		}
		t.Error("provider process ended at its deadline, but the timeout diagnostic blocked beyond it on tmp/arg0")
	}
}

func TestReviewerPipeTimeoutKillsSurvivingProcessGroup(t *testing.T) {
	root := t.TempDir()
	pidFile := filepath.Join(root, "child-pid")
	script := filepath.Join(root, "claude-fixture")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > '"+pidFile+"'\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CLAUDE_BIN", script)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, probeErr := ProviderProbe(ctx, "claude", root)
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Kill()
		}
	})
	state, err := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	if err == nil && strings.TrimSpace(string(state)) != "" && !strings.HasPrefix(strings.TrimSpace(string(state)), "Z") {
		t.Errorf("provider returned %v while its fixture descendant remains alive, state=%s", probeErr, strings.TrimSpace(string(state)))
	}
}
