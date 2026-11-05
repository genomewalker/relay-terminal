package rotationtext

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The database uint16 sentinel must never be applied to the journal's uint32
// actual-size field. Enumerate every value through the upper neighbor.
func TestSQLiteJournalPageSizeExhaustive(t *testing.T) {
	valid := map[uint32]int{512: 512, 1024: 1024, 2048: 2048, 4096: 4096, 8192: 8192, 16384: 16384, 32768: 32768, 65536: 65536}
	header := make([]byte, 28)
	for raw := uint32(0); raw <= 65537; raw++ {
		binary.BigEndian.PutUint32(header[24:], raw)
		if got := sqliteJournalPageSize(header); got != valid[raw] {
			t.Fatalf("journal uint32 page size %d: got %d want %d", raw, got, valid[raw])
		}
	}
	for _, raw := range []uint32{131072, 0x80000000, 0xffffffff} {
		binary.BigEndian.PutUint32(header[24:], raw)
		if got := sqliteJournalPageSize(header); got != 0 {
			t.Fatalf("oversize journal field %d accepted as %d", raw, got)
		}
	}
	binary.BigEndian.PutUint32(header[24:], 65536)
	for n := 0; n < 28; n++ {
		if got := sqliteJournalPageSize(header[:n]); got != 0 {
			t.Fatalf("truncated %d-byte header accepted as %d", n, got)
		}
	}
	if sqlitePageSize(1) != 65536 {
		t.Fatal("the separate database sentinel contract changed")
	}
	t.Log("journal actual uint32: 65538 values (0..65537), 3 high values, 28 truncated lengths; database sentinel kept separate")
}

func FuzzSQLiteJournalPageSize(f *testing.F) {
	for _, size := range []uint32{0, 1, 511, 512, 4096, 32768, 65535, 65536, 65537, 0xffffffff} {
		header := make([]byte, 28)
		copy(header, sqliteJournalMagic)
		binary.BigEndian.PutUint32(header[24:], size)
		f.Add(header)
	}
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, raw []byte) {
		// The oracle is the format's explicit finite set, independent of the
		// implementation's range/power-of-two calculation and uint16 decoder.
		want := 0
		if len(raw) >= 28 {
			switch binary.BigEndian.Uint32(raw[24:28]) {
			case 512:
				want = 512
			case 1024:
				want = 1024
			case 2048:
				want = 2048
			case 4096:
				want = 4096
			case 8192:
				want = 8192
			case 16384:
				want = 16384
			case 32768:
				want = 32768
			case 65536:
				want = 65536
			}
		}
		if got := sqliteJournalPageSize(raw); got != want {
			t.Fatalf("journal field decoder got %d want %d (bytes=%d)", got, want, len(raw))
		}
		if len(raw) >= 28 {
			for n := 0; n < 28; n++ {
				if sqliteJournalPageSize(raw[:n]) != 0 {
					t.Fatalf("truncated journal header accepted at %d", n)
				}
			}
		}
	})
}

// These compressed fixtures were produced by native SQLite 3.51.0 from private
// synthetic data, with sqlite3_db_cacheflush followed by abrupt writer exit.
// They contain no user journal or provider material. Hashes pin actual bytes.
func sqlite64Fixture(t *testing.T, name string) []byte {
	t.Helper()
	hashes := map[string]string{
		"journal.sqlite3":         "8b6bb9dc6b3ad24858a3d0575dc090bb7b56becbc0d9cf998285fef7fb5c0333",
		"journal.sqlite3-journal": "f90b001a3d54b40b335a102310f849b75735374e5589c65ee280e6528ea1d7cb",
		"committed.sqlite3":       "f2d7174ff587dcf850a42dc35535680ea3d109fcdb06d02521fbef1c71caba50",
	}
	encoded, err := os.ReadFile(filepath.Join("testdata", "ledger", "hot64k", name+".gz.b64"))
	if err != nil {
		t.Fatal(err)
	}
	compressed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	raw, err := io.ReadAll(io.LimitReader(reader, sqliteMaxFile+1))
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > sqliteMaxFile || bytesSHA256(raw) != hashes[name] {
		t.Fatalf("native SQLite 64K fixture identity changed: %s", name)
	}
	return raw
}
func sqlite64ExpectedState() *ledgerState {
	state := newLedgerState()
	state.HasSettings = true
	state.SettingsID = strings.Repeat("a", 32)
	state.SettingsValue = "committed-settings-64k"
	state.Changes = []ledgerChange{{ID: strings.Repeat("b", 32), Value: "committed-change-64k"}}
	state.changes[strings.Repeat("b", 32)] = 0
	for n := 1; n <= 3; n++ {
		state.ids[fmt.Sprintf("%032x", n)] = n - 1
		state.fingerprints[fmt.Sprintf("%064x", n)] = n - 1
		result := fmt.Sprintf("committed-result-%d", n)
		state.Rows = append(state.Rows, Operation{ID: fmt.Sprintf("%032x", n), Fingerprint: fmt.Sprintf("%064x", n), SettingsDigest: fmt.Sprintf("%064x", n+100), State: "pending", Day: "2026-10-25", Month: "2026-10", Reserved: 1000000, Charged: 1000000, Result: &result})
	}
	return state
}
func sqlite64WriteSource(t *testing.T, damaged bool) (string, []byte, []byte) {
	t.Helper()
	root := newLedgerRoot(t)
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	db, journal := sqlite64Fixture(t, "journal.sqlite3"), sqlite64Fixture(t, "journal.sqlite3-journal")
	if binary.BigEndian.Uint16(db[16:18]) != 1 || binary.BigEndian.Uint32(journal[24:28]) != 65536 || !bytes.Equal(journal[:8], sqliteJournalMagic) {
		t.Fatal("primary fixture does not distinguish database sentinel and journal actual size")
	}
	if damaged {
		clear(db[:18])
	}
	for name, data := range map[string][]byte{legacyJournalName: db, legacyJournalName + "-journal": journal} {
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root, db, journal
}
func sqlite64Unchanged(t *testing.T, root string, db, journal []byte) {
	t.Helper()
	for name, want := range map[string][]byte{legacyJournalName: db, legacyJournalName + "-journal": journal} {
		got, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("native import changed legacy source %s: %v", name, err)
		}
	}
}
func sqlite64CheckImport(t *testing.T, damaged bool) (string, *legacyImport, []byte, []byte) {
	t.Helper()
	root, db, journal := sqlite64WriteSource(t, damaged)
	imported, err := readLegacyJournal(filepath.Join(root, legacyJournalName), time.Second)
	if err != nil {
		t.Fatalf("native SQLite 64K hot journal import: %v", err)
	}
	expected := sqlite64ExpectedState()
	if imported.hotJournalPages == 0 || !reflect.DeepEqual(imported.state, expected) {
		t.Fatalf("64K recovery did not restore exact committed settings, configuration, rows and results: pages=%d got=%#v", imported.hotJournalPages, imported.state)
	}
	committed := sqlite64Fixture(t, "committed.sqlite3")
	if imported.rolledBackSHA256 != bytesSHA256(committed) {
		t.Fatal("native in-memory rollback differs from committed primary bytes")
	}
	sqlite64Unchanged(t, root, db, journal)
	ledger, err := OpenLedger(root)
	if err != nil {
		t.Fatalf("64K hot journal ledger import: %v", err)
	}
	if !reflect.DeepEqual(ledger.state, expected) || ledger.Import().HotJournalPages == 0 || ledger.Import().SHA256 != bytesSHA256(db) {
		ledger.Close()
		t.Fatal("durable native ledger import lost committed state or source identity")
	}
	if err := ledger.Close(); err != nil {
		t.Fatal(err)
	}
	sqlite64Unchanged(t, root, db, journal)
	return root, imported, db, journal
}
func TestSQLite64KHotJournalDamagedHeader(t *testing.T) {
	sqlite64CheckImport(t, true)
}
func TestSQLite64KHotJournalNativeRecovery(t *testing.T) {
	root, imported, db, journal := sqlite64CheckImport(t, false)
	// A separate copy is opened by the native SQLite CLI, which performs its
	// own real rollback. The Go parser/ledger never writes either source file.
	reference := t.TempDir()
	path := filepath.Join(reference, legacyJournalName)
	if err := os.WriteFile(path, db, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+"-journal", journal, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, sqliteNative(t), "-batch", path)
	command.Stdin = strings.NewReader(".bail on\n.timeout 1000\n.headers off\n.mode list\nSELECT 'settings',singleton,operation_id,value FROM settings ORDER BY singleton;\nSELECT 'change',id,value FROM configuration_changes ORDER BY id;\nSELECT 'operation',id,fingerprint,settings_digest,state,day,month,reserved,charged,result FROM operations ORDER BY id;\n")
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("primary native SQLite rollback: %v %s", err, out)
	}
	expected := "settings|1|" + strings.Repeat("a", 32) + "|committed-settings-64k\nchange|" + strings.Repeat("b", 32) + "|committed-change-64k\n"
	for n := 1; n <= 3; n++ {
		expected += fmt.Sprintf("operation|%032x|%064x|%064x|pending|2026-10-25|2026-10|1000000|1000000|committed-result-%d\n", n, n, n+100, n)
	}
	if string(out) != expected {
		t.Fatalf("primary SQLite exact committed rows/results changed: %q", out)
	}
	recovered, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytesSHA256(recovered) != imported.rolledBackSHA256 || !bytes.Equal(recovered, sqlite64Fixture(t, "committed.sqlite3")) {
		t.Fatal("native SQLite rollback bytes differ from native import and committed primary snapshot")
	}
	if _, err := os.Lstat(path + "-journal"); !os.IsNotExist(err) {
		t.Fatalf("SQLite did not remove hot journal after primary recovery: %v", err)
	}
	sqlite64Unchanged(t, root, db, journal)
	t.Logf("primary native SQLite 64K recovery: restored %d journal pages, 3 exact operation rows/results, settings/configuration, source unchanged, rollback sha256=%s", imported.hotJournalPages, imported.rolledBackSHA256)
}
