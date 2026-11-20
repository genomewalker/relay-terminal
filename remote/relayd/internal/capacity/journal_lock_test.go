package capacity

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"
)

// journalLockFake replaces the journal's flock: each LOCK_EX takes the next
// injected outcome; LOCK_UN is counted and succeeds.
type journalLockFake struct {
	outcomes  []error
	exclusive int
	unlocks   int
	pauses    []time.Duration
}

func useJournalLockFake(t *testing.T, outcomes ...error) *journalLockFake {
	t.Helper()
	fake := &journalLockFake{outcomes: outcomes}
	savedFlock, savedPause := journalFlock, journalLockPause
	journalFlock = func(fd int, how int) error {
		if how == syscall.LOCK_UN {
			fake.unlocks++
			return nil
		}
		fake.exclusive++
		if fake.exclusive > len(fake.outcomes) {
			t.Errorf("flock LOCK_EX call %d exceeds the %d injected outcomes", fake.exclusive, len(fake.outcomes))
			return errors.New("journal lock fake: no outcome left")
		}
		return fake.outcomes[fake.exclusive-1]
	}
	journalLockPause = func(d time.Duration) { fake.pauses = append(fake.pauses, d) }
	t.Cleanup(func() { journalFlock, journalLockPause = savedFlock, savedPause })
	return fake
}

// dandy-07, 2026-11-20: account moves were held with "capacity journal
// requires review: no locks available" from NFS lock emulation. A short
// ENOLCK now gets two more tries before the journal reports it.
func TestJournalLockRetriesENOLCKThenLoads(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "capacity")}
	fake := useJournalLockFake(t, syscall.ENOLCK, syscall.ENOLCK, nil)
	disk, err := j.Load()
	if err != nil {
		t.Fatalf("Load after two ENOLCK answers: %v", err)
	}
	if disk.Revision != Empty().Revision {
		t.Fatalf("revision %d, want the empty journal's", disk.Revision)
	}
	if fake.exclusive != 3 || fake.unlocks != 1 {
		t.Fatalf("flock calls: %d exclusive, %d unlocks; want 3 and 1", fake.exclusive, fake.unlocks)
	}
	if want := []time.Duration{100 * time.Millisecond, 200 * time.Millisecond}; !reflect.DeepEqual(fake.pauses, want) {
		t.Fatalf("pauses %v, want %v", fake.pauses, want)
	}
}

func TestJournalLockFailsClosedAfterThreeENOLCK(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "capacity")}
	fake := useJournalLockFake(t, syscall.ENOLCK, syscall.ENOLCK, syscall.ENOLCK)
	_, err := j.Load()
	if err != error(syscall.ENOLCK) || err.Error() != "no locks available" {
		t.Fatalf("Load returned %v (%T), want the unchanged ENOLCK", err, err)
	}
	if fake.exclusive != 3 || fake.unlocks != 0 {
		t.Fatalf("flock calls: %d exclusive, %d unlocks; want 3 and 0", fake.exclusive, fake.unlocks)
	}
	if _, statErr := os.Stat(filepath.Join(j.Root, "policy.jsonl")); !os.IsNotExist(statErr) {
		t.Fatalf("the journal was opened without its lock: %v", statErr)
	}
}

func TestJournalLockReturnsOtherErrorsAtOnce(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "capacity")}
	fake := useJournalLockFake(t, syscall.EIO)
	if _, err := j.Load(); err != error(syscall.EIO) {
		t.Fatalf("Load returned %v, want EIO", err)
	}
	if fake.exclusive != 1 || len(fake.pauses) != 0 {
		t.Fatalf("EIO was retried: %d calls, %d pauses", fake.exclusive, len(fake.pauses))
	}
}
