package rotationtext

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The external sqlite3 CLI is a real legacy SQLite connection with the same
// DELETE/FULL journal settings and one-second busy timeout as the old fixture.
// Missing SQLite fails the suite: lock/rollback coverage must never be skipped.
func sqliteNative(t *testing.T) string {
	t.Helper()
	if path, err := exec.LookPath("sqlite3"); err == nil {
		return path
	}
	t.Fatal("sqlite3 is required for live legacy lock and hot-journal checks")
	return ""
}
func runLegacyClient(t *testing.T, sqlite, path, mode string) string {
	t.Helper()
	sql := ".bail on\n.timeout 1000\nPRAGMA journal_mode=DELETE;\nPRAGMA synchronous=FULL;\n"
	if mode == "read" {
		sql += "SELECT 'read ' || count(*) FROM operations;\n"
	} else {
		sql += "BEGIN IMMEDIATE;\nINSERT INTO configuration_changes VALUES ('ffffffffffffffffffffffffffffffff', '{}');\nCOMMIT;\nSELECT 'committed';\n"
	}
	command := exec.Command(sqlite, "-batch", path)
	command.Stdin = strings.NewReader(sql)
	output, err := command.CombinedOutput()
	value, parseErr := legacySQLResult(output, err != nil)
	if parseErr != nil {
		t.Fatalf("legacy SQLite client: %v; %v %s", err, parseErr, output)
	}
	return value
}

// While any ledger of this process is open, an older relayd's write to the
// legacy journal fails busy and changes nothing; its reads still work. After
// the last close the write commits, and the ledger then refuses to open.
func TestLedgerHoldsLegacyJournalAgainstLegacyWriters(t *testing.T) {
	sqlite := sqliteNative(t)
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "real"), root)
	legacy := filepath.Join(root, legacyJournalName)
	before := fileSHA(t, legacy)
	first, second := openLedger(t, root), openLedger(t, root)
	defer first.Close()
	defer second.Close()
	if got := runLegacyClient(t, sqlite, legacy, "write"); got != "error database is locked" {
		t.Fatalf("legacy write while held: %q", got)
	}
	if got := runLegacyClient(t, sqlite, legacy, "read"); !strings.HasPrefix(got, "read ") {
		t.Fatalf("legacy read while held: %q", got)
	}
	// Closing one ledger must not drop the process's lock for the other.
	first.Close()
	if got := runLegacyClient(t, sqlite, legacy, "write"); got != "error database is locked" {
		t.Fatalf("legacy write after one close: %q", got)
	}
	if fileSHA(t, legacy) != before {
		t.Fatal("a refused write changed the legacy journal")
	}
	if _, err := os.Lstat(legacy + "-journal"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a refused write left a journal behind")
	}
	second.Close()
	if got := runLegacyClient(t, sqlite, legacy, "write"); got != "committed" {
		t.Fatalf("legacy write after release: %q", got)
	}
	var diverged *errLedgerDiverged
	if _, err := OpenLedger(root); !errors.As(err, &diverged) {
		t.Fatalf("ledger opened over a diverged legacy journal: %v", err)
	}
}

// sqlite's own rollback of the hot journal the import applied in memory is
// not divergence: the file then holds exactly the imported image.
func TestLedgerAcceptsSQLiteRollbackOfTheImportedHotJournal(t *testing.T) {
	sqlite := sqliteNative(t)
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "hot"), root)
	legacy := filepath.Join(root, legacyJournalName)
	before := fileSHA(t, legacy)
	ledger := openLedger(t, root)
	defer ledger.Close()
	rows := rowCount(t, ledger)
	// A hot journal needs EXCLUSIVE to roll back; held SHARED defers it.
	if got := runLegacyClient(t, sqlite, legacy, "read"); got != "error database is locked" {
		t.Fatalf("legacy rollback while held: %q", got)
	}
	ledger.Close()
	if got := runLegacyClient(t, sqlite, legacy, "read"); got != "read 13" {
		t.Fatalf("legacy rollback: %q", got)
	}
	if fileSHA(t, legacy) == before {
		t.Fatal("sqlite did not roll the hot journal back")
	}
	reopened := openLedger(t, root)
	defer reopened.Close()
	if rowCount(t, reopened) != rows || reopened.Import().RolledBackSHA256 != fileSHA(t, legacy) {
		t.Fatal("the rolled-back legacy journal was not accepted as imported")
	}
}

func TestLedgerDivergence(t *testing.T) {
	source := fixtureDir(t, "real")
	imported := func(t *testing.T) (string, string) {
		root := newLedgerRoot(t)
		copyFixture(t, source, root)
		openLedger(t, root).Close()
		return root, filepath.Join(root, legacyJournalName)
	}
	diverged := func(t *testing.T, root string) {
		t.Helper()
		var err error
		ledger, err := OpenLedger(root)
		var coded *errLedgerDiverged
		if !errors.As(err, &coded) || coded.Code() != "journal_diverged" {
			if ledger != nil {
				ledger.Close()
			}
			t.Fatalf("diverged legacy journal opened: %v", err)
		}
	}
	t.Run("unchanged", func(t *testing.T) {
		root, _ := imported(t)
		openLedger(t, root).Close()
	})
	t.Run("mtime only", func(t *testing.T) {
		root, legacy := imported(t)
		later := time.Now().Add(time.Hour)
		os.Chtimes(legacy, later, later)
		ledger := openLedger(t, root)
		defer ledger.Close()
		if ledger.Import().MTime == later.UnixNano() {
			t.Fatal("the import marker followed the file")
		}
	})
	t.Run("content changed", func(t *testing.T) {
		root, legacy := imported(t)
		data, _ := os.ReadFile(legacy)
		data[len(data)-1] ^= 0x01 // same size
		os.WriteFile(legacy, data, 0o600)
		diverged(t, root)
	})
	t.Run("grown", func(t *testing.T) {
		root, legacy := imported(t)
		data, _ := os.ReadFile(legacy)
		os.WriteFile(legacy, append(data, make([]byte, 4096)...), 0o600)
		diverged(t, root)
	})
	t.Run("set aside", func(t *testing.T) {
		root, legacy := imported(t)
		os.Rename(legacy, legacy+".aside")
		openLedger(t, root).Close()
	})
	t.Run("appeared after a fresh ledger", func(t *testing.T) {
		root := newLedgerRoot(t)
		openLedger(t, root).Close()
		data, _ := os.ReadFile(filepath.Join(source, legacyJournalName))
		os.WriteFile(filepath.Join(root, legacyJournalName), data, 0o600)
		diverged(t, root)
	})
	t.Run("operation result names both files", func(t *testing.T) {
		root, legacy := imported(t)
		os.WriteFile(legacy, nil, 0o600)
		reply, err := RunOperation(context.Background(), func() (*Journal, error) { return OpenLedgerJournal(context.Background(), root) },
			"status", []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		result, _ := parseJSON(reply).(obj)
		message, _ := result["message"].(string)
		if result["status"] != "failed" || result["code"] != "journal_diverged" ||
			!strings.Contains(message, legacy) || !strings.Contains(message, filepath.Join(root, ledgerLogName)) {
			t.Fatalf("diverged status: %s", reply)
		}
	})
}

// Lock waits are bounded by the operation's context as well as by the busy
// timeout: a cancelled operation never waits out the five seconds.
func TestLedgerLockWaitsEndWithTheContext(t *testing.T) {
	cancelled := func(t *testing.T, wait func(ctx context.Context) error) {
		t.Helper()
		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(100*time.Millisecond, cancel)
		began := time.Now()
		if err := wait(ctx); !errors.Is(err, context.Canceled) {
			t.Fatalf("wait = %v", err)
		}
		if elapsed := time.Since(began); elapsed > 2*time.Second {
			t.Fatalf("cancelled wait took %v", elapsed)
		}
	}
	t.Run("ledger lock at open and at begin", func(t *testing.T) {
		root := newLedgerRoot(t)
		holder := openLedger(t, root)
		defer holder.Close()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		waiter, err := OpenLedgerContext(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		defer waiter.Close()
		if err := holder.Begin(); err != nil {
			t.Fatal(err)
		}
		defer holder.Rollback()
		cancelled(t, func(ctx context.Context) error {
			ledger, err := OpenLedgerContext(ctx, root)
			if err == nil {
				ledger.Close()
			}
			return err
		})
		go func() { time.Sleep(100 * time.Millisecond); cancel() }()
		began := time.Now()
		if err := waiter.Begin(); !errors.Is(err, context.Canceled) || time.Since(began) > 2*time.Second {
			t.Fatalf("begin = %v after %v", err, time.Since(began))
		}
	})
	t.Run("legacy journal shared lock", func(t *testing.T) {
		root := newLedgerRoot(t)
		copyFixture(t, fixtureDir(t, "real"), root)
		path := filepath.Join(root, legacyJournalName)
		// A legacy writer committing holds PENDING, which blocks new SHARED.
		command := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+path, "RT_LEDGER_BYTE="+strconv.FormatInt(sqlitePendingByte, 10))
		stdin, _ := command.StdinPipe()
		stdout, _ := command.StdoutPipe()
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() { stdin.Close(); command.Wait() }()
		if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "locked\n" {
			t.Fatalf("helper lock: %q", line)
		}
		cancelled(t, func(ctx context.Context) error {
			ledger, err := OpenLedgerContext(ctx, root)
			if err == nil {
				ledger.Close()
			}
			return err
		})
	})
}
