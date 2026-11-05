package rotationtext

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Legacy-delta reconciliation for journal_diverged.
//
// A pre-ledger relayd (one that knows only operations.sqlite3) can append text
// usage after the ledger imported that file. checkLegacy then stops all text
// operations so spend never silently regresses. ReconcileLegacy is the
// supported recovery that needs no relayd to stop: under the ledger lock, the
// read gate and sqlite's SHARED lock on the legacy file (so no legacy writer can
// commit meanwhile), it merges what the legacy journal has and the ledger does
// not, additively, and records the legacy file as re-imported.
//
// It never executes or re-executes a model call, never deletes or lowers a
// ledger row, and never resolves a conflict: any row both sides changed
// incompatibly, any reused fingerprint and any configuration change with two
// values abort the whole reconcile with nothing written. An ambiguous
// (uncertain) outcome is kept, never upgraded to a result it does not have.

// ReconcileConflict is one incompatibility that stops reconciliation.
type ReconcileConflict struct {
	Kind   string `json:"kind"` // change_value, row_identity, fingerprint_reused, row_state
	ID     string `json:"id"`
	Ledger string `json:"ledger"`
	Legacy string `json:"legacy"`
}

// ReconcileReport describes a reconcile; Applied is false for a dry run, a
// conflict or a ledger that had not diverged.
type ReconcileReport struct {
	Diverged         bool                `json:"diverged"`
	Applied          bool                `json:"applied"`
	AddedChanges     []string            `json:"added_changes"`
	AddedRows        []string            `json:"added_rows"`
	AdvancedRows     []string            `json:"advanced_rows"`
	KeptLedgerRows   []string            `json:"kept_ledger_rows"`
	SettingsAdopted  bool                `json:"settings_adopted"`
	SettingsDiffer   bool                `json:"settings_differ_kept_ledger"`
	Conflicts        []ReconcileConflict `json:"conflicts"`
	LegacySHA256     string              `json:"legacy_sha256"`
	PreviousImport   LedgerImport        `json:"previous_import"`
	ResultingImport  *LedgerImport       `json:"resulting_import,omitempty"`
	LedgerRowsBefore int                 `json:"ledger_rows_before"`
	LedgerRowsAfter  int                 `json:"ledger_rows_after"`
	Retire           *RetireReport       `json:"retire,omitempty"`
}

// ReconcileOptions selects a dry run, an apply, and the fenced retirement of
// the legacy journal after the fold (see retire.go).
type ReconcileOptions struct {
	Apply         bool
	Retire        bool
	HelperDirs    []string
	AllowedImages []string // SHA-256 of reviewed images that never write the legacy journal
}

var errReconcileConflict = errors.New("legacy journal conflicts with the ledger; nothing was merged")

// stateRank orders the journal's lifecycle: finish only moves pending rows,
// abandon only pending or uncertain ones.
func stateRank(state string) int {
	switch state {
	case "pending":
		return 0
	case "uncertain":
		return 1
	}
	return 2
}

// legalAdvance reports whether the journal's own writes can take a row from
// state from to state to: finish (pending -> anything) or abandon
// (pending|uncertain -> abandoned).
func legalAdvance(from, to string) bool {
	if from == to {
		return false
	}
	return from == "pending" || from == "uncertain" && to == "abandoned"
}

func sameIdentity(a, b Operation) bool {
	return a.ID == b.ID && a.Fingerprint == b.Fingerprint && a.SettingsDigest == b.SettingsDigest &&
		a.Day == b.Day && a.Month == b.Month && a.Reserved == b.Reserved && a.AccountID == b.AccountID &&
		a.BillingGroup == b.BillingGroup && a.Purpose == b.Purpose && a.RequestID == b.RequestID
}

func sameOutcome(a, b Operation) bool {
	if a.State != b.State || a.Charged != b.Charged || (a.Result == nil) != (b.Result == nil) {
		return false
	}
	return a.Result == nil || *a.Result == *b.Result
}

func describeRow(row Operation) string {
	result := "null"
	if row.Result != nil {
		result = fmt.Sprintf("%d bytes", len(*row.Result))
	}
	return fmt.Sprintf("state=%s charged=%d result=%s fingerprint=%s", row.State, row.Charged, result, row.Fingerprint)
}

// mergeLegacyState merges legacy into a copy of ledger. It is pure: ledger and
// legacy are not modified. On any conflict it returns the report and
// errReconcileConflict and no state.
func mergeLegacyState(ledger, legacy *ledgerState) (*ledgerState, *ReconcileReport, error) {
	report := &ReconcileReport{AddedChanges: []string{}, AddedRows: []string{}, AdvancedRows: []string{},
		KeptLedgerRows: []string{}, Conflicts: []ReconcileConflict{}, LedgerRowsBefore: len(ledger.Rows)}
	merged := ledger.clone()

	for _, change := range legacy.Changes {
		if i, ok := merged.changes[change.ID]; ok {
			if merged.Changes[i].Value != change.Value {
				report.Conflicts = append(report.Conflicts, ReconcileConflict{"change_value", change.ID,
					merged.Changes[i].Value, change.Value})
			}
			continue
		}
		if err := merged.insertChange(change.ID, change.Value); err != nil {
			return nil, report, err
		}
		report.AddedChanges = append(report.AddedChanges, change.ID)
	}

	for _, row := range legacy.Rows {
		i, known := merged.ids[row.ID]
		if !known {
			if j, reused := merged.fingerprints[row.Fingerprint]; reused {
				// The same request recorded under two ids: possibly two model
				// executions. Never hide or count it silently.
				report.Conflicts = append(report.Conflicts, ReconcileConflict{"fingerprint_reused", row.ID,
					merged.Rows[j].ID, row.Fingerprint})
				continue
			}
			if err := merged.insertOperation(row); err != nil {
				return nil, report, err
			}
			report.AddedRows = append(report.AddedRows, row.ID)
			continue
		}
		current := merged.Rows[i]
		if !sameIdentity(current, row) {
			report.Conflicts = append(report.Conflicts, ReconcileConflict{"row_identity", row.ID,
				describeRow(current), describeRow(row)})
			continue
		}
		switch {
		case sameOutcome(current, row):
		case legalAdvance(current.State, row.State):
			// The legacy writer recorded an outcome the ledger lacks.
			result := row.Result
			if result != nil {
				copied := *result
				result = &copied
			}
			merged.Rows[i].State, merged.Rows[i].Charged, merged.Rows[i].Result = row.State, row.Charged, result
			report.AdvancedRows = append(report.AdvancedRows, row.ID)
		case legalAdvance(row.State, current.State):
			// The ledger already moved past the legacy copy: keep it.
			report.KeptLedgerRows = append(report.KeptLedgerRows, row.ID)
		default:
			// Both moved, or the same state with different outcomes.
			report.Conflicts = append(report.Conflicts, ReconcileConflict{"row_state", row.ID,
				describeRow(current), describeRow(row)})
		}
	}

	if legacy.HasSettings {
		switch {
		case !merged.HasSettings:
			merged.HasSettings, merged.SettingsID, merged.SettingsValue = true, legacy.SettingsID, legacy.SettingsValue
			report.SettingsAdopted = true
		case merged.SettingsID != legacy.SettingsID || merged.SettingsValue != legacy.SettingsValue:
			// Settings are configuration, not usage; the ledger is current.
			report.SettingsDiffer = true
		}
	}

	report.LedgerRowsAfter = len(merged.Rows)
	if len(report.Conflicts) > 0 {
		report.LedgerRowsAfter = len(ledger.Rows)
		return nil, report, errReconcileConflict
	}
	return merged, report, nil
}

// ReconcileLegacy merges a diverged legacy journal into the ledger in root.
// With apply false it only reports. Live readers and writers may stay open:
// it holds the ledger lock and the read gate exclusively, and sqlite's SHARED
// lock on the legacy file, for the whole read-merge-replace.
func ReconcileLegacy(ctx context.Context, root string, apply bool) (*ReconcileReport, error) {
	return ReconcileLegacyWith(ctx, root, ReconcileOptions{Apply: apply})
}

// ReconcileLegacyWith is ReconcileLegacy with options. With Retire it also
// retires the legacy journal under the same locks, after checking the helper
// directories; Retire requires Apply.
func ReconcileLegacyWith(ctx context.Context, root string, options ReconcileOptions) (*ReconcileReport, error) {
	apply := options.Apply
	if options.Retire && !apply {
		return nil, errors.New("retiring the legacy journal requires apply")
	}
	var retire *RetireReport
	var allowed map[string]bool
	if options.Retire {
		retire = &RetireReport{HelpersOK: []string{}, HoldersSeen: []string{}}
		var err error
		if allowed, err = allowlist(options.AllowedImages); err != nil {
			retire.RefusalReason = err.Error()
			return &ReconcileReport{Retire: retire}, err
		}
		helpers, err := checkHelperDirs(options.HelperDirs, allowed)
		retire.HelpersOK = helpers
		if err != nil {
			retire.RefusalReason = err.Error()
			return &ReconcileReport{Retire: retire}, err
		}
	}
	if !filepath.IsAbs(root) {
		return nil, &draftError{code: "invalid_state_directory"}
	}
	info, err := os.Lstat(root)
	if err != nil {
		return nil, err
	}
	if err := safeJournalInfo(info, true); err != nil {
		return nil, err
	}
	if _, err := os.Lstat(filepath.Join(root, ledgerLogName)); err != nil {
		return nil, fmt.Errorf("no ledger to reconcile in %s: %w", root, err)
	}
	lock, err := openLedgerFile(filepath.Join(root, ledgerLockName), false)
	if err != nil {
		return nil, err
	}
	l := &Ledger{root: root, ctx: ctx, lock: lock, state: newLedgerState()}
	defer l.Close()
	if l.gate, err = openLedgerFile(filepath.Join(root, ledgerGateName), false); err != nil {
		return nil, err
	}
	if err := l.lockExclusive(); err != nil {
		return nil, err
	}
	defer l.unlock()
	if err := l.flock(l.gate, syscall.LOCK_EX); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(l.gate.Fd()), syscall.LOCK_UN)
	if l.legacy, err = holdLegacyJournal(ctx, l.path(legacyJournalName)); err != nil {
		return nil, err
	}
	if l.legacy == nil {
		return nil, errors.New("no legacy journal to reconcile")
	}
	if err := l.checkPoisoned(); err != nil {
		return nil, err
	}
	if err := l.refresh(true); err != nil {
		return nil, err
	}
	report := &ReconcileReport{PreviousImport: *l.imported}
	divergence := l.checkLegacy()
	var diverged *errLedgerDiverged
	if divergence != nil && !errors.As(divergence, &diverged) {
		return nil, divergence
	}
	imported, err := readLegacyFile(l.legacy.file, l.path(legacyJournalName))
	if err != nil {
		return nil, err
	}
	merged, mergeReport, mergeErr := mergeLegacyState(l.state, imported.state)
	mergeReport.Diverged, mergeReport.PreviousImport, mergeReport.LegacySHA256 = divergence != nil, *l.imported, imported.sha256
	report = mergeReport
	report.Retire = retire
	if mergeErr != nil || !apply {
		return report, mergeErr
	}
	if divergence == nil {
		if !options.Retire {
			return report, nil
		}
		// Already folded: the import record matches the legacy file.
		return report, l.retireOrRefuse(*l.imported, allowed, retire)
	}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	// Keep LedgerImport's existing fields only: ledger-aware relayds already
	// running decode the first frame with unknown fields disallowed.
	record := *l.imported
	record.Source, record.SHA256, record.Size, record.MTime = legacyJournalName, imported.sha256, imported.size, imported.mtime
	record.HotJournalPages, record.RolledBackSHA256 = imported.hotJournalPages, imported.rolledBackSHA256
	record.Operations, record.ConfigurationChanges = len(imported.state.Rows), len(imported.state.Changes)
	if err := l.writeSnapshot(merged, &record); err != nil {
		var unknown *errLedgerDurabilityUnknown
		if errors.As(err, &unknown) {
			report.Applied, report.ResultingImport = true, &record
		}
		return report, err
	}
	report.Applied, report.ResultingImport = true, &record
	if !options.Retire {
		return report, nil
	}
	return report, l.retireOrRefuse(record, allowed, retire)
}

func (l *Ledger) retireOrRefuse(record LedgerImport, allowed map[string]bool, retire *RetireReport) error {
	err := l.retireLegacy(l.legacy.file, record, allowed, retire)
	if err != nil {
		retire.RefusalReason = err.Error()
	}
	return err
}
