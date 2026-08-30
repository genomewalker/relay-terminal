package terminfo

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestEnsureUserIsContentHashedAndIdempotent(t *testing.T) {
	home := t.TempDir()
	first, err := EnsureUser(home)
	if err != nil {
		t.Fatal(err)
	}
	if !first.Installed || !first.Updated || first.Hash != ContentHash() {
		t.Fatalf("first status = %#v", first)
	}
	want, err := os.ReadFile(first.Path)
	if err != nil {
		t.Fatal(err)
	}
	for _, directory := range entryDirectories {
		installed, readErr := os.ReadFile(filepath.Join(home, ".terminfo", directory, Name))
		if readErr != nil || string(installed) != string(want) {
			t.Fatalf("entry layout %q was not installed consistently: %v", directory, readErr)
		}
	}
	second, err := EnsureUser(home)
	if err != nil {
		t.Fatal(err)
	}
	if second.Updated {
		t.Fatalf("second install rewrote unchanged content: %#v", second)
	}
	got, err := os.ReadFile(second.Path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatal("installed entry changed during idempotent check")
	}
	stamp, err := os.ReadFile(filepath.Join(home, ".local", "share", "relay", "terminfo", Name+".sha256"))
	if err != nil {
		t.Fatal(err)
	}
	if string(stamp) != ContentHash()+"\n" {
		t.Fatalf("hash stamp = %q", stamp)
	}
}

func TestEnsureUserReplacesStaleEntry(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, ".terminfo", entryDirectories[0], Name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	status, err := EnsureUser(home)
	if err != nil {
		t.Fatal(err)
	}
	if !status.Updated {
		t.Fatalf("stale entry was not updated: %#v", status)
	}
}

func TestPreferredEnvironmentFallsBackWhenStatusIsNotResolvable(t *testing.T) {
	currentOnce = sync.Once{}
	currentStatus = Status{}
	currentError = nil
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", "")
	environment := PreferredEnvironment()
	if environment["TERM"] != FallbackName || environment["TERMINFO"] != "" {
		t.Fatalf("environment = %#v", environment)
	}
}
