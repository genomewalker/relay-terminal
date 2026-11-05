package rotationtext

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Optional arbitrary-copy checks retain a real SQLite storage oracle. Journal
// semantics are trusted here and separately checked by the pinned canonical
// corpus; this deliberately does not claim a second independent engine.
type sqliteReference struct {
	command             *exec.Cmd
	input               io.WriteCloser
	output              *bufio.Reader
	stderr              bytes.Buffer
	serial              uint64
	transaction, closed bool
}

func decodeSQLiteReferenceRows(raw []byte) (rows []any, err error) {
	defer func() {
		if recover() != nil {
			rows = nil
			err = errors.New("invalid SQLite JSON rows")
		}
	}()
	if len(bytes.TrimSpace(raw)) == 0 {
		return []any{}, nil
	}
	value := parseJSON(raw)
	rows, ok := value.([]any)
	if !ok {
		return nil, errors.New("SQLite result is not rows")
	}
	for _, row := range rows {
		if _, ok := row.(obj); !ok {
			return nil, errors.New("SQLite row is not an object")
		}
	}
	return rows, nil
}
func openSQLiteReference(t *testing.T, root string) *sqliteReference {
	t.Helper()
	client := &sqliteReference{}
	client.command = exec.Command(sqliteNative(t), "-batch", filepath.Join(root, legacyJournalName))
	client.command.Stderr = &client.stderr
	var err error
	client.input, err = client.command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := client.command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	client.output = bufio.NewReader(output)
	if err = client.command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	if _, err = io.WriteString(client.input, ".bail on\n.timeout 5000\n.mode json\n"); err != nil {
		t.Fatal(err)
	}
	return client
}
func (s *sqliteReference) rawQuery(sql, mode string) ([]byte, error) {
	if s.closed {
		return nil, errors.New("closed SQLite reference")
	}
	s.serial++
	marker := fmt.Sprintf("__relay_sqlite_end_%d__", s.serial)
	if _, err := io.WriteString(s.input, ".mode "+mode+"\n"+sql+";\n.print "+marker+"\n"); err != nil {
		return nil, err
	}
	var raw bytes.Buffer
	for {
		line, err := s.output.ReadString('\n')
		if err != nil {
			s.input.Close()
			s.command.Wait()
			s.closed = true
			return nil, errors.New("SQLite reference command failed")
		}
		if strings.TrimSuffix(line, "\n") == marker {
			break
		}
		raw.WriteString(line)
	}
	return raw.Bytes(), nil
}

func (s *sqliteReference) query(sql string) ([]any, error) {
	raw, err := s.rawQuery(sql, "json")
	if err != nil {
		return nil, err
	}
	return decodeSQLiteReferenceRows(raw)
}

// SQLite shell's direct JSON printer truncates TEXT at embedded NUL. JSON1
// encodes the value inside SQLite first, preserving exact TEXT bytes/values.
func (s *sqliteReference) jsonQuery(sql string, columns []string) ([]any, error) {
	parts := []string{}
	for _, column := range columns {
		parts = append(parts, sqlText(column), "canonical.\""+strings.ReplaceAll(column, "\"", "\"\"")+"\"")
	}
	raw, err := s.rawQuery("SELECT json_group_array(json_object("+strings.Join(parts, ",")+")) AS canonical_json FROM ("+sql+") AS canonical", "list")
	if err != nil {
		return nil, err
	}
	return decodeSQLiteReferenceRows(raw)
}
func (s *sqliteReference) tableRows(table, sql string) ([]any, error) {
	rows, err := s.query("PRAGMA table_info(\"" + strings.ReplaceAll(table, "\"", "\"\"") + "\")")
	if err != nil {
		return nil, err
	}
	columns := []string{}
	for _, raw := range rows {
		columns = append(columns, raw.(obj)["name"].(string))
	}
	return s.jsonQuery(sql, columns)
}
func sqlText(value string) string {
	return "CAST(X'" + hex.EncodeToString([]byte(value)) + "' AS TEXT)"
}
func (s *sqliteReference) statement(sql string) error { _, err := s.query(sql); return err }
func (s *sqliteReference) initialize() error {
	for _, sql := range []string{"PRAGMA trusted_schema=OFF", "PRAGMA journal_mode=DELETE", "PRAGMA synchronous=FULL", "PRAGMA max_page_count=16384", `CREATE TABLE IF NOT EXISTS settings(singleton INTEGER PRIMARY KEY CHECK(singleton=1), operation_id TEXT NOT NULL,value TEXT NOT NULL)`, `CREATE TABLE IF NOT EXISTS configuration_changes(id TEXT PRIMARY KEY,value TEXT NOT NULL)`, `CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,fingerprint TEXT UNIQUE NOT NULL,settings_digest TEXT NOT NULL,state TEXT NOT NULL,day TEXT NOT NULL,month TEXT NOT NULL,reserved INTEGER NOT NULL,charged INTEGER NOT NULL,result TEXT)`} {
		if err := s.statement(sql); err != nil {
			return err
		}
	}
	rows, err := s.query("PRAGMA table_info(operations)")
	if err != nil {
		return err
	}
	columns := map[string]bool{}
	for _, raw := range rows {
		columns[raw.(obj)["name"].(string)] = true
	}
	if err := s.Begin(); err != nil {
		return err
	}
	for _, name := range []string{"account_id", "billing_group", "purpose", "request_id"} {
		if !columns[name] {
			if err := s.statement("ALTER TABLE operations ADD COLUMN " + name + " TEXT NOT NULL DEFAULT ''"); err != nil {
				return err
			}
		}
	}
	return s.Commit()
}
func (s *sqliteReference) Begin() error {
	if err := s.statement("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	s.transaction = true
	return nil
}
func (s *sqliteReference) Commit() error {
	if err := s.statement("COMMIT"); err != nil {
		return err
	}
	s.transaction = false
	return nil
}
func (s *sqliteReference) Rollback() error {
	if err := s.statement("ROLLBACK"); err != nil {
		return err
	}
	s.transaction = false
	return nil
}
func (s *sqliteReference) InTransaction() bool { return s.transaction }
func (s *sqliteReference) InitSettings(value string) error {
	return s.statement("INSERT OR IGNORE INTO settings VALUES(1,''," + sqlText(value) + ")")
}
func (s *sqliteReference) Settings() (string, string, bool, error) {
	rows, err := s.jsonQuery("SELECT operation_id,value FROM settings WHERE singleton=1", []string{"operation_id", "value"})
	if err != nil || len(rows) == 0 {
		return "", "", false, err
	}
	row := rows[0].(obj)
	return row["operation_id"].(string), row["value"].(string), true, nil
}
func (s *sqliteReference) UpdateSettings(id, value string) error {
	return s.statement("UPDATE settings SET operation_id=" + sqlText(id) + ",value=" + sqlText(value) + " WHERE singleton=1")
}
func (s *sqliteReference) ConfigurationChange(id string) (string, bool, error) {
	rows, err := s.jsonQuery("SELECT value FROM configuration_changes WHERE id="+sqlText(id), []string{"value"})
	if err != nil || len(rows) == 0 {
		return "", false, err
	}
	return rows[0].(obj)["value"].(string), true, nil
}
func (s *sqliteReference) InsertConfigurationChange(id, value string) error {
	return s.statement("INSERT INTO configuration_changes VALUES(" + sqlText(id) + "," + sqlText(value) + ")")
}
func (s *sqliteReference) Operations() ([]Operation, error) {
	rows, err := s.tableRows("operations", "SELECT * FROM operations ORDER BY rowid")
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(rows)
	if err != nil {
		return nil, err
	}
	var out []Operation
	err = json.Unmarshal(data, &out)
	return out, err
}
func (s *sqliteReference) InsertOperation(row Operation) error {
	result := "NULL"
	if row.Result != nil {
		result = sqlText(*row.Result)
	}
	values := []string{sqlText(row.ID), sqlText(row.Fingerprint), sqlText(row.SettingsDigest), sqlText(row.State), sqlText(row.Day), sqlText(row.Month), fmt.Sprint(row.Reserved), fmt.Sprint(row.Charged), result, sqlText(row.AccountID), sqlText(row.BillingGroup), sqlText(row.Purpose), sqlText(row.RequestID)}
	return s.statement("INSERT INTO operations(id,fingerprint,settings_digest,state,day,month,reserved,charged,result,account_id,billing_group,purpose,request_id) VALUES(" + strings.Join(values, ",") + ")")
}
func (s *sqliteReference) FinishOperation(id, state string, charged int64, result string) error {
	return s.statement("UPDATE operations SET state=" + sqlText(state) + ",charged=" + fmt.Sprint(charged) + ",result=" + sqlText(result) + " WHERE id=" + sqlText(id) + " AND state='pending'")
}
func (s *sqliteReference) AbandonOperation(id string) error {
	return s.statement("UPDATE operations SET state='abandoned' WHERE id=" + sqlText(id) + " AND state IN ('pending','uncertain')")
}
func (s *sqliteReference) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	s.input.Close()
	return s.command.Wait()
}
func sqliteReferenceDump(t *testing.T, fixture string) any {
	t.Helper()
	root := filepath.Join(t.TempDir(), "rotation-text")
	copyFixture(t, fixture, root)
	client := openSQLiteReference(t, root)
	defer client.Close()
	rows, err := client.query("SELECT name FROM sqlite_master WHERE type='table'")
	if err != nil {
		t.Fatal(err)
	}
	tables := map[string]bool{}
	for _, raw := range rows {
		tables[raw.(obj)["name"].(string)] = true
	}
	out := obj{"settings": nil, "changes": []any{}, "operations": []any{}}
	if tables["settings"] {
		rows, err = client.jsonQuery("SELECT rowid AS canonical_rowid,operation_id,value FROM settings ORDER BY rowid", []string{"canonical_rowid", "operation_id", "value"})
		if err != nil {
			t.Fatal(err)
		}
		for _, raw := range rows {
			row := raw.(obj)
			out["settings"] = []any{row["canonical_rowid"], row["operation_id"], row["value"]}
		}
	}
	if tables["configuration_changes"] {
		rows, err = client.jsonQuery("SELECT id,value FROM configuration_changes ORDER BY rowid", []string{"id", "value"})
		if err != nil {
			t.Fatal(err)
		}
		for _, raw := range rows {
			row := raw.(obj)
			out["changes"] = append(out["changes"].([]any), []any{row["id"], row["value"]})
		}
	}
	if tables["operations"] {
		rows, err = client.tableRows("operations", "SELECT * FROM operations ORDER BY rowid")
		if err != nil {
			t.Fatal(err)
		}
		for _, raw := range rows {
			row := raw.(obj)
			for _, name := range []string{"account_id", "billing_group", "purpose", "request_id"} {
				if _, exists := row[name]; !exists {
					row[name] = ""
				}
			}
			out["operations"] = append(out["operations"].([]any), row)
		}
	}
	return out
}
func TestNativeSQLiteReferenceAgainstCanonicalFixtures(t *testing.T) {
	f := newCLIFixture(t)
	for i, name := range ledgerFixtures {
		fixture := fixtureDir(t, name)
		dump := oracleCase{Fn: "sqlite_dump", Fixture: fixture}
		baseline := runGo(t, dump)
		dump.nativeSQLite = true
		native := runGo(t, dump)
		if compact(baseline) != compact(native) {
			t.Fatalf("native SQLite row oracle differs for %s", name)
		}
		c := continuation(f, "native-SQLite-"+name, fixture)
		// The exact independent canonical output is already pinned under the
		// original continuation test's index. Reuse its input and corpus record.
		b, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		expected := referenceLookup(t, fmt.Sprint(i), string(b), caseRoots(c), c.Env, c.Unset, nil, fmt.Sprintf("TestDifferentialLedgerContinuation/%d", i))
		c.nativeSQLite = true
		got := runGo(t, c)
		if compact(parseJSON(expected)) != compact(finite(got)) {
			t.Fatalf("native SQLite continuation differs from canonical %s", name)
		}
	}
}
func FuzzSQLiteReferenceRows(f *testing.F) {
	for _, raw := range []string{"", `[]`, `[{"id":"x","charged":3,"result":null}]`, `[{"value":"\\u0000"}]`, `[{`, `null`, `[1]`} {
		f.Add([]byte(raw))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		rows, err := decodeSQLiteReferenceRows(raw)
		if err != nil {
			return
		}

		encoded := asciiJSON(rows)
		again, err := decodeSQLiteReferenceRows([]byte(encoded))
		if err != nil || asciiJSON(rows) != asciiJSON(again) {
			t.Fatal("SQLite row/value/ID roundtrip changed")
		}
		if _, err := decodeSQLiteReferenceRows([]byte(encoded[:len(encoded)-1])); err == nil {
			t.Fatal("truncated SQLite rows accepted")
		}
	})
}

func TestSQLiteReferenceRowsRejectsInvalid(t *testing.T) {
	for _, raw := range []string{`null`, `[1]`, `[{`, `{"id":"x"}`, `[{"id":"x","id":"y"}]`} {
		if _, err := decodeSQLiteReferenceRows([]byte(raw)); err == nil {
			t.Fatalf("invalid SQLite rows accepted: %s", raw)
		}
	}
}
func TestSQLiteReferenceStoresExactValuesAndRollback(t *testing.T) {
	root := t.TempDir()
	client := openSQLiteReference(t, root)
	defer client.Close()
	if err := client.initialize(); err != nil {
		t.Fatal(err)
	}
	value := "quotes ' ; DROP TABLE operations;--\x00unicode é"
	if err := client.InitSettings(value); err != nil {
		t.Fatal(err)
	}
	_, got, ok, err := client.Settings()
	if err != nil || !ok || got != value {
		t.Fatal("SQLite text value changed")
	}
	if err := client.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := client.InsertConfigurationChange("quoted'key", value); err != nil {
		t.Fatal(err)
	}
	if err := client.Rollback(); err != nil {
		t.Fatal(err)
	}
	if _, exists, err := client.ConfigurationChange("quoted'key"); err != nil || exists {
		t.Fatal("SQLite rollback retained configuration")
	}
	for _, id := range []string{"one", "two"} {
		if err := client.InsertOperation(Operation{ID: id, Fingerprint: id, SettingsDigest: "digest", State: "pending", Day: "2026-10-25", Month: "2026-10", Reserved: 9, Charged: 9, AccountID: "account", BillingGroup: "group", Purpose: "purpose", RequestID: "request"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := client.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := client.FinishOperation("one", "committed", 7, value); err != nil {
		t.Fatal(err)
	}
	if err := client.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := client.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := client.AbandonOperation("two"); err != nil {
		t.Fatal(err)
	}
	if err := client.Rollback(); err != nil {
		t.Fatal(err)
	}
	rows, err := client.Operations()
	if err != nil || len(rows) != 2 || rows[0].ID != "one" || rows[0].Charged != 7 || rows[0].Result == nil || *rows[0].Result != value || rows[1].ID != "two" || rows[1].State != "pending" || rows[0].AccountID != "account" || rows[0].BillingGroup != "group" || rows[0].Purpose != "purpose" || rows[0].RequestID != "request" {
		t.Fatal("SQLite row/value/order/transaction semantics changed")
	}
}
