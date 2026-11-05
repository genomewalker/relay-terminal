package providersetup

import (
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"testing"
)

func makeFIFO(path string) error { return unix.Mkfifo(path, 0600) }
func TestExhaustiveOwnedRegularPolicy(t *testing.T) {
	configurations := 0
	for _, kind := range []uint32{unix.S_IFREG, unix.S_IFDIR, unix.S_IFLNK, unix.S_IFIFO, unix.S_IFSOCK, unix.S_IFCHR, unix.S_IFBLK} {
		for _, uid := range []uint32{17, 18} {
			for _, perm := range []uint32{0, 0600, 0640, 0644, 0700, 0755, 0777, 04700} {
				got := ownedRegular(kind|perm, uid, 17)
				want := kind == unix.S_IFREG && uid == 17
				if got != want {
					t.Fatalf("ownership/type policy kind=%o uid=%d mode=%o", kind, uid, perm)
				}
				configurations++
			}
		}
	}
	if configurations != 112 {
		t.Fatal("ownership policy bound changed")
	}
	t.Log("112 real ownership predicate configurations, both accepted/refused")
}

func TestRepairExactModeIgnoresUmask(t *testing.T) {
	previous := unix.Umask(0077)
	defer unix.Umask(previous)
	for _, mode := range []uint32{0640, 0660, 0670, 04750, 01700} {
		home, s := fixture(t)
		write(t, home, adapterPath, []byte(anchor))
		if e := unix.Chmod(filepath.Join(home, adapterPath), mode); e != nil {
			t.Fatal(e)
		}
		if _, e := s.Repair(); e != nil {
			t.Fatal(e)
		}
		var st unix.Stat_t
		if e := unix.Stat(filepath.Join(home, adapterPath), &st); e != nil {
			t.Fatal(e)
		}
		if uint32(st.Mode)&07777 != mode {
			t.Fatalf("adapter mode changed: got %o want %o with umask 077", uint32(st.Mode)&07777, mode)
		}
		for _, path := range []string{".config/relay/backups/chitta-failure-event-20261004/hook_client-" + hash([]byte(anchor)) + ".py"} {
			info, e := os.Stat(filepath.Join(home, path))
			if e != nil || info.Mode().Perm() != 0600 {
				t.Fatal("private backup must ignore restrictive umask")
			}
		}
	}
}
