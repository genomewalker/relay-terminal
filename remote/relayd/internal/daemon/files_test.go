package daemon

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestEditorFileRoundTripAndConflict(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "main.go")
	if err := os.WriteFile(path, []byte("package main\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	document, err := ReadEditorFile(path)
	if err != nil {
		t.Fatal(err)
	}
	decoded, _ := base64.StdEncoding.DecodeString(document.ContentBase64)
	if string(decoded) != "package main\n" {
		t.Fatalf("unexpected content %q", decoded)
	}
	written, err := WriteEditorFile(path, document.ModificationNS, bytes.NewBufferString("package relay\n"))
	if err != nil {
		t.Fatal(err)
	}
	if written.ModificationNS == 0 {
		t.Fatal("saved document is missing its timestamp")
	}
	if _, err := WriteEditorFile(path, document.ModificationNS, bytes.NewBufferString("stale")); err == nil {
		t.Fatal("stale editor write was accepted")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("save changed mode to %o", info.Mode().Perm())
	}
}

func TestDirectoryListingSortsFoldersFirst(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "a.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(directory, "z-folder"), 0o700); err != nil {
		t.Fatal(err)
	}
	entries, err := ListDirectory(directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || !entries[0].Directory || entries[1].Directory {
		t.Fatalf("directories were not sorted first: %#v", entries)
	}
}

func TestDecodePath(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("/tmp/project"))
	path, err := DecodePath(encoded)
	if err != nil || path != "/tmp/project" {
		t.Fatalf("decoded %q with error %v", path, err)
	}
}

func TestImportFileAvoidsOverwriteAndBoundsInput(t *testing.T) {
	directory := t.TempDir()
	first, err := ImportFile(directory, "notes.txt", bytes.NewBufferString("first"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := ImportFile(directory, "notes.txt", bytes.NewBufferString("second"))
	if err != nil {
		t.Fatal(err)
	}
	if first.Path == second.Path || filepath.Base(second.Path) != "notes-2.txt" {
		t.Fatalf("repeated import overwrote its destination: %#v %#v", first, second)
	}
	firstData, _ := os.ReadFile(first.Path)
	secondData, _ := os.ReadFile(second.Path)
	if string(firstData) != "first" || string(secondData) != "second" {
		t.Fatalf("unexpected imported contents %q %q", firstData, secondData)
	}
	if _, err := ImportFile(directory, "../escape.txt", bytes.NewBuffer(nil)); err == nil {
		t.Fatal("path traversal filename was accepted")
	}
}
