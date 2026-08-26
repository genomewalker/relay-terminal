package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveArtifactPathAllowsHomeImage(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, "generated.png")
	if err := os.WriteFile(path, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveArtifactPath(path, home, 501)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != want {
		t.Fatalf("got %q, want %q", resolved, want)
	}
}

func TestResolveArtifactPathRejectsEscapingSymlink(t *testing.T) {
	home := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret.png")
	if err := os.WriteFile(outside, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "linked.png")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveArtifactPath(link, home, 501); err == nil {
		t.Fatal("expected escaping symlink to be rejected")
	}
}

func TestResolveArtifactPathRejectsUnsupportedType(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, "notes.txt")
	if err := os.WriteFile(path, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveArtifactPath(path, home, 501); err == nil {
		t.Fatal("expected unsupported type to be rejected")
	}
}

func TestResolveArtifactPathAllowsRelativeCodexImage(t *testing.T) {
	home := t.TempDir()
	directory := filepath.Join(home, ".codex", "generated_images", "demo")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "image.png")
	if err := os.WriteFile(path, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}
	resolved, err := resolveArtifactPath(".codex/generated_images/demo/image.png", home, 501)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != want {
		t.Fatalf("got %q, want %q", resolved, want)
	}
}

func TestResolveArtifactPathRejectsOtherRelativePaths(t *testing.T) {
	if _, err := resolveArtifactPath(".ssh/id_rsa", t.TempDir(), 501); err == nil {
		t.Fatal("expected unrelated relative path to be rejected")
	}
}
