package providersetup

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPrivateNoFollowAndBounds(t *testing.T) {
	for _, kind := range []string{"final-symlink", "parent-symlink", "backup-symlink", "public-backup", "fifo", "oversize"} {
		t.Run(kind, func(t *testing.T) {
			home, s := fixture(t)
			external := t.TempDir()
			write(t, external, "sentinel", []byte("outside"))
			path := ".config/relay/asset"
			oldRaw := []byte("original")
			switch kind {
			case "final-symlink":
				write(t, home, ".config/relay/stub", nil)
				if e := os.Symlink(filepath.Join(external, "sentinel"), filepath.Join(home, path)); e != nil {
					t.Fatal(e)
				}
			case "parent-symlink":
				if e := os.Mkdir(filepath.Join(home, ".config"), 0700); e != nil {
					t.Fatal(e)
				}
				if e := os.Symlink(external, filepath.Join(home, ".config/relay")); e != nil {
					t.Fatal(e)
				}
			case "backup-symlink":
				write(t, home, path, oldRaw)
				if e := os.Symlink(external, filepath.Join(home, ".config/relay/backups")); e != nil {
					t.Fatal(e)
				}
			case "public-backup":
				write(t, home, path, oldRaw)
				if e := os.Mkdir(filepath.Join(home, ".config/relay/backups"), 0755); e != nil {
					t.Fatal(e)
				}
			case "fifo":
				write(t, home, ".config/relay/stub", nil)
				if e := makeFIFO(filepath.Join(home, path)); e != nil {
					t.Fatal(e)
				}
			case "oversize":
				write(t, home, path, bytes.Repeat([]byte("x"), FileLimit+1))
			}
			if e := s.put(path, []byte("updated"), 0600); e == nil {
				t.Fatalf("unsafe %s accepted", kind)
			}
			if string(read(t, external, "sentinel")) != "outside" {
				t.Fatal("escaped root")
			}
		})
	}
}
func TestCASRejectsEveryScheduledExternalChange(t *testing.T) {
	for _, initial := range []bool{false, true} {
		for _, mutation := range []string{"write", "replace", "symlink", "remove"} {
			t.Run(fmt.Sprintf("%t-%s", initial, mutation), func(t *testing.T) {
				home, s := fixture(t)
				path := ".config/relay/asset"
				if initial {
					write(t, home, path, []byte("original"))
				}
				old, e := s.read(path)
				if e != nil {
					t.Fatal(e)
				}
				var external []byte
				s.beforeCommit = func(p string) {
					if p != path {
						t.Fatal("unexpected path")
					}
					full := filepath.Join(home, path)
					switch mutation {
					case "write":
						write(t, home, path, []byte("external"))
						external = []byte("external")
					case "replace":
						_ = os.Remove(full)
						write(t, home, path, []byte("replacement"))
						external = []byte("replacement")
					case "symlink":
						_ = os.Remove(full)
						if e := os.Symlink("does-not-exist", full); e != nil {
							t.Fatal(e)
						}
					case "remove":
						_ = os.Remove(full)
					}
				}
				e = s.replace(path, []byte("native"), old, 0600, "")
				// Removing an already absent target is not a mutation; all other actual
				// changes must refuse and must leave the external writer's state intact.
				changed := initial || mutation != "remove"
				if changed && e == nil {
					t.Fatal("CAS accepted external change")
				}
				if !changed && e != nil {
					t.Fatal(e)
				}
				if external != nil && !bytes.Equal(read(t, home, path), external) {
					t.Fatal("lost external write")
				}
				if changed && mutation == "remove" {
					if _, e := os.Lstat(filepath.Join(home, path)); !os.IsNotExist(e) {
						t.Fatal("resurrected removed file")
					}
				}
				if mutation == "symlink" {
					info, e := os.Lstat(filepath.Join(home, path))
					if e != nil || info.Mode()&os.ModeSymlink == 0 {
						t.Fatal("replaced external symlink")
					}
				}
			})
		}
	}
}
func TestAllSettingsExternalWriteSchedules(t *testing.T) {
	// Every order of two actors' read/commit events with each actor's read before
	// its commit. Both actors use the real snapshot and replacement code.
	schedules := [][]string{{"ar", "ac", "br", "bc"}, {"ar", "br", "ac", "bc"}, {"ar", "br", "bc", "ac"}, {"br", "bc", "ar", "ac"}, {"br", "ar", "bc", "ac"}, {"br", "ar", "ac", "bc"}}
	transitions := 0
	for i, events := range schedules {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			home, s := fixture(t)
			path := ".config/relay/state"
			write(t, home, path, []byte("initial"))
			snaps := map[byte]*snapshot{}
			success := map[byte]bool{}
			last := "initial"
			for _, event := range events {
				actor := event[0]
				if event[1] == 'r' {
					old, e := s.read(path)
					if e != nil {
						t.Fatal(e)
					}
					snaps[actor] = old
				} else {
					e := s.replace(path, []byte{actor}, snaps[actor], 0600, "")
					if e == nil {
						success[actor] = true
						last = string(actor)
					} else if success[actor] {
						t.Fatal("actor unexpectedly repeated")
					}
				}
				if string(read(t, home, path)) != last {
					t.Fatal("write escaped admitted CAS history")
				}
				transitions++
			}
			overlapping := events[1][1] == 'r'
			if overlapping && len(success) != 1 {
				t.Fatalf("stale commit admitted: %v", success)
			}
			if !overlapping && len(success) != 2 {
				t.Fatal("serial updates failed")
			}
		})
	}
	if transitions != 24 {
		t.Fatal("interleaving bound changed")
	}
	t.Log("all 6 two-actor read/commit interleavings; 24 checked transitions")
}
func TestBoundedOwnershipAndInstallState(t *testing.T) {
	// Enumerate a small real-store operation set, including every two-actor
	// interleaving. Every prefix checks: no outside mutation; symlink never
	// followed; failed replacements never install native bytes; backups private.
	ops := []string{"a-install", "b-install", "external-write", "external-link"}
	sequences := 0
	transitions := 0
	states := map[string]bool{}
	const depth = 3
	for code := 0; code < 64; code++ {
		home, s := fixture(t)
		outside := t.TempDir()
		write(t, outside, "sentinel", []byte("outside"))
		path := ".config/relay/asset"
		n := code
		for step := 0; step < depth; step++ {
			op := ops[n%len(ops)]
			n /= len(ops)
			full := filepath.Join(home, path)
			switch op {
			case "a-install", "b-install":
				before, e := os.Lstat(full)
				wasLink := e == nil && before.Mode()&os.ModeSymlink != 0
				err := s.put(path, []byte(op), 0600)
				if wasLink && err == nil {
					t.Fatal("symlink installed")
				}
			case "external-write":
				_ = os.Remove(full)
				write(t, home, path, []byte("external"))
			case "external-link":
				if e := os.MkdirAll(filepath.Dir(full), 0700); e != nil {
					t.Fatal(e)
				}
				_ = os.Remove(full)
				if e := os.Symlink(filepath.Join(outside, "sentinel"), full); e != nil {
					t.Fatal(e)
				}
			}
			if string(read(t, outside, "sentinel")) != "outside" {
				t.Fatal("path escaped owned root")
			}
			privateBackups(t, home)
			info, e := os.Lstat(full)
			state := "absent"
			if e == nil {
				if info.Mode()&os.ModeSymlink != 0 {
					state = "link"
				} else {
					state = string(read(t, home, path))
				}
			}
			states[state] = true
			transitions++
		}
		sequences++
	}
	if sequences != 64 || transitions != 192 || len(states) != 4 {
		t.Fatalf("bound/states changed %d/%d/%d", sequences, transitions, len(states))
	}
	t.Logf("depth %d, %d histories, %d transitions, %d observed states; real open/read/replace", depth, sequences, transitions, len(states))
}
func TestCooperatingInstallerLock(t *testing.T) {
	home, s := fixture(t)
	other, e := Open(home)
	if e != nil {
		t.Fatal(e)
	}
	defer other.Close()
	entered := make(chan struct{})
	release := make(chan struct{})
	second := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if e := s.locked(func() error { close(entered); <-release; return nil }); e != nil {
			t.Error(e)
		}
	}()
	<-entered
	go func() {
		defer wg.Done()
		if e := other.locked(func() error { close(second); return nil }); e != nil {
			t.Error(e)
		}
	}()
	select {
	case <-second:
		t.Fatal("concurrent installer entered held lock")
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	select {
	case <-second:
	case <-time.After(3 * time.Second):
		t.Fatal("installer did not acquire released lock")
	}
	wg.Wait()
}
func TestPrivatePathGrammar(t *testing.T) {
	for _, p := range []string{"", "/abs", "../escape", "a/../b", "a//b", "./a", "a/./b", "a\x00b"} {
		if _, e := parts(p); e == nil {
			t.Fatalf("unsafe path %q", p)
		}
	}
	if _, e := parts(strings.Repeat("x", 4097)); e == nil {
		t.Fatal("oversized path")
	}
}

func TestInstallLockRefusesUnsafeFile(t *testing.T) {
	for _, kind := range []string{"symlink", "public", "fifo"} {
		t.Run(kind, func(t *testing.T) {
			home, s := fixture(t)
			path := ".config/relay/provider-setup.lock"
			write(t, home, ".config/relay/stub", nil)
			switch kind {
			case "symlink":
				outside := t.TempDir()
				write(t, outside, "sentinel", []byte("outside"))
				if e := os.Symlink(filepath.Join(outside, "sentinel"), filepath.Join(home, path)); e != nil {
					t.Fatal(e)
				}
			case "public":
				write(t, home, path, nil)
				if e := os.Chmod(filepath.Join(home, path), 0644); e != nil {
					t.Fatal(e)
				}
			case "fifo":
				if e := makeFIFO(filepath.Join(home, path)); e != nil {
					t.Fatal(e)
				}
			}
			called := false
			if e := s.locked(func() error { called = true; return nil }); e == nil || called {
				t.Fatal("unsafe lock admitted installer")
			}
		})
	}
}

func TestRepairRefusesConcurrentChange(t *testing.T) {
	home, s := fixture(t)
	raw := []byte("header\n" + anchor)
	write(t, home, adapterPath, raw)
	s.beforeCommit = func(path string) {
		if path == adapterPath {
			write(t, home, adapterPath, []byte("external plugin update"))
		}
	}
	if _, e := s.Repair(); e == nil {
		t.Fatal("repair overwrote a concurrently changed adapter")
	}
	if string(read(t, home, adapterPath)) != "external plugin update" {
		t.Fatal("lost concurrent plugin update")
	}
	if !bytes.Equal(read(t, home, ".config/relay/backups/chitta-failure-event-20261004/hook_client-"+hash(raw)+".py"), raw) {
		t.Fatal("pre-race adapter backup lost")
	}
}
