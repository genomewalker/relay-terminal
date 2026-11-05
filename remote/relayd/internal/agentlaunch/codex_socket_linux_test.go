//go:build linux

package agentlaunch

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestCodexSocketCandidateUsesProcessEnvironmentOrExplicitRemote(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home")
	env := []byte("HOME=" + home + "\x00TERM=xterm-relay\x00")
	want := filepath.Join(home, ".codex", "app-server-control", "app-server-control.sock")
	got, err := codexSocketCandidate([]string{"resume", "old-id"}, env)
	if err != nil || got != want {
		t.Fatalf("home candidate: %q %v", got, err)
	}
	customHome := filepath.Join(t.TempDir(), "codex-home")
	got, err = codexSocketCandidate(nil, []byte("HOME="+home+"\x00CODEX_HOME="+customHome+"\x00"))
	if err != nil || got != filepath.Join(customHome, "app-server-control", "app-server-control.sock") {
		t.Fatalf("CODEX_HOME override: %q %v", got, err)
	}
	custom := filepath.Join(t.TempDir(), "control.sock")
	got, err = codexSocketCandidate([]string{"resume", "--remote", "unix://" + custom, "old-id"}, env)
	if err != nil || got != custom {
		t.Fatalf("explicit endpoint: %q %v", got, err)
	}
	for _, args := range [][]string{
		{"--remote", "ws://127.0.0.1:9000"},
		{"--remote", "unix://" + custom, "--remote", "unix://" + custom},
	} {
		if _, err := codexSocketCandidate(args, env); err == nil {
			t.Fatalf("unverified endpoint accepted: %v", args)
		}
	}
	if _, err := codexSocketCandidate(nil, []byte("HOME=/a\x00HOME=/b\x00")); err == nil {
		t.Fatal("duplicate HOME accepted")
	}
}

func TestCodexSocketRequiresPrivateOwnedUnixSocket(t *testing.T) {
	// AF_UNIX limits the complete pathname, including Go's test-name prefix.
	// Keep the real socket fixture short while retaining all ownership/mode
	// assertions below; a long fixture fails before that policy is exercised.
	root, err := os.MkdirTemp("/tmp", "rcs-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	directory := filepath.Join(root, "app-server-control")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "app-server-control.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if dev, ino, err := privateCodexSocket(path); err != nil || dev == 0 || ino == 0 {
		t.Fatalf("private socket: %d %d %v", dev, ino, err)
	}
	if err := os.Chmod(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := privateCodexSocket(path); err == nil {
		t.Fatal("public parent accepted")
	}
}
