package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestV4ReviewEnvUnsetMustKeepManagedCodexAfterPathReorder(t *testing.T) {
	home := t.TempDir()
	// Ported: the managed marker sits where relayd installs the shims (see
	// startSession), and the default-account command is the exact form the
	// app and the maintenance resume type, pinned to that shim.
	shim := filepath.Join(home, ".local", "share", "relay", "shims")
	other := filepath.Join(home, "environment")
	for dir, marker := range map[string]string{shim: "managed", other: "unmanaged"} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "codex"), []byte("#!/bin/sh\nprintf '"+marker+":%s\\n' \"${CODEX_HOME+set}\"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	prefix := relayCodexShellFunction(shim) + "\nexport PATH=" + shellQuote(other) + ":$PATH\n"
	try := func(command string) (string, error) {
		p := exec.Command("/bin/bash", "--noprofile", "--norc", "-c", prefix+command)
		p.Env = []string{"HOME=" + home, "PATH=" + shim + ":/usr/bin:/bin", "CODEX_HOME=/synthetic/personal"}
		data, err := p.CombinedOutput()
		return strings.TrimSpace(string(data)), err
	}
	run := func(command string) string {
		got, err := try(command)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	if got := run("(unset CODEX_HOME && codex)"); got != "managed:" {
		t.Fatalf("control failed: %q", got)
	}
	if got := run(`env -u CODEX_HOME "$HOME"/.local/share/relay/shims/codex`); got != "managed:" {
		t.Fatalf("default launch bypassed Relay's own shell function after PATH reorder: %q", got)
	}
	if got := run(`CODEX_HOME="$HOME"/.codex-personal "$HOME"/.local/share/relay/shims/codex`); got != "managed:set" {
		t.Fatalf("account launch bypassed the managed shim after PATH reorder: %q", got)
	}
	if err := os.Remove(filepath.Join(shim, "codex")); err != nil {
		t.Fatal(err)
	}
	if got, err := try(`env -u CODEX_HOME "$HOME"/.local/share/relay/shims/codex`); err == nil || strings.Contains(got, "unmanaged") {
		t.Fatalf("a missing managed shim fell back to PATH: %q %v", got, err)
	}
}

func TestV4ReviewSharedHistoryMustKeepMainRootSafety(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	main := filepath.Join(home, ".claude")
	personal := filepath.Join(home, ".claude-personal")
	relative := filepath.Join("p", "11111111-1111-4111-8111-111111111111.jsonl")
	writeTranscript(t, filepath.Join(main, "projects", relative), "{}\n")
	if err := os.MkdirAll(personal, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(main, "projects"), filepath.Join(personal, "projects")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(main, 0o777); err != nil {
		t.Fatal(err)
	}
	canonical := filepath.Join(main, "projects", relative)
	if _, err := rotationSourcePathIn(canonical, "claude", main); err == nil {
		t.Fatal("control: strict source safety check unexpectedly accepted a writable main root")
	}
	if err := validateAccountTranscript(filepath.Join(personal, "projects", relative), "claude", personal); err == nil {
		t.Fatal("shared history bypassed the main root's existing owner/mode safety check")
	}
}
