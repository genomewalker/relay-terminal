package rotationtext

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// ---- pure merge ----

func rrow(id, fingerprint, state string, charged int64, result string) Operation {
	row := Operation{ID: id, Fingerprint: fingerprint, SettingsDigest: "s", State: state, Day: "2026-11-01",
		Month: "2026-11", Reserved: 10, Charged: charged, AccountID: "a", Purpose: "p", RequestID: "r-" + id}
	if result != "" {
		value := result
		row.Result = &value
	}
	return row
}

func rstate(t testing.TB, rows ...Operation) *ledgerState {
	t.Helper()
	state := newLedgerState()
	for _, row := range rows {
		if err := state.insertOperation(row); err != nil {
			t.Fatal(err)
		}
	}
	return state
}

func TestReconcileMergeCases(t *testing.T) {
	type tc struct {
		name           string
		ledger, legacy []Operation
		conflict       string
		added, adv     int
		wantState      map[string]string
	}
	cases := []tc{
		{name: "legacy-only row is added", ledger: []Operation{rrow("1", "f1", "complete", 5, "ok")},
			legacy: []Operation{rrow("1", "f1", "complete", 5, "ok"), rrow("2", "f2", "complete", 7, "ok")},
			added:  1, wantState: map[string]string{"1": "complete", "2": "complete"}},
		{name: "ledger-only row is kept", ledger: []Operation{rrow("1", "f1", "complete", 5, "ok"), rrow("3", "f3", "pending", 0, "")},
			legacy: []Operation{rrow("1", "f1", "complete", 5, "ok")}, wantState: map[string]string{"3": "pending"}},
		{name: "legacy finish advances pending", ledger: []Operation{rrow("1", "f1", "pending", 0, "")},
			legacy: []Operation{rrow("1", "f1", "complete", 9, "ok")}, adv: 1, wantState: map[string]string{"1": "complete"}},
		{name: "legacy abandon advances uncertain", ledger: []Operation{rrow("1", "f1", "uncertain", 0, "")},
			legacy: []Operation{rrow("1", "f1", "abandoned", 0, "")}, adv: 1, wantState: map[string]string{"1": "abandoned"}},
		{name: "uncertain is never upgraded to a result", ledger: []Operation{rrow("1", "f1", "uncertain", 0, "")},
			legacy: []Operation{rrow("1", "f1", "complete", 9, "ok")}, conflict: "row_state"},
		{name: "ledger ahead keeps ledger", ledger: []Operation{rrow("1", "f1", "complete", 9, "ok")},
			legacy: []Operation{rrow("1", "f1", "pending", 0, "")}, wantState: map[string]string{"1": "complete"}},
		{name: "both finished differently", ledger: []Operation{rrow("1", "f1", "complete", 9, "ok")},
			legacy: []Operation{rrow("1", "f1", "failed", 0, "x")}, conflict: "row_state"},
		{name: "same state different charge", ledger: []Operation{rrow("1", "f1", "complete", 9, "ok")},
			legacy: []Operation{rrow("1", "f1", "complete", 8, "ok")}, conflict: "row_state"},
		{name: "fingerprint reused under a new id", ledger: []Operation{rrow("1", "f1", "complete", 9, "ok")},
			legacy: []Operation{rrow("2", "f1", "complete", 9, "ok")}, conflict: "fingerprint_reused"},
		{name: "same id different reserved", ledger: []Operation{rrow("1", "f1", "pending", 0, "")},
			legacy:   []Operation{func() Operation { r := rrow("1", "f1", "pending", 0, ""); r.Reserved = 99; return r }()},
			conflict: "row_identity"},
		{name: "same id different identity", ledger: []Operation{rrow("1", "f1", "pending", 0, "")},
			legacy: []Operation{rrow("1", "f9", "complete", 9, "ok")}, conflict: "row_identity"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ledger, legacy := rstate(t, c.ledger...), rstate(t, c.legacy...)
			before := fmt.Sprintf("%+v", ledger.Rows)
			merged, report, err := mergeLegacyState(ledger, legacy)
			if fmt.Sprintf("%+v", ledger.Rows) != before {
				t.Fatal("merge modified its input")
			}
			if c.conflict != "" {
				if !errors.Is(err, errReconcileConflict) || merged != nil || len(report.Conflicts) == 0 ||
					report.Conflicts[0].Kind != c.conflict {
					t.Fatalf("want conflict %s, got err=%v merged=%v report=%+v", c.conflict, err, merged != nil, report)
				}
				return
			}
			if err != nil || len(report.AddedRows) != c.added || len(report.AdvancedRows) != c.adv {
				t.Fatalf("err=%v report=%+v", err, report)
			}
			for id, state := range c.wantState {
				if merged.Rows[merged.ids[id]].State != state {
					t.Fatalf("row %s state %s want %s", id, merged.Rows[merged.ids[id]].State, state)
				}
			}
		})
	}
}

func TestReconcileChangesAndSettings(t *testing.T) {
	ledger, legacy := newLedgerState(), newLedgerState()
	ledger.insertChange("c1", "v1")
	legacy.insertChange("c1", "v1")
	legacy.insertChange("c2", "v2")
	legacy.HasSettings, legacy.SettingsID, legacy.SettingsValue = true, "op", "cfg"
	merged, report, err := mergeLegacyState(ledger, legacy)
	if err != nil || len(report.AddedChanges) != 1 || !report.SettingsAdopted || merged.SettingsValue != "cfg" {
		t.Fatalf("err=%v report=%+v", err, report)
	}
	ledger.HasSettings, ledger.SettingsID, ledger.SettingsValue = true, "op2", "newer"
	merged, report, err = mergeLegacyState(ledger, legacy)
	if err != nil || !report.SettingsDiffer || merged.SettingsValue != "newer" {
		t.Fatalf("ledger settings not kept: err=%v report=%+v", err, report)
	}
	legacy.Changes[0].Value = "other"
	legacy.changes = map[string]int{"c1": 0, "c2": 1}
	if _, report, err = mergeLegacyState(ledger, legacy); !errors.Is(err, errReconcileConflict) ||
		report.Conflicts[0].Kind != "change_value" {
		t.Fatalf("change conflict not refused: %v %+v", err, report)
	}
}

// testIdentity is the test's own identity oracle, independent of sameIdentity:
// every column except the outcome (state, charged, result).
func testIdentity(a, b Operation) bool {
	a.State, a.Charged, a.Result = "", 0, nil
	b.State, b.Charged, b.Result = "", 0, nil
	return fmt.Sprintf("%+v", a) == fmt.Sprintf("%+v", b)
}

// ---- exhaustive bounded check ----

// reconcileUniverse is every variant one id can have on one side: absent, each
// lifecycle state, two charges for complete, and a foreign identity.
var reconcileStates = []string{"", "pending", "uncertain", "complete", "complete9", "failed", "abandoned", "foreign", "fpreuse"}

func variant(id, v string) (Operation, bool) {
	switch v {
	case "":
		return Operation{}, false
	case "complete":
		return rrow(id, "f"+id, "complete", 5, "ok"), true
	case "complete9":
		return rrow(id, "f"+id, "complete", 9, "ok"), true
	case "failed":
		return rrow(id, "f"+id, "failed", 0, "err"), true
	case "foreign":
		row := rrow(id, "f"+id, "pending", 0, "")
		row.Reserved = 99
		return row, true
	case "fpreuse":
		// A fresh id reusing the other id's fingerprint.
		other := map[string]string{"1": "2", "2": "1"}[id]
		return rrow("x"+id, "f"+other, "complete", 5, "ok"), true
	}
	return rrow(id, "f"+id, v, 0, ""), true
}

// checkReconcileProperties asserts the named safety and liveness properties of
// one merge. It returns the outcome class for counting.
func checkReconcileProperties(t testing.TB, ledger, legacy *ledgerState) string {
	merged, report, err := mergeLegacyState(ledger, legacy)
	if err != nil {
		// R4 all-or-nothing: a conflict returns no state.
		if !errors.Is(err, errReconcileConflict) || merged != nil || len(report.Conflicts) == 0 {
			t.Fatalf("R4: err=%v merged=%v conflicts=%d", err, merged != nil, len(report.Conflicts))
		}
		return "conflict"
	}
	if len(report.Conflicts) != 0 {
		t.Fatal("R4: conflicts without an error")
	}
	for _, row := range ledger.Rows {
		i, ok := merged.ids[row.ID]
		if !ok {
			t.Fatalf("R1: ledger row %s removed", row.ID)
		}
		got := merged.Rows[i]
		// R1 identity preserved; R2 only equal or a legal advance.
		if !testIdentity(got, row) || !(sameOutcome(got, row) || legalAdvance(row.State, got.State)) {
			t.Fatalf("R1/R2: row %s %s -> %s", row.ID, describeRow(row), describeRow(got))
		}
		// R5 an ambiguous outcome is never given a result it did not have.
		if row.State == "uncertain" && got.State != "uncertain" && got.State != "abandoned" {
			t.Fatalf("R5: uncertain row %s became %s", row.ID, got.State)
		}
	}
	for _, row := range legacy.Rows {
		i, ok := merged.ids[row.ID]
		if !ok {
			t.Fatalf("R3: legacy row %s lost", row.ID)
		}
		got := merged.Rows[i]
		// R3 legacy usage is represented: equal, or the merged row is past it.
		if !testIdentity(got, row) || !(sameOutcome(got, row) || legalAdvance(row.State, got.State)) {
			t.Fatalf("R3: legacy %s %s merged %s", row.ID, describeRow(row), describeRow(got))
		}
	}
	// R6 fingerprints stay unique (no hidden second execution).
	seen := map[string]bool{}
	for _, row := range merged.Rows {
		if seen[row.Fingerprint] {
			t.Fatalf("R6: fingerprint %s twice", row.Fingerprint)
		}
		seen[row.Fingerprint] = true
	}
	// R7 idempotent: merging the same legacy again changes nothing.
	again, second, err := mergeLegacyState(merged, legacy)
	if err != nil || len(second.AddedRows)+len(second.AdvancedRows)+len(second.AddedChanges) != 0 ||
		fmt.Sprintf("%+v", again.Rows) != fmt.Sprintf("%+v", merged.Rows) {
		t.Fatalf("R7: second merge err=%v report=%+v", err, second)
	}
	return "merged"
}

func TestReconcileBoundedExhaustive(t *testing.T) {
	ids := []string{"1", "2"}
	n := len(reconcileStates)
	total, counts := 0, map[string]int{}
	var walk func(depth int, ledgerV, legacyV []string)
	walk = func(depth int, ledgerV, legacyV []string) {
		if depth == len(ids) {
			ledger, legacy := newLedgerState(), newLedgerState()
			valid := true
			for k, id := range ids {
				if row, ok := variant(id, ledgerV[k]); ok && ledgerV[k] != "fpreuse" && ledgerV[k] != "foreign" {
					valid = valid && ledger.insertOperation(row) == nil
				} else if ledgerV[k] == "fpreuse" || ledgerV[k] == "foreign" {
					valid = false // the ledger side uses only real lifecycle rows
				}
				if row, ok := variant(id, legacyV[k]); ok {
					if legacy.insertOperation(row) != nil {
						valid = false
					}
				}
			}
			if !valid {
				return
			}
			total++
			counts[checkReconcileProperties(t, ledger, legacy)]++
			// L1 liveness: a legacy copy that is the ledger plus legal
			// advances and new rows always merges.
			return
		}
		for i := 0; i < n; i++ {
			for j := 0; j < n; j++ {
				walk(depth+1, append(ledgerV, reconcileStates[i]), append(legacyV, reconcileStates[j]))
			}
		}
	}
	walk(0, nil, nil)
	t.Logf("bounded: %d ids x %d variants per side: %d valid pairs checked, %v", len(ids), n, total, counts)
	if total < 1000 || counts["merged"] == 0 || counts["conflict"] == 0 {
		t.Fatalf("bounded check too small or one-sided: %d %v", total, counts)
	}
}

// L1: liveness, positively. Every legal advance and every new legacy row merges
// without conflict and lands in the ledger.
func TestReconcileLivenessLegalAdvances(t *testing.T) {
	states := []string{"pending", "uncertain", "complete", "failed", "abandoned"}
	for _, from := range states {
		for _, to := range states {
			if from != to && !legalAdvance(from, to) {
				continue
			}
			ledger := rstate(t, rrow("1", "f1", from, 0, ""))
			legacyRow := rrow("1", "f1", to, 0, "")
			if to == "complete" || to == "failed" {
				legacyRow = rrow("1", "f1", to, 4, "r")
			}
			if from == to {
				legacyRow = ledger.Rows[0]
			}
			legacy := rstate(t, legacyRow, rrow("2", "f2", "complete", 3, "ok"))
			merged, report, err := mergeLegacyState(ledger, legacy)
			if err != nil || merged.Rows[merged.ids["1"]].State != to || len(report.AddedRows) != 1 {
				t.Fatalf("L1 %s->%s: err=%v report=%+v", from, to, err, report)
			}
		}
	}
}

// ---- fuzz ----

func FuzzReconcileMerge(f *testing.F) {
	f.Add([]byte{1, 3, 2, 4})
	f.Add([]byte{3, 3, 0, 1, 8, 7})
	f.Add([]byte{2, 2, 2, 2, 2, 2, 2, 2})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 64 {
			data = data[:64]
		}
		ledger, legacy := newLedgerState(), newLedgerState()
		for i := 0; i+1 < len(data); i += 2 {
			id := fmt.Sprint(i/2%4 + 1)
			if row, ok := variant(id, reconcileStates[int(data[i])%len(reconcileStates)]); ok &&
				row.ID == id && row.Reserved == 10 {
				_ = ledger.insertOperation(row)
			}
			if row, ok := variant(id, reconcileStates[int(data[i+1])%len(reconcileStates)]); ok {
				_ = legacy.insertOperation(row)
			}
		}
		checkReconcileProperties(t, ledger, legacy)
	})
}

// ---- end to end over a real sqlite legacy journal ----

func sqliteExec(t *testing.T, path, sql string) {
	t.Helper()
	tool, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Fatalf("sqlite3 is required for the legacy-writer emulation: %v", err)
	}
	if out, err := exec.Command(tool, path, sql).CombinedOutput(); err != nil {
		t.Fatalf("sqlite3: %v %s", err, out)
	}
}

func divergedRoot(t *testing.T) (string, int) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "real"), root)
	ledger := openLedger(t, root)
	imported := rowCount(t, ledger)
	insertRows(t, ledger, 900000, 1, "ledger-side") // a post-import ledger write
	ledger.Close()
	legacy := filepath.Join(root, legacyJournalName)
	// An older relayd appends usage after the import.
	sqliteExec(t, legacy, "INSERT INTO operations (id,fingerprint,settings_digest,state,day,month,reserved,charged,result) "+
		"VALUES ('legacy-after-import','fp-legacy-after-import','s','complete','2026-10-29','2026-10',10,7,'{}');")
	var diverged *errLedgerDiverged
	if _, err := OpenLedger(root); !errors.As(err, &diverged) {
		t.Fatalf("setup did not diverge: %v", err)
	}
	return root, imported
}

func TestReconcileLegacyEndToEnd(t *testing.T) {
	root, imported := divergedRoot(t)
	logPath := filepath.Join(root, ledgerLogName)
	before := fileSHA(t, logPath)
	legacySHA := fileSHA(t, filepath.Join(root, legacyJournalName))

	dry, err := ReconcileLegacy(context.Background(), root, false)
	if err != nil || dry.Applied || !dry.Diverged || len(dry.AddedRows) != 1 || dry.AddedRows[0] != "legacy-after-import" {
		t.Fatalf("dry run: err=%v report=%+v", err, dry)
	}
	if fileSHA(t, logPath) != before {
		t.Fatal("dry run wrote the ledger")
	}

	report, err := ReconcileLegacy(context.Background(), root, true)
	if err != nil || !report.Applied || report.ResultingImport == nil || report.ResultingImport.SHA256 != legacySHA {
		t.Fatalf("apply: err=%v report=%+v", err, report)
	}
	if fileSHA(t, filepath.Join(root, legacyJournalName)) != legacySHA {
		t.Fatal("reconcile modified the legacy journal")
	}
	ledger := openLedger(t, root) // no longer diverged
	defer ledger.Close()
	rows, err := ledger.Operations()
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, row := range rows {
		found[row.ID] = true
	}
	if len(rows) != imported+2 || !found["legacy-after-import"] || !found[ledgerRow(900000, "").ID] {
		t.Fatalf("merged ledger has %d rows (imported %d), legacy=%v ledger-side=%v", len(rows), imported,
			found["legacy-after-import"], found[ledgerRow(900000, "").ID])
	}
	// Normal writes continue after reconcile.
	insertRows(t, ledger, 900001, 1, "after")
	// A second reconcile has nothing to do.
	again, err := ReconcileLegacy(context.Background(), root, true)
	if err != nil || again.Diverged || again.Applied {
		t.Fatalf("second reconcile: err=%v report=%+v", err, again)
	}
}

func TestReconcileLegacyConflictWritesNothing(t *testing.T) {
	root, _ := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	// The legacy writer also rewrote an outcome the ledger already has.
	sqliteExec(t, legacy, "UPDATE operations SET charged = charged + 1 WHERE id = (SELECT id FROM operations WHERE state='complete' AND id <> 'legacy-after-import' LIMIT 1);")
	logPath := filepath.Join(root, ledgerLogName)
	before := fileSHA(t, logPath)
	report, err := ReconcileLegacy(context.Background(), root, true)
	if !errors.Is(err, errReconcileConflict) || report == nil || report.Applied || len(report.Conflicts) != 1 ||
		report.Conflicts[0].Kind != "row_state" {
		t.Fatalf("conflict not refused: err=%v report=%+v", err, report)
	}
	if fileSHA(t, logPath) != before {
		t.Fatal("a conflicting reconcile wrote the ledger")
	}
	var diverged *errLedgerDiverged
	if _, err := OpenLedger(root); !errors.As(err, &diverged) {
		t.Fatalf("ledger no longer refuses after a refused reconcile: %v", err)
	}
}

// The reconcile holds sqlite's SHARED lock: a legacy writer cannot commit
// between the read and the snapshot, so nothing it writes can be lost.
func TestReconcileLegacyNotDivergedIsNoop(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "real"), root)
	openLedger(t, root).Close()
	before := fileSHA(t, filepath.Join(root, ledgerLogName))
	report, err := ReconcileLegacy(context.Background(), root, true)
	if err != nil || report.Diverged || report.Applied || fileSHA(t, filepath.Join(root, ledgerLogName)) != before {
		t.Fatalf("clean ledger changed: err=%v report=%+v", err, report)
	}
	if _, err := ReconcileLegacy(context.Background(), "relative", true); err == nil {
		t.Fatal("relative root accepted")
	}
	empty := newLedgerRoot(t)
	if _, err := ReconcileLegacy(context.Background(), empty, true); err == nil {
		t.Fatal("reconcile without a ledger succeeded")
	}
	_ = os.Remove
}
