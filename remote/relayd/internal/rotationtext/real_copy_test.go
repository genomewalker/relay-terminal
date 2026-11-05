package rotationtext

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// RELAY_LEDGER_REAL_COPY names a copy of a host's rotation-text directory
// (never the live one). The import runs on a second private copy, so neither
// is written; only counts and hashes are logged, never journal values.
func realCopy(t *testing.T) string {
	source := os.Getenv("RELAY_LEDGER_REAL_COPY")
	if source == "" {
		t.Skip("RELAY_LEDGER_REAL_COPY unset")
	}
	return source
}

func directoryHashes(t *testing.T, dir string) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(data)
		out[entry.Name()] = hex.EncodeToString(sum[:])
	}
	return out
}

func TestLedgerRealCopyImport(t *testing.T) {
	source := realCopy(t)
	before := directoryHashes(t, source)
	root := filepath.Join(t.TempDir(), "rotation-text")
	copyFixture(t, source, root)
	imported, err := readLegacyJournal(filepath.Join(root, legacyJournalName), ledgerLockTimeout)
	if err != nil {
		t.Fatal(err)
	}
	states := map[string]int{}
	for _, row := range imported.state.Rows {
		states[row.State]++
	}
	names := []string{}
	for name := range states {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		t.Logf("state %s: %d", name, states[name])
	}
	t.Logf("operations %d, configuration changes %d, settings %v, hot journal pages %d, sqlite sha256 %s size %d",
		len(imported.state.Rows), len(imported.state.Changes), imported.state.HasSettings,
		imported.hotJournalPages, imported.sha256, imported.size)
	ledger, err := OpenLedger(root)
	if err != nil {
		t.Fatal(err)
	}
	marker := ledger.Import()
	if marker.SHA256 != imported.sha256 || marker.Size != imported.size || marker.Operations != len(imported.state.Rows) ||
		marker.ConfigurationChanges != len(imported.state.Changes) {
		t.Fatalf("import marker %+v differs from the source", marker)
	}
	if !reflect.DeepEqual(ledger.state.Rows, imported.state.Rows) || !reflect.DeepEqual(ledger.state.Changes, imported.state.Changes) ||
		ledger.state.SettingsValue != imported.state.SettingsValue || ledger.state.SettingsID != imported.state.SettingsID {
		t.Fatal("ledger state differs from the imported rows")
	}
	ledger.Close()
	info, err := os.Stat(filepath.Join(root, ledgerLogName))
	if err != nil {
		t.Fatal(err)
	}
	// A second open reads the marker and never imports again.
	again, err := OpenLedger(root)
	if err != nil {
		t.Fatal(err)
	}
	if again.Import() != marker {
		t.Fatal("reopened ledger re-imported")
	}
	again.Close()
	if after, err := os.Stat(filepath.Join(root, ledgerLogName)); err != nil || after.Size() != info.Size() {
		t.Fatal("reopening rewrote the ledger", err)
	}
	if got := directoryHashes(t, filepath.Join(root)); got[legacyJournalName] != before[legacyJournalName] {
		t.Fatal("import modified the private sqlite copy")
	}
	journal, err := OpenLedgerJournal(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	status := journal.Status(nil)
	journal.Close()
	usage := obj{}
	for _, key := range []string{"status", "enabled", "requests_today", "charged_today_microusd", "charged_month_microusd",
		"unresolved"} {
		if value, ok := status[key]; ok {
			usage[key] = value
		}
	}
	encoded, _ := json.Marshal(usage)
	t.Logf("status after import: %s (%d status keys)", encoded, len(status))
	if !reflect.DeepEqual(directoryHashes(t, source), before) {
		t.Fatal("the real copy changed")
	}
}

// The oracle over sqlite and the Go reader agree on every row of the real
// copy, and the same journal operations continue identically across the
// import (fake API only).
func TestLedgerRealCopyDifferential(t *testing.T) {
	source := realCopy(t)
	before := directoryHashes(t, source)
	fixture := filepath.Join(t.TempDir(), "real-copy")
	copyFixture(t, source, fixture)
	f := newCLIFixture(t)
	compareOracle(t, []oracleCase{{name: "dump-real-copy", Fn: "sqlite_dump", Fixture: fixture},
		continuation(f, "continue-real-copy", fixture)})
	if !reflect.DeepEqual(directoryHashes(t, source), before) {
		t.Fatal("the real copy changed")
	}
}
