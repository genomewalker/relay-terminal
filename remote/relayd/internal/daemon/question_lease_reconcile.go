package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// An operator reconciles one unresolved lease_claim that never got a reply.
//
// The journal keeps such a claim forever because a request already sent can
// still execute. A claim is the only mutation this resolves, because a late
// claim can only give the lease to its own session: chitta refuses a claim on
// a thread another session holds live, and a same-session claim keeps the held
// epoch. A late release could remove a newer lease, so a release is never
// reconciled here.
//
// Proof, all of it read at reconcile time:
//   - no chitta ledger client started by relayd is still running, so no copy of
//     the request is in transit from this host;
//   - chitta answered a lease_list after the claim, so it is serving requests;
//   - that table shows no lease row for the thread, or a row owned by the
//     claim's own session (its epoch is then journaled as an orphan, released
//     epoch-fenced by the tick unless a live binding owns the key), or a live
//     row owned by another session (the claim lost to a live owner).
// An expired row owned by another session is ambiguous and refused.

type questionLeaseRow struct {
	ThreadID   string  `json:"thread_id"`
	SessionID  string  `json:"session_id"`
	LeaseEpoch *uint64 `json:"lease_epoch"`
	ExpiresAt  float64 `json:"expires_at"`
}

// QuestionLeaseReconcileReceipt reports one reconcile decision.
type QuestionLeaseReconcileReceipt struct {
	OpID       string            `json:"op_id"`
	SessionID  string            `json:"session_id"`
	ThreadID   string            `json:"thread_id"`
	Applied    bool              `json:"applied"`
	Decision   string            `json:"decision"`
	Observed   *questionLeaseRow `json:"observed_lease,omitempty"`
	OrphanID   string            `json:"orphan_id,omitempty"`
	ClientsRun int               `json:"ledger_clients_running"`
}

// Seam: the ledger clients relayd has running (chitta subprocesses). Tests replace it.
var questionLedgerClientsRunning = runningLedgerClients

func runningLedgerClients() (int, error) {
	if runtime.GOOS != "linux" {
		return 0, errors.New("in-flight ledger client check is available only on Linux")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return 0, err
	}
	chitta := filepath.Join(home, ".claude", "bin", "chitta")
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
		if err != nil || len(cmdline) == 0 {
			continue
		}
		if strings.SplitN(string(cmdline), "\x00", 2)[0] != chitta {
			continue
		}
		stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if err != nil {
			continue
		}
		fields := strings.Fields(string(stat[strings.LastIndexByte(string(stat), ')')+1:]))
		if len(fields) < 2 {
			continue
		}
		parentCmd, err := os.ReadFile("/proc/" + fields[1] + "/cmdline")
		if err != nil {
			continue
		}
		if filepath.Base(strings.SplitN(string(parentCmd), "\x00", 2)[0]) == "relayd" ||
			strings.HasPrefix(filepath.Base(strings.SplitN(string(parentCmd), "\x00", 2)[0]), "relayd-") {
			count++
		}
	}
	return count, nil
}

// ListQuestionLeaseJournal returns the unresolved mutations and orphans.
func ListQuestionLeaseJournal() (questionLeaseJournal, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return questionLeaseJournal{}, err
	}
	var journal questionLeaseJournal
	err = deps.withQuestionState(func() error {
		journal, err = deps.loadLeaseJournal()
		return err
	})
	return journal, err
}

// ReconcileQuestionLeaseClaim runs reconcileQuestionLeaseClaim with the host's deps.
func ReconcileQuestionLeaseClaim(ctx context.Context, opID string, apply bool) (QuestionLeaseReconcileReceipt, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return QuestionLeaseReconcileReceipt{}, err
	}
	return reconcileQuestionLeaseClaim(ctx, deps, opID, apply)
}

func reconcileQuestionLeaseClaim(ctx context.Context, deps questionThreadDeps, opID string, apply bool) (QuestionLeaseReconcileReceipt, error) {
	if !validHostNativeUUID(opID) {
		return QuestionLeaseReconcileReceipt{}, errors.New("op id must be a journaled lease mutation UUID")
	}
	var op questionLeaseOp
	found := false
	if err := deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		if err != nil {
			return err
		}
		for _, existing := range journal.Ops {
			if existing.ID == opID {
				op, found = existing, true
			}
		}
		return nil
	}); err != nil {
		return QuestionLeaseReconcileReceipt{}, err
	}
	if !found {
		return QuestionLeaseReconcileReceipt{}, errors.New("no unresolved lease mutation with that id")
	}
	receipt := QuestionLeaseReconcileReceipt{OpID: op.ID, SessionID: op.SessionID, ThreadID: op.ThreadID}
	if op.Op != questionLeaseClaim || op.Orphan != "" {
		receipt.Decision = "refused: only an unresolved lease_claim is reconciled; a release stays until its reply"
		return receipt, nil
	}
	running, err := questionLedgerClientsRunning()
	if err != nil {
		return receipt, err
	}
	receipt.ClientsRun = running
	if running != 0 {
		receipt.Decision = "refused: a relayd ledger client is still running, so the claim may be in transit"
		return receipt, nil
	}
	raw, err := questionCall(ctx, deps, "lease_list", map[string]any{"active_only": false})
	if err != nil {
		return receipt, errors.New("chitta lease table unavailable; nothing reconciled")
	}
	var table struct {
		Rows []questionLeaseRow `json:"rows"`
	}
	if json.Unmarshal(raw, &table) != nil {
		return receipt, errors.New("invalid chitta lease table; nothing reconciled")
	}
	var row *questionLeaseRow
	for i := range table.Rows {
		if table.Rows[i].ThreadID == op.ThreadID {
			if row != nil {
				return receipt, errors.New("chitta lists two leases for the thread; nothing reconciled")
			}
			row = &table.Rows[i]
		}
	}
	receipt.Observed = row
	now := float64(deps.now().UnixNano()) / 1e9
	recordOrphan := false
	switch {
	case row == nil:
		receipt.Decision = "no lease exists for the thread: the claim granted nothing that is still held"
	case row.SessionID == op.SessionID:
		if row.LeaseEpoch == nil || *row.LeaseEpoch == 0 {
			receipt.Decision = "refused: the claim's session holds a lease without an epoch, so it cannot be released fenced"
			return receipt, nil
		}
		recordOrphan = true
		receipt.Decision = "the claim's session holds the lease; it is journaled as an orphan for an epoch-fenced release"
	case row.ExpiresAt > now:
		receipt.Decision = "another session holds a live lease: the claim lost, and a late copy would be refused as live_owner"
	default:
		receipt.Decision = "refused: an expired lease of another session is ambiguous"
		return receipt, nil
	}
	if !apply {
		return receipt, nil
	}
	err = deps.withQuestionState(func() error {
		journal, err := deps.loadLeaseJournal()
		if err != nil {
			return err
		}
		var ops []questionLeaseOp
		present := false
		for _, existing := range journal.Ops {
			if existing.ID == op.ID {
				present = true
				continue
			}
			if existing.SessionID == op.SessionID && existing.ThreadID == op.ThreadID {
				return errors.New("another mutation on the key is unresolved; nothing reconciled")
			}
			ops = append(ops, existing)
		}
		if !present {
			return errors.New("the mutation was resolved meanwhile; nothing reconciled")
		}
		journal.Ops = ops
		if recordOrphan {
			id, err := newHostNativeUUID()
			if err != nil {
				return err
			}
			epoch := *row.LeaseEpoch
			journal.Orphans = append(journal.Orphans, questionLeaseOrphan{ID: id, SessionID: op.SessionID, ThreadID: op.ThreadID, LeaseEpoch: &epoch})
			receipt.OrphanID = id
		}
		return deps.saveLeaseJournal(journal)
	})
	if err != nil {
		return receipt, err
	}
	receipt.Applied = true
	// Held bindings on the key may claim now.
	reacquireHeldLeases(ctx, deps, op.SessionID, op.ThreadID)
	return receipt, nil
}
