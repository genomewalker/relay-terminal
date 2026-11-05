package rotationtext

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func isPoisoned(err error) bool {
	var poisoned *errLedgerPoisoned
	return errors.As(err, &poisoned) && poisoned.Code() == "journal_poisoned"
}

// A commit whose fsync fails and whose frame cannot then be removed poisons
// the ledger before readers can see the frame: in this process at once, and
// in every process through the marker, until an operator repairs the log.
func TestLedgerFailedRollbackPoisonsTheLedger(t *testing.T) {
	root := newLedgerRoot(t)
	defer poisonedLedgers.Delete(root)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("old-committed"); err != nil {
		t.Fatal(err)
	}
	reader := openLedger(t, root)
	defer reader.Close()
	helper := helperProcess(t, "read-settings", "RT_LEDGER_ROOT="+root)
	input, _ := helper.StdinPipe()
	output, _ := helper.StdoutPipe()
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { input.Close(); helper.Wait() }()
	lines := bufio.NewReader(output)
	if line, _ := lines.ReadString('\n'); line != "ready\n" {
		t.Fatalf("helper = %q", line)
	}
	committed := writer.offset

	injected := errors.New("injected fsync failure")
	savedSync, savedTruncate := ledgerSync, ledgerTruncate
	defer func() { ledgerSync, ledgerTruncate = savedSync, savedTruncate }()
	ledgerSync = func(file *os.File) error {
		if file == writer.log {
			return injected
		}
		return savedSync(file)
	}
	ledgerTruncate = func(*os.File, int64) error { return errors.New("injected truncate failure") }
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := writer.UpdateSettings("", "new-uncommitted"); err != nil {
		t.Fatal(err)
	}
	err := writer.Commit()
	ledgerSync, ledgerTruncate = savedSync, savedTruncate
	if !isPoisoned(err) || !errors.Is(err, injected) {
		t.Fatalf("commit = %v", err)
	}
	if info, err := os.Stat(filepath.Join(root, ledgerLogName)); err != nil || info.Size() <= committed {
		t.Fatalf("the failed frame should still be in the log: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ledgerPoisonName))
	var marker map[string]int64
	if err != nil || json.Unmarshal(data, &marker) != nil || marker["offset"] != committed {
		t.Fatalf("marker = %q, %v", data, err)
	}

	refusals := func(t *testing.T, when string) {
		t.Helper()
		if _, value, _, err := reader.Settings(); !isPoisoned(err) {
			t.Fatalf("%s: reader saw %q, %v", when, value, err)
		}
		if err := reader.Begin(); !isPoisoned(err) {
			t.Fatalf("%s: begin = %v", when, err)
		}
		if ledger, err := OpenLedger(root); ledger != nil || !isPoisoned(err) {
			t.Fatalf("%s: open = %v", when, err)
		}
		reply, err := RunOperation(context.Background(), func() (*Journal, error) { return OpenLedgerJournal(context.Background(), root) },
			"status", []byte(`{}`))
		result, _ := parseJSON(reply).(obj)
		message, _ := result["message"].(string)
		if err != nil || result["code"] != "journal_poisoned" || !strings.Contains(message, filepath.Join(root, ledgerPoisonName)) {
			t.Fatalf("%s: status = %s, %v", when, reply, err)
		}
	}
	refusals(t, "poisoned")
	io.WriteString(input, "read\n")
	if line, _ := lines.ReadString('\n'); !strings.HasPrefix(line, "error: ") || !strings.Contains(line, "failed to commit") {
		t.Fatalf("reader in another process = %q", line)
	}

	// In this process the poison holds without the marker ...
	os.Rename(filepath.Join(root, ledgerPoisonName), filepath.Join(root, "marker"))
	refusals(t, "marker removed")
	// ... and the marker holds it for a process that never saw the failure.
	os.Rename(filepath.Join(root, "marker"), filepath.Join(root, ledgerPoisonName))
	poisonedLedgers.Delete(root)
	refusals(t, "after a restart")
	var poisoned *errLedgerPoisoned
	if _, _, _, err := reader.Settings(); !errors.As(err, &poisoned) || poisoned.offset != committed {
		t.Fatalf("the marker's committed length = %v", err)
	}

	// Recovery (a): the log cut back to the committed length.
	if err := os.Truncate(filepath.Join(root, ledgerLogName), committed); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(root, ledgerPoisonName))
	if _, value, _, err := reader.Settings(); err != nil || value != "old-committed" {
		t.Fatalf("after recovery: %q, %v", value, err)
	}
}

// A frame truncated without a durable fsync may come back after a crash: that
// poisons the ledger too.
func TestLedgerUnsyncedRollbackPoisons(t *testing.T) {
	root := newLedgerRoot(t)
	defer poisonedLedgers.Delete(root)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("old"); err != nil {
		t.Fatal(err)
	}
	saved := ledgerSync
	defer func() { ledgerSync = saved }()
	ledgerSync = func(file *os.File) error {
		if file == writer.log {
			return errors.New("injected fsync failure")
		}
		return saved(file)
	}
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	writer.UpdateSettings("", "new")
	if err := writer.Commit(); !isPoisoned(err) {
		t.Fatalf("commit = %v", err)
	}
	if _, err := os.Lstat(filepath.Join(root, ledgerPoisonName)); err != nil {
		t.Fatalf("marker: %v", err)
	}
}

// A failed fsync whose frame is removed rolls back without poisoning.
func TestLedgerFailedCommitThatRollsBackDoesNotPoison(t *testing.T) {
	root := newLedgerRoot(t)
	defer poisonedLedgers.Delete(root)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("old"); err != nil {
		t.Fatal(err)
	}
	saved := ledgerSync
	defer func() { ledgerSync = saved }()
	failed := false
	ledgerSync = func(file *os.File) error {
		if file == writer.log && !failed {
			failed = true
			return errors.New("injected fsync failure")
		}
		return saved(file)
	}
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	writer.UpdateSettings("", "new")
	if err := writer.Commit(); err == nil || isPoisoned(err) {
		t.Fatalf("commit = %v", err)
	}
	ledgerSync = saved
	if _, err := os.Lstat(filepath.Join(root, ledgerPoisonName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("marker: %v", err)
	}
	if _, value, _, err := writer.Settings(); err != nil || value != "old" {
		t.Fatalf("settings = %q, %v", value, err)
	}
}

// A compaction whose snapshot replaced the log but whose directory fsync
// failed reports a distinct durability-unknown error; the transaction is in
// the log, every ledger agrees, and repeating it cannot apply it twice.
func TestLedgerCompactionWithUnknownDurability(t *testing.T) {
	root := newLedgerRoot(t)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("0"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		if err := increment(writer); err != nil {
			t.Fatal(err)
		}
	}
	reader := openLedger(t, root)
	defer reader.Close()
	savedCap, savedSync := ledgerCap, ledgerSync
	defer func() { ledgerCap, ledgerSync = savedCap, savedSync }()
	ledgerCap = writer.offset + 16 // the next commit compacts
	injected := errors.New("injected directory fsync failure")
	ledgerSync = func(file *os.File) error {
		if file.Name() == root {
			return injected
		}
		return savedSync(file)
	}
	row := ledgerRow(1, "result")
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := writer.InsertOperation(row); err != nil {
		t.Fatal(err)
	}
	err := writer.Commit()
	ledgerSync = savedSync
	var unknown *errLedgerDurabilityUnknown
	if !errors.As(err, &unknown) || unknown.Code() != "journal_durability_unknown" || !errors.Is(err, injected) {
		t.Fatalf("commit = %v", err)
	}
	for name, ledger := range map[string]*Ledger{"writer": writer, "reader": reader} {
		if rows, err := ledger.Operations(); err != nil || len(rows) != 1 || rows[0].ID != row.ID {
			t.Fatalf("%s: %d rows, %v", name, len(rows), err)
		}
	}
	if writer.state.SettingsValue != "20" || len(writer.state.Rows) != 1 {
		t.Fatalf("writer state: %q, %d rows", writer.state.SettingsValue, len(writer.state.Rows))
	}
	// A retry of the same transaction finds it applied.
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := writer.InsertOperation(row); err == nil {
		t.Fatal("the retried insert applied twice")
	}
	writer.Rollback()
	reopened := openLedger(t, root)
	defer reopened.Close()
	if rows, err := reopened.Operations(); err != nil || len(rows) != 1 {
		t.Fatalf("reopened: %d rows, %v", len(rows), err)
	}
	if info, err := os.Stat(filepath.Join(root, ledgerLogName)); err != nil || info.Size() > ledgerCap {
		t.Fatalf("log was not compacted: %v", err)
	}
}

// A store failure keeps a ledger refusal's code through the journal.
func TestJournalKeepsLedgerRefusalCodes(t *testing.T) {
	for _, err := range []error{&errLedgerPoisoned{root: "/r"}, &errLedgerDurabilityUnknown{root: "/r"}, errors.New("plain")} {
		code := func() (code string) {
			defer func() {
				draft, _ := recoverPy(recover())
				if draft != nil {
					code = draft.code
				} else {
					code = "StoreError"
				}
			}()
			must(err)
			return ""
		}()
		want := "StoreError"
		var refusal ledgerRefusal
		if errors.As(err, &refusal) {
			want = refusal.Code()
		}
		if code != want {
			t.Fatalf("must(%T) = %q, want %q", err, code, want)
		}
	}
}
