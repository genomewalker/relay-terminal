package daemon

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestEnsurePrivateRuntimeDirRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "runtime")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePrivateRuntimeDir(link); err == nil {
		t.Fatal("expected symlink runtime directory to be rejected")
	}
}

func TestEnsurePrivateRuntimeDirRepairsPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePrivateRuntimeDir(path); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("runtime permissions = %o, want 700", got)
	}
}

func TestOpenPrivateFileRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.WriteFile(target, []byte("do not replace"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "relayd.log")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	file, err := OpenPrivateFile(link, syscall.O_CREAT|syscall.O_WRONLY)
	if file != nil {
		_ = file.Close()
	}
	if err == nil {
		t.Fatal("expected symlink runtime file to be rejected")
	}
}
