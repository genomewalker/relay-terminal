package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestStockCodexIgnoresOldManagedBundle(t *testing.T) {
	home := t.TempDir()
	shim := filepath.Join(home, ".local", "share", "relay", "shims")
	stockDir := filepath.Join(home, "stock")
	legacy := filepath.Join(home, ".local", "share", "relay", "native-codex")
	for _, path := range []string{shim, stockDir, legacy} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range []string{filepath.Join(shim, "codex"), filepath.Join(legacy, "codex"), filepath.Join(stockDir, "codex")} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(legacy, "installed.json"), []byte("old native bundle"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("PATH", shim+string(os.PathListSeparator)+stockDir)
	t.Setenv("RELAY_CODEX_BIN", "")
	got, err := resolveStockCodexExecutable()
	if err != nil || got != filepath.Join(stockDir, "codex") {
		t.Fatalf("stock selection: %q %v", got, err)
	}
}

func TestStockCodexRemovesRetiredNativeEnvironment(t *testing.T) {
	got := stockCodexEnvironment([]string{"PATH=/stock", "RELAY_NATIVE_MESSAGES=1", "CODEX_HOME=/private", "RELAY_NATIVE_ROTATION_HELPER=/old"})
	want := []string{"PATH=/stock", "CODEX_HOME=/private"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}
