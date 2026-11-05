//go:build linux

package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func forceFakeLinuxProc(t *testing.T, argv []byte) (string, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "456")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	fields := make([]string, 20)
	for i := range fields {
		fields[i] = "0"
	}
	fields[0], fields[1], fields[19] = "S", "123", "987"
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte("456 (strange ) name) "+strings.Join(fields, " ")+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cmdline"), argv, 0600); err != nil {
		t.Fatal(err)
	}
	return root, dir
}

func TestForceLinuxExactArgvAndIdentity(t *testing.T) {
	root, _ := forceFakeLinuxProc(t, []byte{'a', 0, 'b', 0, 0})
	p, err := forceLinuxReadProcess(root, 456)
	if err != nil || p.Parent != 123 || p.Start != "987" || !reflect.DeepEqual(p.Argv, []string{"a", "b", ""}) {
		t.Fatalf("unexpected process snapshot: %#v %v", p, err)
	}
}

func TestForceLinuxRejectsIncompleteOrInvalidArgv(t *testing.T) {
	for _, argv := range [][]byte{nil, {'a'}, {0xff, 0}, []byte(strings.Repeat("a", 65536) + "\x00")} {
		root, _ := forceFakeLinuxProc(t, argv)
		if _, err := forceLinuxReadProcess(root, 456); err == nil {
			t.Fatal("bad argv accepted")
		}
	}
}

func TestForceLinuxRejectsSymlinkProcessDirectory(t *testing.T) {
	root, dir := forceFakeLinuxProc(t, []byte{'a', 0})
	if err := os.Symlink(dir, filepath.Join(root, "457")); err != nil {
		t.Fatal(err)
	}
	if _, err := forceLinuxReadProcess(root, 457); err == nil {
		t.Fatal("symlink process directory accepted")
	}
}

func TestForceLinuxReadsOwnLiveProcess(t *testing.T) {
	p, err := forceLinuxReadProcess("/proc", os.Getpid())
	if err != nil || p.Parent <= 1 || p.Start == "" || len(p.Argv) == 0 {
		t.Fatal(fmt.Sprintf("live process read failed: %v", err))
	}
}
