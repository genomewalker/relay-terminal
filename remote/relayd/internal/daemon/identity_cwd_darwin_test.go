//go:build darwin

package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDarwinProcessWorkingDirectory(t *testing.T) {
	want, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	want, err = filepath.EvalSymlinks(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := processWorkingDirectory(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("cwd mismatch: %q vs %q", got, want)
	}
	for _, pid := range []int{-1, 0, 1, 2147483647} {
		if _, err := processWorkingDirectory(pid); err == nil {
			t.Fatalf("accepted invalid process %d", pid)
		}
	}
}
