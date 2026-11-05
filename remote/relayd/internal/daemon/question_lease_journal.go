package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
)

// Every chitta lease mutation is journaled before its call and resolved only by
// the call's reply. chitta's lease_release takes no generation, so a release
// still in transit can remove a lease that a later claim on the same key
// granted. While a mutation on a session/thread key is unresolved, no claim is
// issued on that key: a rebind is held, not confirmed, and its notices wait.
// A transport failure or an unreadable reply is an unknown outcome and stays
// journaled. Nothing resolves it by time, by process exit or by asking chitta,
// because a request already sent can still execute. Only a reply clears it.

// questionLeaseUnconfirmedReason is reported while a bind is held. It stays until
// the unresolved mutation on its key is reconciled.
const questionLeaseUnconfirmedReason = "unresolved_lease_mutation"

const (
	questionLeaseClaim   = "lease_claim"
	questionLeaseRelease = "lease_release"
)

// questionLeaseOp is one unresolved lease mutation. Orphan names the orphan
// record it settles, or is empty for a mutation of a binding.
type questionLeaseOp struct {
	ID        string `json:"id"`
	Op        string `json:"op"`
	SessionID string `json:"session_id"`
	ThreadID  string `json:"thread_id"`
	Orphan    string `json:"orphan,omitempty"`
}

// questionLeaseOrphan is a lease this process may have claimed for a key that no
// live binding owns. Settling it releases that key and touches nothing else:
// no pane record, no opt-in.
type questionLeaseOrphan struct {
	ID         string  `json:"id"`
	SessionID  string  `json:"session_id"`
	ThreadID   string  `json:"thread_id"`
	LeaseEpoch *uint64 `json:"lease_epoch,omitempty"`
}

type questionLeaseJournal struct {
	Ops     []questionLeaseOp     `json:"ops,omitempty"`
	Orphans []questionLeaseOrphan `json:"orphans,omitempty"`
}

// leaseJournalPath sits beside the record directory, not inside it, so the
// record listing never reads it.
func (deps questionThreadDeps) leaseJournalPath() string {
	return deps.store.dir + ".leases.json"
}

// loadLeaseJournal and saveLeaseJournal run under withQuestionState.
func (deps questionThreadDeps) loadLeaseJournal() (questionLeaseJournal, error) {
	var journal questionLeaseJournal
	data, err := os.ReadFile(deps.leaseJournalPath())
	if errors.Is(err, os.ErrNotExist) {
		return journal, nil
	}
	if err != nil {
		return journal, err
	}
	if err := json.Unmarshal(data, &journal); err != nil {
		return journal, errors.New("invalid question lease journal")
	}
	return journal, nil
}

// saveLeaseJournal replaces the journal atomically and durably: the new content is
// synced before the rename, and the directory is synced after it. Every failure
// is returned, and the callers dispatch nothing when a journal write fails, so a
// mutation is never sent without its entry on disk. A failed write leaves the old
// journal in place, so no pending mutation is cleared by a persistence error.
func (deps questionThreadDeps) saveLeaseJournal(journal questionLeaseJournal) error {
	data, err := json.Marshal(journal)
	if err != nil {
		return err
	}
	return durableWriteFile(deps.leaseJournalPath(), append(data, '\n'))
}

// busy reports whether any unresolved mutation is on the key.
func (journal questionLeaseJournal) busy(sessionID, threadID string) bool {
	for _, op := range journal.Ops {
		if op.SessionID == sessionID && op.ThreadID == threadID {
			return true
		}
	}
	return false
}

func (journal questionLeaseJournal) orphanInFlight(orphanID string) bool {
	for _, op := range journal.Ops {
		if op.Orphan == orphanID {
			return true
		}
	}
	return false
}

// beginLeaseOp journals one mutation before its chitta call. A claim is refused,
// with ok false, while any mutation on its key is unresolved. A release is never
// refused: it only removes a lease.
func (deps questionThreadDeps) beginLeaseOp(op questionLeaseOp, claim bool) (bool, error) {
	ok := true
	err := deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		if err != nil {
			return err
		}
		if claim && journal.busy(op.SessionID, op.ThreadID) {
			ok = false
			return nil
		}
		journal.Ops = append(journal.Ops, op)
		return deps.saveLeaseJournal(journal)
	})
	return ok, err
}

// finishLeaseOp removes a resolved mutation, and the orphan it settled.
func (deps questionThreadDeps) finishLeaseOp(op questionLeaseOp) error {
	return deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		if err != nil {
			return err
		}
		var ops []questionLeaseOp
		for _, existing := range journal.Ops {
			if existing.ID != op.ID {
				ops = append(ops, existing)
			}
		}
		journal.Ops = ops
		if op.Orphan != "" {
			var orphans []questionLeaseOrphan
			for _, orphan := range journal.Orphans {
				if orphan.ID != op.Orphan {
					orphans = append(orphans, orphan)
				}
			}
			journal.Orphans = orphans
		}
		return deps.saveLeaseJournal(journal)
	})
}

// saveQuestionOrphan records an orphan under the state lock.
func (deps questionThreadDeps) saveQuestionOrphan(sessionID, threadID string, epoch *uint64) error {
	return deps.withQuestionState(func() error {
		_, err := deps.recordOrphanLocked(sessionID, threadID, epoch)
		return err
	})
}

// recordOrphanLocked adds an orphan record. The caller holds the state lock.
func (deps questionThreadDeps) recordOrphanLocked(sessionID, threadID string, epoch *uint64) (questionLeaseOrphan, error) {
	id, err := newHostNativeUUID()
	if err != nil {
		return questionLeaseOrphan{}, err
	}
	orphan := questionLeaseOrphan{ID: id, SessionID: sessionID, ThreadID: threadID, LeaseEpoch: epoch}
	journal, err := deps.loadLeaseJournal()
	if err != nil {
		return questionLeaseOrphan{}, err
	}
	journal.Orphans = append(journal.Orphans, orphan)
	return orphan, deps.saveLeaseJournal(journal)
}

// claimTrackedLease claims the thread's lease for the session through the
// journal. held is true, with no chitta call, while an older mutation on the key
// is unresolved. On an error the outcome is unknown, and the mutation stays
// journaled.
func claimTrackedLease(ctx context.Context, deps questionThreadDeps, sessionID, threadID string, ttl int) (reply questionLeaseReply, held bool, err error) {
	id, err := newHostNativeUUID()
	if err != nil {
		return questionLeaseReply{}, false, err
	}
	op := questionLeaseOp{ID: id, Op: questionLeaseClaim, SessionID: sessionID, ThreadID: threadID}
	ok, err := deps.beginLeaseOp(op, true)
	if err != nil {
		return questionLeaseReply{}, false, err
	}
	if !ok {
		return questionLeaseReply{}, true, nil
	}
	reply, err = claimQuestionLease(ctx, deps, sessionID, threadID, ttl)
	if err != nil {
		return reply, false, err
	}
	return reply, false, deps.finishLeaseOp(op)
}

// leaseReleaseArgs builds a lease_release call. The epoch is sent only when chitta
// returned one for this lease.
func leaseReleaseArgs(sessionID, threadID string, epoch *uint64) map[string]any {
	args := map[string]any{"session_id": sessionID, "thread_id": threadID}
	if epoch != nil {
		args["lease_epoch"] = *epoch
	}
	return args
}

// releaseLeaseKey journals and sends one lease_release for the op's key. A reply
// with reason epoch_mismatch means the lease is not this one and nothing was
// removed. That is a known outcome, not an error, and it is never retried.
func releaseLeaseKey(ctx context.Context, deps questionThreadDeps, op questionLeaseOp, epoch *uint64) error {
	id, err := newHostNativeUUID()
	if err != nil {
		return err
	}
	op.ID, op.Op = id, questionLeaseRelease
	if _, err := deps.beginLeaseOp(op, false); err != nil {
		return err
	}
	if _, err := questionCall(ctx, deps, questionLeaseRelease, leaseReleaseArgs(op.SessionID, op.ThreadID, epoch)); err != nil {
		return errors.New("chitta lease release unavailable")
	}
	return deps.finishLeaseOp(op)
}

// ownsLeaseKey reports whether a live record owns the session/thread key. A
// record that is reserved for a bind on the thread counts as an owner, because
// its session is not known yet. A releasing record owns nothing.
func (deps questionThreadDeps) ownsLeaseKey(sessionID, threadID string) (owner, deferred bool, err error) {
	panes, err := deps.store.panes()
	if err != nil {
		return false, false, err
	}
	for _, pane := range panes {
		binding, found, err := deps.store.load(pane)
		if err != nil {
			return false, false, err
		}
		if !found || binding.ReleaseStage != "" || binding.ThreadID != threadID {
			continue
		}
		if binding.Phase == questionThreadPhaseReserved {
			deferred = true
			continue
		}
		if binding.SessionID == sessionID {
			owner = true
		}
	}
	return owner, deferred, nil
}

// settleQuestionOrphan releases an orphan's key unless a live record owns it. It
// is a no-op while another settle of the same orphan is in flight, and it is
// deferred while a bind reserves the thread.
func settleQuestionOrphan(ctx context.Context, deps questionThreadDeps, orphan questionLeaseOrphan) error {
	id, err := newHostNativeUUID()
	if err != nil {
		return err
	}
	op := questionLeaseOp{ID: id, Op: questionLeaseRelease, SessionID: orphan.SessionID, ThreadID: orphan.ThreadID, Orphan: orphan.ID}
	start := false
	err = deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		if err != nil {
			return err
		}
		if journal.orphanInFlight(orphan.ID) {
			return nil
		}
		owner, deferred, err := deps.ownsLeaseKey(orphan.SessionID, orphan.ThreadID)
		if err != nil || deferred {
			return err
		}
		if owner {
			var orphans []questionLeaseOrphan
			for _, existing := range journal.Orphans {
				if existing.ID != orphan.ID {
					orphans = append(orphans, existing)
				}
			}
			journal.Orphans = orphans
			return deps.saveLeaseJournal(journal)
		}
		journal.Ops = append(journal.Ops, op)
		start = true
		return deps.saveLeaseJournal(journal)
	})
	if err != nil || !start {
		return err
	}
	if _, err := questionCall(ctx, deps, questionLeaseRelease, leaseReleaseArgs(orphan.SessionID, orphan.ThreadID, orphan.LeaseEpoch)); err != nil {
		return errors.New("chitta lease release unavailable")
	}
	return deps.finishLeaseOp(op)
}

// settleQuestionOrphans retries every journaled orphan. The tick runs it.
func settleQuestionOrphans(ctx context.Context, deps questionThreadDeps) {
	var orphans []questionLeaseOrphan
	_ = deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		orphans = journal.Orphans
		return err
	})
	for _, orphan := range orphans {
		if ctx.Err() != nil {
			return
		}
		_ = settleQuestionOrphan(ctx, deps, orphan)
	}
}

// reacquireHeldLeases claims the lease for each held binding on the key, now that
// its older mutations have resolved. Each claim goes through renewQuestionThread,
// which checks the record's identity before it commits.
func reacquireHeldLeases(ctx context.Context, deps questionThreadDeps, sessionID, threadID string) {
	panes, err := deps.store.panes()
	if err != nil {
		return
	}
	for _, pane := range panes {
		binding, found, err := deps.loadQuestionState(pane)
		if err != nil || !found || !binding.LeasePending || binding.ReleaseStage != "" ||
			binding.SessionID != sessionID || binding.ThreadID != threadID {
			continue
		}
		_, _ = renewQuestionThread(ctx, deps, binding)
	}
}
