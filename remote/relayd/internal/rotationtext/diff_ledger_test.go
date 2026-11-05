package rotationtext

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Legacy journals written by text_backend.py's TextJournal and by
// sqlite itself (testdata/gen_ledger_fixtures.py), as committed base64 text.
var ledgerFixtures = []string{"real", "pending", "fresh", "legacy-premigration", "legacy-migrated", "overflow-1k",
	"overflow-8k", "hot"}

// fixtureDir decodes one fixture into a private directory of its own.
func fixtureDir(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "fixture-"+name)
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	matches, err := filepath.Glob(filepath.Join("testdata", "ledger", name+".*.b64"))
	if err != nil || len(matches) == 0 {
		t.Fatalf("fixture %s missing", name)
	}
	for _, match := range matches {
		encoded, err := os.ReadFile(match)
		if err != nil {
			t.Fatal(err)
		}
		data, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(string(encoded), "\n", ""))
		if err != nil {
			t.Fatal(err)
		}
		file := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(match), name+"."), ".b64")
		if err := os.WriteFile(filepath.Join(dir, file), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// copyFixture makes target a private rotation-text directory holding a copy
// of source's files (none when source is empty).
func copyFixture(t *testing.T, source, target string) {
	t.Helper()
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if source == "" {
		return
	}
	entries, err := os.ReadDir(source)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(source, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(target, entry.Name()), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// goSQLiteDump is the oracle's sqlite_dump through the Go reader.
func goSQLiteDump(t *testing.T, fixture string) any {
	root := filepath.Join(t.TempDir(), "rotation-text")
	copyFixture(t, fixture, root)
	imported, err := readLegacyJournal(filepath.Join(root, legacyJournalName), ledgerLockTimeout)
	if err != nil {
		t.Logf("reader: %v", err)
		raise("OSError")
	}
	state := imported.state
	out := obj{"settings": nil, "changes": []any{}, "operations": []any{}}
	if state.HasSettings {
		out["settings"] = []any{int64(1), state.SettingsID, state.SettingsValue}
	}
	for _, change := range state.Changes {
		out["changes"] = append(out["changes"].([]any), []any{change.ID, change.Value})
	}
	for _, row := range state.Rows {
		var result any
		if row.Result != nil {
			result = *row.Result
		}
		out["operations"] = append(out["operations"].([]any), obj{"id": row.ID, "fingerprint": row.Fingerprint,
			"settings_digest": row.SettingsDigest, "state": row.State, "day": row.Day, "month": row.Month,
			"reserved": row.Reserved, "charged": row.Charged, "result": result, "account_id": row.AccountID,
			"billing_group": row.BillingGroup, "purpose": row.Purpose, "request_id": row.RequestID})
	}
	return out
}

// The Go reader returns exactly the rows sqlite returns, for every fixture.
func TestLedgerImportFidelity(t *testing.T) {
	cases := []oracleCase{}
	for _, name := range ledgerFixtures {
		cases = append(cases, oracleCase{name: "dump-" + name, Fn: "sqlite_dump", Fixture: fixtureDir(t, name)})
	}
	compareOracle(t, cases)
}

// continuation runs the same journal operations on the Python journal over
// the sqlite fixture and on the Go journal over the ledger imported from it:
// usage, the daily request and spending limits, reconciliation holds and the
// configuration identity must carry across the import. Drafts go through the
// real backend with a fake API; each accepted draft costs exactly its
// 1000000 reservation.
func continuation(f cliFixture, name, fixture string) oracleCase {
	steps := []oracleStep{
		jstep("status", obj{}),
		jstep("status", obj{"operation_id": fmt.Sprintf("%032x", 100)}),
		jstep("status", obj{"operation_id": fmt.Sprintf("%032x", 300)}),
		jstep("status", obj{"operation_id": fmt.Sprintf("%032x", 101)}),
	}
	submit := func(n int) {
		steps = append(steps, jstep("submit", submitRequest(fmt.Sprintf("%032x", 0x7000+n), fmt.Sprint("Continued evidence ", n, "."))))
	}
	for n := 0; n < 4; n++ {
		submit(n)
	}
	steps = append(steps, jstep("abandon", obj{"operation_id": fmt.Sprintf("%032x", 101)}), jstep("status", obj{}))
	// Reconfigure against the imported configuration identity, then use the room.
	settings := enabledSettings(obj{"max_requests_per_day": int64(200), "daily_limit_microusd": int64(9_000_000)})
	steps = append(steps,
		jstep("configure", obj{"operation_id": opID3, "settings": settings, "expected_configuration_id": fmt.Sprintf("%032x", 2)}),
		jstep("configure", obj{"operation_id": opID2, "settings": settings, "expected_configuration_id": fmt.Sprintf("%032x", 1)}))
	for n := 4; n < 16; n++ {
		submit(n)
	}
	steps = append(steps, jstep("status", obj{}))
	for n := 0; n < 2; n++ {
		steps = append(steps, jstep("assist", assistRequest(fmt.Sprintf("%032x", 0x7100+n), reqID,
			[]any{obj{"role": "user", "content": "Why is pane A held?"}})))
	}
	steps = append(steps, jstep("status", obj{}))
	api := []oracleAPI{}
	for n := 0; n < 18; n++ {
		api = append(api, apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()}}, "end_turn",
			obj{"usage": obj{"input_tokens": int64(0), "output_tokens": int64(2_000_000)}})))
	}
	c := journalCase(name, f, "draft", steps, nil, api...)
	c.Fixture = fixture
	return c
}

func TestDifferentialLedgerContinuation(t *testing.T) {
	f := newCLIFixture(t)
	cases := []oracleCase{}
	for _, name := range ledgerFixtures {
		cases = append(cases, continuation(f, "continue-"+name, fixtureDir(t, name)))
	}
	compareOracle(t, cases)
}
