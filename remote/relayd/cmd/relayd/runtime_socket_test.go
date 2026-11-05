package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestExistingOwnedRuntimeSocketRequiresPrivateRealUserObjects(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "relay-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	path := filepath.Join(root, "relayd.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if existingOwnedRelaydRuntimeSocket(root, os.Getuid()) != path {
		t.Fatal("existing private supervisor was not selected")
	}
	if existingOwnedRelaydRuntimeSocket(root, os.Getuid()+1) != "" {
		t.Fatal("foreign runtime was selected")
	}
	if err := os.Chmod(root, 0755); err != nil {
		t.Fatal(err)
	}
	if existingOwnedRelaydRuntimeSocket(root, os.Getuid()) != "" {
		t.Fatal("shared runtime directory was selected")
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if existingOwnedRelaydRuntimeSocket(root, os.Getuid()) != "" {
		t.Fatal("shared socket was selected")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	alias := root + "-alias"
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(alias) })
	if existingOwnedRelaydRuntimeSocket(alias, os.Getuid()) != "" {
		t.Fatal("symlinked runtime was selected")
	}
}

func TestExistingOwnedRuntimeSocketRejectsRegularFile(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "relayd.sock"), []byte("not a socket"), 0600); err != nil {
		t.Fatal(err)
	}
	if existingOwnedRelaydRuntimeSocket(root, os.Getuid()) != "" {
		t.Fatal("ordinary file was selected")
	}
}
