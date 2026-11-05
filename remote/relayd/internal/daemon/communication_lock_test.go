package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"syscall"
	"testing"
	"time"
)

// errCommunicationLockFakeExhausted is returned when the code under test calls
// flock more often than the test injected outcomes for. It is not ENOLCK, so a
// loop that ignores its bound stops instead of hanging the test.
var errCommunicationLockFakeExhausted = errors.New("communication lock fake: no injected outcome left")

// communicationLockFake replaces the lock's system calls. Each LOCK_EX call
// takes the next injected outcome; LOCK_UN is counted and succeeds.
type communicationLockFake struct {
	outcomes  []error
	exclusive int
	unlocks   int
	pauses    []time.Duration
}

func useCommunicationLockFake(t *testing.T, outcomes ...error) *communicationLockFake {
	t.Helper()
	fake := &communicationLockFake{outcomes: outcomes}
	savedFlock, savedPause := communicationFlock, communicationLockPause
	communicationFlock = func(fd int, how int) error {
		switch how {
		case syscall.LOCK_EX:
			fake.exclusive++
			if fake.exclusive > len(fake.outcomes) {
				t.Errorf("flock LOCK_EX call %d exceeds the %d injected outcomes", fake.exclusive, len(fake.outcomes))
				return errCommunicationLockFakeExhausted
			}
			return fake.outcomes[fake.exclusive-1]
		case syscall.LOCK_UN:
			fake.unlocks++
			return nil
		}
		t.Errorf("unexpected flock operation %d", how)
		return syscall.EINVAL
	}
	communicationLockPause = func(d time.Duration) { fake.pauses = append(fake.pauses, d) }
	t.Cleanup(func() { communicationFlock, communicationLockPause = savedFlock, savedPause })
	return fake
}

func communicationLockHome(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_STATE_HOME", t.TempDir())
}

// communicationLockRoot creates a private root that already holds the given
// lock files, so a refused lock must leave it byte for byte unchanged.
func communicationLockRoot(t *testing.T, root string, locks ...string) {
	t.Helper()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range locks {
		f, err := OpenPrivateFile(filepath.Join(root, name), os.O_CREATE|os.O_RDWR)
		if err != nil {
			t.Fatal(err)
		}
		f.Close()
	}
}

func communicationLockEntries(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names
}

func communicationLockPolicy() *communicationPolicy {
	hash := sha256.Sum256([]byte("communication-lock-fixture-token"))
	return &communicationPolicy{Callers: []communicationCaller{{ID: "communication-lock-caller", Label: "ENOLCK fixture", TokenHash: hex.EncodeToString(hash[:])}}}
}

func requireCommunicationENOLCK(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("the lock was refused but the operation succeeded")
	}
	if err.Error() != "no locks available" || !errors.Is(err, syscall.ENOLCK) || err != error(syscall.ENOLCK) {
		t.Fatalf("refused lock returned %q (%T), want the unchanged ENOLCK error", err.Error(), err)
	}
}

var communicationLockRetryPauses = []time.Duration{100 * time.Millisecond, 200 * time.Millisecond}

// The lock is refused on every attempt: the request fails with the unchanged
// ENOLCK error after exactly three flock calls and writes nothing.
func TestCommunicationENOLCKFailsClosedNoWrites(t *testing.T) {
	communicationLockHome(t)
	root := communicationRoot()
	communicationLockRoot(t, root, "lock")
	before := treeState(t, root)
	fake := useCommunicationLockFake(t, syscall.ENOLCK, syscall.ENOLCK, syscall.ENOLCK)
	result, err := ExecuteCommunication(CommunicationRequest{Operation: "caller_policy_import", Policy: communicationLockPolicy()})
	requireCommunicationENOLCK(t, err)
	if result != nil {
		t.Fatalf("refused lock returned a result: %v", result)
	}
	if fake.exclusive != 3 || fake.unlocks != 0 || !reflect.DeepEqual(fake.pauses, communicationLockRetryPauses) {
		t.Fatalf("flock calls %d, unlocks %d, pauses %v; want 3, 0, %v", fake.exclusive, fake.unlocks, fake.pauses, communicationLockRetryPauses)
	}
	if _, err := os.Stat(communicationPolicyPath(root)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("caller policy written without the lock: %v", err)
	}
	if names := communicationLockEntries(t, root); !reflect.DeepEqual(names, []string{"lock"}) {
		t.Fatalf("root holds %v after a refused lock, want only lock", names)
	}
	if after := treeState(t, root); after != before {
		t.Fatalf("root changed under a refused lock:\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

// Positive control for the test above: the same request imports the policy
// when the lock is granted, so the no-write assertions are not vacuous.
func TestCommunicationLockGrantedImportsPolicy(t *testing.T) {
	communicationLockHome(t)
	root := communicationRoot()
	communicationLockRoot(t, root, "lock")
	fake := useCommunicationLockFake(t, nil)
	result, err := ExecuteCommunication(CommunicationRequest{Operation: "caller_policy_import", Policy: communicationLockPolicy()})
	if err != nil || result["status"] != "imported" {
		t.Fatalf("granted lock: %v %v", result, err)
	}
	var saved communicationPolicy
	if err := communicationRead(communicationPolicyPath(root), &saved); err != nil || !reflect.DeepEqual(saved, *communicationLockPolicy()) {
		t.Fatalf("imported policy %+v %v", saved, err)
	}
	if fake.exclusive != 1 || fake.unlocks != 1 || len(fake.pauses) != 0 {
		t.Fatalf("flock calls %d, unlocks %d, pauses %v; want 1, 1, none", fake.exclusive, fake.unlocks, fake.pauses)
	}
}

// Every exclusive communication lock site fails closed the same way.
func TestCommunicationENOLCKFailsClosedEverySite(t *testing.T) {
	for _, site := range []struct {
		name  string
		locks []string
		run   func(root string, fn func() error) error
	}{
		{"communicationFanoutLocked", []string{"lock"}, communicationFanoutLocked},
		{"withCommunicationRootLock", []string{"lock"}, withCommunicationRootLock},
		{"lockCommunicationRootForQuestions", []string{"lock", "question-state.lock"}, func(_ string, fn func() error) error {
			unlock, err := lockCommunicationRootForQuestions()
			if err != nil {
				if unlock != nil {
					return errors.New("a refused question lock returned an unlock function")
				}
				return err
			}
			defer unlock()
			return fn()
		}},
		{"communicationQuestionRequest", []string{"lock"}, func(_ string, fn func() error) error {
			result, err := ExecuteCommunication(CommunicationRequest{Operation: "question_bind"})
			if err != nil {
				if result != nil {
					return errors.New("a refused question request returned a result")
				}
				return err
			}
			return fn()
		}},
	} {
		t.Run(site.name, func(t *testing.T) {
			communicationLockHome(t)
			root := communicationRoot()
			communicationLockRoot(t, root, site.locks...)
			before := treeState(t, root)
			fake := useCommunicationLockFake(t, syscall.ENOLCK, syscall.ENOLCK, syscall.ENOLCK)
			ran := 0
			err := site.run(root, func() error {
				ran++
				return communicationAtomic(filepath.Join(root, "counter.json"), map[string]int{"n": ran})
			})
			requireCommunicationENOLCK(t, err)
			if ran != 0 {
				t.Fatalf("locked work ran %d times under a refused lock", ran)
			}
			if fake.exclusive != 3 || fake.unlocks != 0 || !reflect.DeepEqual(fake.pauses, communicationLockRetryPauses) {
				t.Fatalf("flock calls %d, unlocks %d, pauses %v; want 3, 0, %v", fake.exclusive, fake.unlocks, fake.pauses, communicationLockRetryPauses)
			}
			if names := communicationLockEntries(t, root); !reflect.DeepEqual(names, site.locks) {
				t.Fatalf("root holds %v after a refused lock, want %v", names, site.locks)
			}
			if after := treeState(t, root); after != before {
				t.Fatalf("root changed under a refused lock:\nbefore:\n%s\nafter:\n%s", before, after)
			}
		})
	}
}

// ENOLCK twice, then a granted lock: the request succeeds and writes once.
func TestCommunicationENOLCKTransientRecovers(t *testing.T) {
	t.Run("ExecuteCommunication", func(t *testing.T) {
		communicationLockHome(t)
		root := communicationRoot()
		communicationLockRoot(t, root, "lock")
		fake := useCommunicationLockFake(t, syscall.ENOLCK, syscall.ENOLCK, nil)
		result, err := ExecuteCommunication(CommunicationRequest{Operation: "caller_policy_import", Policy: communicationLockPolicy()})
		if err != nil || result["status"] != "imported" {
			t.Fatalf("transient ENOLCK was not recovered: %v %v", result, err)
		}
		var saved communicationPolicy
		if err := communicationRead(communicationPolicyPath(root), &saved); err != nil || !reflect.DeepEqual(saved, *communicationLockPolicy()) {
			t.Fatalf("imported policy %+v %v", saved, err)
		}
		if names := communicationLockEntries(t, root); !reflect.DeepEqual(names, []string{"caller-policy.json", "lock"}) {
			t.Fatalf("root holds %v, want caller-policy.json and lock", names)
		}
		if fake.exclusive != 3 || fake.unlocks != 1 || !reflect.DeepEqual(fake.pauses, communicationLockRetryPauses) {
			t.Fatalf("flock calls %d, unlocks %d, pauses %v; want 3, 1, %v", fake.exclusive, fake.unlocks, fake.pauses, communicationLockRetryPauses)
		}
	})
	t.Run("communicationFanoutLocked", func(t *testing.T) {
		communicationLockHome(t)
		root := communicationRoot()
		communicationLockRoot(t, root, "lock")
		fake := useCommunicationLockFake(t, syscall.ENOLCK, syscall.ENOLCK, nil)
		ran := 0
		err := communicationFanoutLocked(root, func() error {
			ran++
			return communicationAtomic(filepath.Join(root, "counter.json"), map[string]int{"n": ran})
		})
		if err != nil || ran != 1 {
			t.Fatalf("transient ENOLCK: err %v, locked work ran %d times, want once", err, ran)
		}
		var counter map[string]int
		if err := communicationRead(filepath.Join(root, "counter.json"), &counter); err != nil || counter["n"] != 1 {
			t.Fatalf("counter %v %v", counter, err)
		}
		if fake.exclusive != 3 || fake.unlocks != 1 || !reflect.DeepEqual(fake.pauses, communicationLockRetryPauses) {
			t.Fatalf("flock calls %d, unlocks %d, pauses %v; want 3, 1, %v", fake.exclusive, fake.unlocks, fake.pauses, communicationLockRetryPauses)
		}
	})
}

// Errors other than ENOLCK are returned unchanged after one call, as before.
func TestCommunicationLockNonENOLCKNotRetried(t *testing.T) {
	for _, injected := range []syscall.Errno{syscall.EBADF, syscall.EINTR, syscall.EACCES} {
		t.Run(injected.Error(), func(t *testing.T) {
			communicationLockHome(t)
			root := communicationRoot()
			communicationLockRoot(t, root, "lock")
			before := treeState(t, root)
			fake := useCommunicationLockFake(t, injected, nil, nil)
			ran := 0
			err := communicationFanoutLocked(root, func() error { ran++; return nil })
			if err != error(injected) || err.Error() != injected.Error() {
				t.Fatalf("got %v, want the unchanged %v", err, injected)
			}
			if fake.exclusive != 1 || fake.unlocks != 0 || len(fake.pauses) != 0 || ran != 0 {
				t.Fatalf("flock calls %d, unlocks %d, pauses %v, ran %d; want 1, 0, none, 0", fake.exclusive, fake.unlocks, fake.pauses, ran)
			}
			if after := treeState(t, root); after != before {
				t.Fatalf("root changed:\nbefore:\n%s\nafter:\n%s", before, after)
			}
		})
	}
}
