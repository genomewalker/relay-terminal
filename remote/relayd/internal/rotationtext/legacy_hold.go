package rotationtext

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"syscall"
)

// While a ledger is open it holds sqlite's SHARED lock on the legacy
// operations.sqlite3, so a relayd that still writes the legacy journal (an
// older version running beside this one) gets SQLITE_BUSY instead of
// committing usage the ledger never sees. Its readers are not blocked.
//
// POSIX record locks belong to the process and are all dropped when any of
// its descriptors for the file is closed, so the process keeps one descriptor
// per file, shared by every open ledger, and reads the file only through it.
// The registry mutex guards only the map: no one waits for a lock while
// holding it, so ledgers in other roots never wait on each other.
var legacyHolds = struct {
	sync.Mutex
	files map[legacyKey]*legacyHold
}{files: map[legacyKey]*legacyHold{}}

type legacyKey struct{ dev, ino uint64 }

type legacyHold struct {
	key   legacyKey
	file  *os.File
	refs  int
	ready chan struct{} // closed once the opener has the lock, or gave up
}

// holdLegacyJournal takes (or shares) the SHARED lock on path; nil when there
// is no legacy journal.
func holdLegacyJournal(ctx context.Context, path string) (*legacyHold, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		hold, pending, err := takeLegacyJournal(ctx, path)
		if pending == nil {
			return hold, err
		}
		// Another ledger of this process is taking the lock on this file:
		// wait for it, until this ledger's own context ends, then look again.
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-pending:
		}
	}
}

// takeLegacyJournal shares a held lock, or takes it; pending is non-nil when
// another opener is taking it.
func takeLegacyJournal(ctx context.Context, path string) (hold *legacyHold, pending chan struct{}, err error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	if err := safeJournalInfo(info, false); err != nil {
		return nil, nil, err
	}
	stat := info.Sys().(*syscall.Stat_t)
	key := legacyKey{uint64(stat.Dev), uint64(stat.Ino)}
	legacyHolds.Lock()
	if hold := legacyHolds.files[key]; hold != nil {
		if hold.file == nil {
			legacyHolds.Unlock()
			return nil, hold.ready, nil
		}
		hold.refs++
		legacyHolds.Unlock()
		return hold, nil, nil
	}
	hold = &legacyHold{key: key, ready: make(chan struct{})}
	legacyHolds.files[key] = hold
	legacyHolds.Unlock()

	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err == nil {
		var opened os.FileInfo
		if opened, err = file.Stat(); err == nil && !os.SameFile(info, opened) {
			err = errors.New("legacy journal changed while opening")
		}
		if err == nil {
			err = sqliteSharedLock(ctx, file, ledgerLockTimeout)
		}
		if err != nil {
			file.Close()
		}
	}
	legacyHolds.Lock()
	if err != nil {
		delete(legacyHolds.files, key) // waiters try again themselves
	} else {
		hold.file, hold.refs = file, 1
	}
	close(hold.ready)
	legacyHolds.Unlock()
	if err != nil {
		return nil, nil, err
	}
	return hold, nil, nil
}

// release drops one reference; the last closes the descriptor, which releases
// the lock.
func (h *legacyHold) release() {
	if h == nil {
		return
	}
	legacyHolds.Lock()
	defer legacyHolds.Unlock()
	if h.refs--; h.refs == 0 {
		delete(legacyHolds.files, h.key)
		h.file.Close()
	}
}

// errLedgerDiverged is a legacy journal written after the import: an older
// relayd recorded usage the ledger does not have. Text operations stop, so
// spend and daily-limit counts never silently regress; nothing is merged.
type errLedgerDiverged struct{ root string }

func (e *errLedgerDiverged) Code() string { return "journal_diverged" }

func (e *errLedgerDiverged) Error() string {
	return fmt.Sprintf("%s/%s changed after it was imported into %s/%s: an older relayd wrote text usage "+
		"the ledger does not have, so text operations are stopped. Stop every relayd on this host, then "+
		"either (a) keep the ledger: rename %s aside (its later operations are not counted), or "+
		"(b) re-import: rename %s aside (operations recorded since the import are not counted). "+
		"Nothing is merged automatically.",
		e.root, legacyJournalName, e.root, ledgerLogName, legacyJournalName, ledgerLogName)
}

// checkLegacy refuses a legacy journal that differs from the one imported. An
// unchanged size and mtime pass without reading; otherwise the content must
// hash to the imported file, or to sqlite's rollback of its hot journal.
func (l *Ledger) checkLegacy() error {
	diverged := &errLedgerDiverged{l.root}
	if l.legacy == nil {
		// Gone: removed by the operator (or never there).
		if _, err := os.Lstat(l.path(legacyJournalName)); !errors.Is(err, os.ErrNotExist) {
			return diverged // appeared after this ledger opened
		}
		return nil
	}
	record := l.imported
	if record.Source == "" {
		return diverged // created after the ledger, by a legacy writer
	}
	info, err := l.legacy.file.Stat()
	if err != nil {
		return err
	}
	if info.Size() == record.Size && info.ModTime().UnixNano() == record.MTime {
		return nil
	}
	data, _, err := legacyBytes(l.legacy.file)
	if errors.Is(err, errSQLiteFormat) {
		return diverged // grown past any journal the ledger imported
	} else if err != nil {
		return err
	}
	if sum := bytesSHA256(data); sum == record.SHA256 || record.RolledBackSHA256 != "" && sum == record.RolledBackSHA256 {
		return nil
	}
	return diverged
}
