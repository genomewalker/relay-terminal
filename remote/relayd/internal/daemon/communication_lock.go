package daemon

import (
	"errors"
	"os"
	"syscall"
	"time"
)

// communicationFlock and communicationLockPause are the lock's system calls;
// tests replace them.
var communicationFlock = syscall.Flock
var communicationLockPause = time.Sleep

// communicationLockAttempts bounds the exclusive flock calls for one lock. On
// NFSv3 the kernel emulates flock through NLM, which can answer ENOLCK while
// lockd is briefly unavailable. ENOLCK means no lock was granted, and every
// caller takes the lock before it reads or writes any record, so only the
// flock call itself is retried.
const communicationLockAttempts = 3

// communicationLockExclusive takes the exclusive communication lock on f. Only
// ENOLCK is retried, after a fixed pause of 100 ms times the attempt number.
// After the last attempt the ENOLCK error is returned unchanged. Every other
// error is returned at once, as before.
func communicationLockExclusive(f *os.File) error {
	fd := int(f.Fd())
	for attempt := 1; ; attempt++ {
		err := communicationFlock(fd, syscall.LOCK_EX)
		if err == nil || !errors.Is(err, syscall.ENOLCK) {
			return err
		}
		if attempt == communicationLockAttempts {
			return err
		}
		communicationLockPause(time.Duration(attempt) * 100 * time.Millisecond)
	}
}

// communicationUnlock releases a lock taken by communicationLockExclusive.
func communicationUnlock(f *os.File) {
	_ = communicationFlock(int(f.Fd()), syscall.LOCK_UN)
}
