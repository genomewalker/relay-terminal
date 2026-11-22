package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/capacity"
)

// holdCapacityLock takes policy.lock exclusively through its own open file, so
// any journal call that locks blocks until release is called.
func holdCapacityLock(t *testing.T, directory string) (release func()) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(directory, "policy.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }
}

// revokeWhileLocked runs capacityRevokeHumanInput while the test holds the
// lock and reports whether it returned before the lock was released.
func revokeWhileLocked(t *testing.T, root, pane string) (returnedWhileLocked bool, err error) {
	t.Helper()
	release := holdCapacityLock(t, filepath.Join(root, "capacity"))
	done := make(chan error, 1)
	go func() { done <- capacityRevokeHumanInput(root, pane) }()
	select {
	case err = <-done:
		release()
		return true, err
	case <-time.After(300 * time.Millisecond):
	}
	release()
	select {
	case err = <-done:
		return false, err
	case <-time.After(10 * time.Second):
		t.Fatal("HUMAN_INPUT_NEVER_RETURNED")
	}
	return false, nil
}

func unmanagedCapacityEntry(pane string) capacity.Entry {
	source := capacitySourceFixture()
	source.Pane = pane
	return capacity.NewEntry(source, capacity.Settings{}, false, false)
}

func enrollCapacityPanes(t *testing.T, root string, entries map[string]capacity.Entry) capacity.Journal {
	t.Helper()
	j := capacity.Journal{Root: filepath.Join(root, "capacity")}
	if _, err := j.Update("setup", capacity.Hash([]byte("setup")), 0, func(d *capacity.Disk) error {
		for pane, e := range entries {
			d.Entries[pane] = e
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return j
}

func TestCapacityHumanInputSkipsLockForUnmanagedPanes(t *testing.T) {
	root := t.TempDir()
	managed := capacity.Entry{Managed: true, Source: capacitySourceFixture(), Enabled: true, Baseline: 56000, BaselineTurn: 1}
	unmanaged := unmanagedCapacityEntry("plain")
	j := enrollCapacityPanes(t, root, map[string]capacity.Entry{"pane": managed, "plain": unmanaged})
	before, err := j.Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, pane := range []string{"plain", "absent"} {
		fast, err := revokeWhileLocked(t, root, pane)
		if !fast || err != nil {
			t.Fatalf("%s: returned while locked=%v err=%v; want no lock", pane, fast, err)
		}
	}
	if d, err := j.Load(); err != nil || d.Revision != before.Revision {
		t.Fatal("UNMANAGED_INPUT_WROTE_JOURNAL", err)
	}

	// A managed pane still waits for the lock and records the takeover.
	fast, err := revokeWhileLocked(t, root, "pane")
	if fast || err != nil {
		t.Fatalf("managed pane: returned while locked=%v err=%v; want locked path", fast, err)
	}
	d, err := j.Load()
	if err != nil || !d.Entries["pane"].Takeover || d.Entries["pane"].Enabled || d.Revision != before.Revision+1 {
		t.Fatal("MANAGED_INPUT_DID_NOT_REVOKE", d, err)
	}
	// Once taken over, later input no longer takes the lock.
	if fast, err = revokeWhileLocked(t, root, "pane"); !fast || err != nil {
		t.Fatalf("taken-over pane: returned while locked=%v err=%v; want no lock", fast, err)
	}
}

func TestCapacityHumanInputUnreadableJournalTakesTheLock(t *testing.T) {
	root := t.TempDir()
	j := enrollCapacityPanes(t, root, map[string]capacity.Entry{
		"pane":  {Managed: true, Source: capacitySourceFixture(), Enabled: true, Baseline: 56000, BaselineTurn: 1},
		"plain": unmanagedCapacityEntry("plain"),
	})
	// A torn tail (no final newline) makes the unlocked read fail.
	f, err := os.OpenFile(filepath.Join(j.Root, "policy.jsonl"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.WriteString(`{"partial":`); err != nil {
		t.Fatal(err)
	}
	f.Close()
	fast, err := revokeWhileLocked(t, root, "plain")
	if fast {
		t.Fatal("TORN_JOURNAL_SKIPPED_THE_LOCK")
	}
	if err == nil || !strings.Contains(err.Error(), "partial") {
		t.Fatalf("locked path should report the torn journal, got %v", err)
	}
}

func TestCapacityHumanInputWithoutJournalIsANoOp(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "capacity"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := capacityRevokeHumanInput(root, "pane"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "capacity", "policy.lock")); !os.IsNotExist(err) {
		t.Fatal("NO_JOURNAL_INPUT_TOOK_THE_LOCK", err)
	}
}
