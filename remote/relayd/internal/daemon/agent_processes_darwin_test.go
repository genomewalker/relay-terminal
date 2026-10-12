//go:build darwin

package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDarwinAgentCommandStopsAtFirstNUL(t *testing.T) {
	for _, command := range []string{"claude", "codex", "2.1.286", "bash"} {
		raw := append([]byte(command), 0, '1', '4', 0)
		if got := darwinAgentCommand(raw); got != command {
			t.Fatalf("got %q, want %q", got, command)
		}
	}
}

func TestDarwinClaudeVersionExecutableRequiresExactInstall(t *testing.T) {
	home := t.TempDir()
	directory := filepath.Join(home, ".local", "share", "claude", "versions")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "2.1.286")
	if err := os.WriteFile(executable, []byte("fixture"), 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "claude")
	if err := os.Symlink(executable, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{executable, link} {
		if got := classifyDarwinAgentExecutable("2.1.286", path, home); got != "claude" {
			t.Fatalf("%s: %q", path, got)
		}
	}
	for _, row := range [][2]string{{"2.1.285", executable}, {"2.1.286", "relative"}, {"2.1.286", directory}, {"2.1.286", filepath.Join(home, "missing")}} {
		if got := classifyDarwinAgentExecutable(row[0], row[1], home); got != "" {
			t.Fatalf("accepted mismatched executable: %q", got)
		}
	}
	outside := filepath.Join(home, "2.1.286")
	if err := os.WriteFile(outside, []byte("fixture"), 0700); err != nil {
		t.Fatal(err)
	}
	if got := classifyDarwinAgentExecutable("2.1.286", outside, home); got != "" {
		t.Fatal("accepted unrelated version-named executable")
	}
}

func TestDarwinKernelExecutableReportsRunningImage(t *testing.T) {
	got, err := darwinKernelExecutable(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("kernel path %q differs from executable %q", got, want)
	}
	if _, err := darwinKernelExecutable(-1); err == nil {
		t.Fatal("accepted invalid PID")
	}
}
