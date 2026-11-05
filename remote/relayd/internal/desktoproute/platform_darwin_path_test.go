//go:build darwin

package desktoproute

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestDarwinProcessPathRealSelf(t *testing.T) {
	want, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want, err = filepath.EvalSymlinks(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := inspectProcess(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if got.Executable != want {
		t.Fatalf("executable = %q, want %q", got.Executable, want)
	}
}

func TestDarwinProcessPathRejectsInvalid(t *testing.T) {
	for _, pid := range []int{0, -1} {
		if _, err := inspectProcess(pid); err == nil {
			t.Fatalf("accepted pid %d", pid)
		}
	}
	for _, tc := range []struct {
		data  []byte
		errno syscall.Errno
	}{
		{[]byte("/path\x00"), syscall.EPERM},
		{[]byte{0, 0}, 0},
		{[]byte("/no-terminator"), 0},
	} {
		if got, err := decodeDarwinProcessPath(tc.data, tc.errno); err == nil {
			t.Fatalf("accepted %q", got)
		}
	}
	if got, err := decodeDarwinProcessPath([]byte("/valid\x00garbage"), 0); err != nil || got != "/valid" {
		t.Fatalf("got %q, %v", got, err)
	}
}
