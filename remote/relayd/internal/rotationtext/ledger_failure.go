package rotationtext

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"syscall"
)

// A commit whose fsync failed is rolled back by truncating its frame. When the
// truncation (or its fsync) fails too, the frame may still be in the log, and
// readers would take it as committed once the gate opens. The ledger is then
// poisoned before the gate opens: in this process at once, and durably by the
// ledger.poisoned marker. Every open, Begin and read refuses until an operator
// repairs the log; nothing is repaired automatically.
const ledgerPoisonName = "ledger.poisoned"

// poisonedLedgers holds the roots this process poisoned, for when even the
// marker could not be written. Only a restart clears it.
var poisonedLedgers sync.Map // root -> *errLedgerPoisoned

type errLedgerPoisoned struct {
	root   string
	offset int64 // the log's committed length; the failed frame follows it
	cause  error
}

func (e *errLedgerPoisoned) Code() string  { return "journal_poisoned" }
func (e *errLedgerPoisoned) Unwrap() error { return e.cause }

func (e *errLedgerPoisoned) Error() string {
	offset := "(unknown: the marker is unreadable)"
	if e.offset >= 0 {
		offset = fmt.Sprint(e.offset)
	}
	return fmt.Sprintf("%s/%s may end with a transaction that failed to commit: its fsync failed and removing it "+
		"failed too, so text operations are stopped. Committed transactions end at byte %s. Stop every relayd on "+
		"this host and check the file system, then either (a) truncate %s to that many bytes, or (b) rename %s aside to "+
		"re-import %s (operations recorded since the import are not counted); then remove %s/%s. Nothing is "+
		"repaired automatically.",
		e.root, ledgerLogName, offset, ledgerLogName, ledgerLogName, legacyJournalName, e.root, ledgerPoisonName)
}

// poison records that the frame after l.offset may remain, and returns the
// refusal. The caller holds the lock and the gate, so no reader has seen it.
func (l *Ledger) poison(cause error) error {
	poisoned := &errLedgerPoisoned{root: l.root, offset: l.offset, cause: cause}
	poisonedLedgers.Store(l.root, poisoned)
	data, _ := json.Marshal(map[string]int64{"offset": l.offset})
	file, err := os.OpenFile(l.path(ledgerPoisonName), os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err == nil {
		_, err = file.Write(data)
		if err == nil {
			err = ledgerSync(file)
		}
		file.Close()
		if err == nil {
			_ = syncDirectory(l.root)
		}
	}
	return poisoned
}

// checkPoisoned refuses a ledger poisoned by this process or, through its
// marker, by any other.
func (l *Ledger) checkPoisoned() error {
	if poisoned, ok := poisonedLedgers.Load(l.root); ok {
		return poisoned.(*errLedgerPoisoned)
	}
	data, err := os.ReadFile(l.path(ledgerPoisonName))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	poisoned := &errLedgerPoisoned{root: l.root, offset: -1, cause: err}
	var marker struct {
		Offset *int64 `json:"offset"`
	}
	if err == nil && json.Unmarshal(data, &marker) == nil && marker.Offset != nil {
		poisoned.offset = *marker.Offset
	}
	return poisoned
}

// errLedgerDurabilityUnknown is a compaction whose snapshot replaced the log
// but whose directory fsync failed: the transaction is in the log every
// reader sees, but may not survive a crash. The writer keeps its state, which
// is the log's, so a retry cannot apply the transaction twice.
type errLedgerDurabilityUnknown struct {
	root  string
	cause error
}

func (e *errLedgerDurabilityUnknown) Code() string  { return "journal_durability_unknown" }
func (e *errLedgerDurabilityUnknown) Unwrap() error { return e.cause }

func (e *errLedgerDurabilityUnknown) Error() string {
	return fmt.Sprintf("%s/%s was replaced by a compacted copy holding the transaction, but syncing %s failed (%v): "+
		"the transaction is recorded but may not survive a crash. Check the file system.",
		e.root, ledgerLogName, e.root, e.cause)
}
