package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestPromptOwnerBindingUsesKernelShellAndWorker(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	pane := "3040ccdc-28eb-4adc-bdf3-b03e4ec28ad6"
	command := exec.Command("/bin/sh", "-c", "read waiting")
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { input.Close(); command.Process.Kill(); command.Wait() }()
	workerStart, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	shellStart, err := processStartTime(command.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	boot, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	manifest := workerManifest{Version: workerProtocolVersion, SessionID: pane,
		WorkerPID: os.Getpid(), WorkerStartTime: workerStart, ShellPID: command.Process.Pid, NodeBootID: boot}
	if err = storeManifest(server.manifestPath(pane), manifest); err != nil {
		t.Fatal(err)
	}
	first, err := server.readVerifiedPromptOwnerBinding(pane)
	if err != nil {
		t.Fatal(err)
	}
	if first.Provider != "shell" || first.ShellPID != command.Process.Pid || first.ProcessID != command.Process.Pid || first.ShellStart != shellStart || first.ProcessStart != shellStart || first.WorkerStart != workerStart || first.NodeBootID != boot {
		t.Fatalf("incorrect kernel shell identity: %+v", first)
	}
	second, err := server.readVerifiedPromptOwnerBinding(pane)
	if err != nil || first != second {
		t.Fatalf("unchanged identity changed: %+v %v", second, err)
	}
	manifest.WorkerStartTime++
	if err = storeManifest(server.manifestPath(pane), manifest); err != nil {
		t.Fatal(err)
	}
	if _, err = server.readVerifiedPromptOwnerBinding(pane); err == nil {
		t.Fatal("reused worker identity accepted")
	}
	manifest.WorkerStartTime = workerStart
	manifest.ShellPID = os.Getppid()
	if err = storeManifest(server.manifestPath(pane), manifest); err != nil {
		t.Fatal(err)
	}
	if _, err = server.readVerifiedPromptOwnerBinding(pane); err == nil {
		t.Fatal("shell outside worker ancestry accepted")
	}
	manifest.ShellPID = command.Process.Pid
	if err = storeManifest(server.manifestPath(pane), manifest); err != nil {
		t.Fatal(err)
	}
	input.Close()
	command.Wait()
	if _, err = server.readVerifiedPromptOwnerBinding(pane); err == nil {
		t.Fatal("exited shell accepted")
	}
	if _, err = server.readVerifiedPromptOwnerBinding("../../invalid"); err == nil {
		t.Fatal("invalid pane accepted")
	}
}
