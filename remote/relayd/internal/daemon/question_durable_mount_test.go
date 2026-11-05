package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

// fakeMountChain makes root/a look like a mount point of another filesystem
// below root, as /home/kbd606 is below the autofs /home on dandy-07. It
// records each synced directory, and fails syncing or statting failAt.
func fakeMountChain(t *testing.T, mountRoot string, failSync, failStat string) *[]string {
	t.Helper()
	restoreSync, restoreDevice := questionJournalSync, durableDirectoryDevice
	t.Cleanup(func() { questionJournalSync, durableDirectoryDevice = restoreSync, restoreDevice })
	var synced []string
	questionJournalSync = func(file *os.File) error {
		synced = append(synced, file.Name())
		if file.Name() == failSync {
			return syscall.EIO
		}
		if !strings.HasPrefix(file.Name()+"/", mountRoot+"/") {
			return syscall.EINVAL // like the autofs /home: must never be reached
		}
		return file.Sync()
	}
	durableDirectoryDevice = func(path string) (uint64, error) {
		if path == failStat {
			return 0, syscall.EACCES
		}
		if strings.HasPrefix(path+"/", mountRoot+"/") {
			return 2, nil
		}
		return 1, nil
	}
	return &synced
}

// realTempDir is t.TempDir with symlinks resolved (/var is /private/var on
// macOS), since durableDirectory works on real paths.
func realTempDir(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func TestDurableDirectorySyncsOnlyUpToTheMountRoot(t *testing.T) {
	root := realTempDir(t)
	mount := filepath.Join(root, "mount")
	target := filepath.Join(mount, "state", "relay", "workers", "host-jobs-tombstones")
	synced := fakeMountChain(t, mount, "", "")
	if err := durableDirectory(target); err != nil {
		t.Fatalf("durableDirectory across a mount: %v", err)
	}
	want := []string{mount, filepath.Join(mount, "state"), filepath.Join(mount, "state", "relay"),
		filepath.Join(mount, "state", "relay", "workers"), target}
	if !slices.Equal(*synced, want) {
		t.Fatalf("synced %v, want %v", *synced, want)
	}
}

func TestDurableDirectoryErrorsInsideTheChainStillFail(t *testing.T) {
	root := realTempDir(t)
	mount := filepath.Join(root, "mount")
	target := filepath.Join(mount, "state", "workers")
	t.Run("sync of the mount root", func(t *testing.T) {
		fakeMountChain(t, mount, mount, "")
		if err := durableDirectory(target); !errors.Is(err, syscall.EIO) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("sync of an intermediate directory", func(t *testing.T) {
		fakeMountChain(t, mount, filepath.Join(mount, "state"), "")
		if err := durableDirectory(target); !errors.Is(err, syscall.EIO) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("stat of an ancestor up to the boundary", func(t *testing.T) {
		fakeMountChain(t, mount, "", filepath.Join(mount, "state"))
		if err := durableDirectory(target); !errors.Is(err, syscall.EACCES) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("stat of the mount root's parent", func(t *testing.T) {
		// Deciding where the chain ends needs the parent's device too.
		fakeMountChain(t, mount, "", root)
		if err := durableDirectory(target); !errors.Is(err, syscall.EACCES) {
			t.Fatalf("got %v", err)
		}
	})
}

// With no mount boundary the whole chain to "/" is synced, as before.
func TestDurableDirectoryWithoutAMountSyncsToTheRoot(t *testing.T) {
	target := filepath.Join(realTempDir(t), "a", "b")
	restoreSync, restoreDevice := questionJournalSync, durableDirectoryDevice
	defer func() { questionJournalSync, durableDirectoryDevice = restoreSync, restoreDevice }()
	var synced []string
	questionJournalSync = func(file *os.File) error { synced = append(synced, file.Name()); return nil }
	durableDirectoryDevice = func(string) (uint64, error) { return 7, nil }
	if err := durableDirectory(target); err != nil {
		t.Fatal(err)
	}
	if len(synced) == 0 || synced[0] != "/" || synced[len(synced)-1] != target {
		t.Fatalf("synced %v", synced)
	}
}

// The real device lookup ends the chain at a real mount root.
func TestDurableDirectoryRealDeviceChainEndsAtAMountRoot(t *testing.T) {
	restore := questionJournalSync
	defer func() { questionJournalSync = restore }()
	var synced []string
	questionJournalSync = func(file *os.File) error { synced = append(synced, file.Name()); return file.Sync() }
	target := filepath.Join(realTempDir(t), "x")
	if err := durableDirectory(target); err != nil {
		t.Fatal(err)
	}
	top := synced[0]
	topDevice, err := durableDirectoryDevice(top)
	if err != nil {
		t.Fatal(err)
	}
	targetDevice, _ := durableDirectoryDevice(target)
	if topDevice != targetDevice {
		t.Fatalf("chain top %s is on another filesystem", top)
	}
	if parent := filepath.Dir(top); parent != top {
		if parentDevice, _ := durableDirectoryDevice(parent); parentDevice == targetDevice {
			t.Fatalf("chain stopped at %s before its mount root", top)
		}
	}
}

// A state directory reached through a symlink on another filesystem syncs
// the real directory's chain, up to its own mount root, never the alias's.
func TestDurableDirectoryFollowsASymlinkedStateDirToItsRealMount(t *testing.T) {
	root := realTempDir(t)
	dataMount := filepath.Join(root, "data")
	state := filepath.Join(dataMount, "state")
	local := filepath.Join(root, "local")
	for _, directory := range []string{state, local} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	alias := filepath.Join(local, "state")
	if err := os.Symlink(state, alias); err != nil {
		t.Fatal(err)
	}
	synced := fakeMountChain(t, dataMount, "", "")
	if err := durableDirectory(filepath.Join(alias, "host-jobs-tombstones")); err != nil {
		t.Fatal(err)
	}
	want := []string{dataMount, state, filepath.Join(state, "host-jobs-tombstones")}
	if !slices.Equal(*synced, want) {
		t.Fatalf("synced %v, want %v", *synced, want)
	}
}

// A symlink retargeted while the chain is synced fails closed.
func TestDurableDirectoryFailsWhenAComponentChangesDuringTheWalk(t *testing.T) {
	root := realTempDir(t)
	first, second := filepath.Join(root, "first"), filepath.Join(root, "second")
	for _, directory := range []string{filepath.Join(first, "ledger"), filepath.Join(second, "ledger")} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	alias := filepath.Join(root, "state")
	if err := os.Symlink(first, alias); err != nil {
		t.Fatal(err)
	}
	restore := questionJournalSync
	defer func() { questionJournalSync = restore }()
	swapped := false
	questionJournalSync = func(file *os.File) error {
		if !swapped {
			swapped = true
			if err := os.Remove(alias); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(second, alias); err != nil {
				t.Fatal(err)
			}
		}
		return file.Sync()
	}
	if err := durableDirectory(filepath.Join(alias, "ledger")); err == nil || !strings.Contains(err.Error(), "changed while it was synced") {
		t.Fatalf("a retargeted state directory was accepted: %v", err)
	}
}
