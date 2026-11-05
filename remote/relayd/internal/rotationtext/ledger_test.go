package rotationtext

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func newLedgerRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "rotation-text")
	return root
}

func openLedger(t *testing.T, root string) *Ledger {
	t.Helper()
	ledger, err := OpenLedger(root)
	if err != nil {
		t.Fatal(err)
	}
	return ledger
}

func ledgerRow(n int, result string) Operation {
	r := result
	return Operation{ID: fmt.Sprintf("%032x", n), Fingerprint: fmt.Sprintf("%064x", n), SettingsDigest: strings.Repeat("d", 64),
		State: "pending", Day: "2026-10-21", Month: "2026-10", Reserved: 1_000_000, Charged: 1_000_000, Result: &r}
}

func insertRows(t *testing.T, ledger *Ledger, first, count int, result string) {
	t.Helper()
	for n := first; n < first+count; n++ {
		if err := ledger.Begin(); err != nil {
			t.Fatal(err)
		}
		if err := ledger.InsertOperation(ledgerRow(n, result)); err != nil {
			t.Fatal(err)
		}
		if err := ledger.Commit(); err != nil {
			t.Fatal(err)
		}
	}
}

func rowCount(t *testing.T, ledger *Ledger) int {
	t.Helper()
	rows, err := ledger.Operations()
	if err != nil {
		t.Fatal(err)
	}
	return len(rows)
}

func fileSHA(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// increment is one read-modify-write transaction on the settings counter.
func increment(ledger *Ledger) error {
	if err := ledger.Begin(); err != nil {
		return err
	}
	_, value, _, err := ledger.Settings()
	if err == nil {
		var n int
		n, err = strconv.Atoi(value)
		if err == nil {
			err = ledger.UpdateSettings("", strconv.Itoa(n+1))
		}
	}
	if err != nil {
		ledger.Rollback()
		return err
	}
	return ledger.Commit()
}

// TestLedgerHelperProcess is a second relayd process for the cross-process
// tests; it does nothing unless RT_LEDGER_HELPER is set.
func TestLedgerHelperProcess(t *testing.T) {
	mode := os.Getenv("RT_LEDGER_HELPER")
	if mode == "" {
		return
	}
	root := os.Getenv("RT_LEDGER_ROOT")
	switch mode {
	case "increment":
		ledger, err := OpenLedger(root)
		if err != nil {
			fmt.Println("open:", err)
			os.Exit(2)
		}
		count, _ := strconv.Atoi(os.Getenv("RT_LEDGER_COUNT"))
		for i := 0; i < count; i++ {
			if err := increment(ledger); err != nil {
				fmt.Println("increment:", err)
				os.Exit(2)
			}
		}
		fmt.Println("done")
	case "commit-forever":
		ledger, err := OpenLedger(root)
		if err != nil {
			os.Exit(2)
		}
		first, _ := strconv.Atoi(os.Getenv("RT_LEDGER_FIRST"))
		for n := first; ; n++ {
			if ledger.Begin() != nil || ledger.InsertOperation(ledgerRow(n, strings.Repeat("x", 3000))) != nil || ledger.Commit() != nil {
				os.Exit(2)
			}
			fmt.Println(n) // printed only after the commit is durable
		}
	case "legacy-commit":
		// An older relayd's BEGIN IMMEDIATE ... COMMIT, locked as sqlite's unix
		// VFS locks it (os_unix.c byte offsets): SHARED, RESERVED, then PENDING
		// and EXCLUSIVE on the shared range to write the database file.
		file, err := os.OpenFile(os.Getenv("RT_LEDGER_FILE"), os.O_RDWR, 0)
		if err != nil {
			os.Exit(2)
		}
		lock := func(kind int16, start, length int64) bool {
			range_ := syscall.Flock_t{Type: kind, Whence: io.SeekStart, Start: start, Len: length}
			return syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, &range_) == nil
		}
		const pending, reserved, shared, sharedSize = 0x40000000, 0x40000001, 0x40000002, 510
		switch {
		case !lock(syscall.F_RDLCK, pending, 1) || !lock(syscall.F_RDLCK, shared, sharedSize) || !lock(syscall.F_UNLCK, pending, 1):
			fmt.Println("busy shared")
		case !lock(syscall.F_WRLCK, reserved, 1):
			fmt.Println("busy reserved")
		case !lock(syscall.F_WRLCK, pending, 1):
			fmt.Println("busy pending")
		case !lock(syscall.F_WRLCK, shared, sharedSize):
			fmt.Println("busy")
		default:
			fmt.Println("exclusive")
		}
	case "sqlite-lock":
		file, err := os.OpenFile(os.Getenv("RT_LEDGER_FILE"), os.O_RDWR, 0)
		if err != nil {
			os.Exit(2)
		}
		start, _ := strconv.ParseInt(os.Getenv("RT_LEDGER_BYTE"), 10, 64)
		lock := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: io.SeekStart, Start: start, Len: 1}
		if syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, &lock) != nil {
			os.Exit(2)
		}
		fmt.Println("locked")
		io.Copy(io.Discard, os.Stdin) // hold until the parent closes stdin
	case "read-settings":
		// A reader in another process: each line on stdin reads the settings.
		ledger, err := OpenLedger(root)
		if err != nil {
			os.Exit(2)
		}
		fmt.Println("ready")
		input := bufio.NewScanner(os.Stdin)
		for input.Scan() {
			_, value, _, err := ledger.Settings()
			if err != nil {
				fmt.Println("error:", err)
				continue
			}
			fmt.Println(value)
		}
	}
	os.Exit(0)
}

func helperProcess(t *testing.T, mode string, env ...string) *exec.Cmd {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestLedgerHelperProcess$", "-test.count=1")
	command.Env = append(append(os.Environ(), "RT_LEDGER_HELPER="+mode), env...)
	return command
}

// Writers in other processes and in this one serialise on the flock: no
// read-modify-write transaction is lost.
func TestLedgerConcurrentWriters(t *testing.T) {
	root := newLedgerRoot(t)
	ledger := openLedger(t, root)
	if err := ledger.InitSettings("0"); err != nil {
		t.Fatal(err)
	}
	const perWriter = 60
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			command := helperProcess(t, "increment", "RT_LEDGER_ROOT="+root, "RT_LEDGER_COUNT="+strconv.Itoa(perWriter))
			out, err := command.Output()
			if err != nil || strings.TrimSpace(string(out)) != "done" {
				errs <- fmt.Errorf("helper: %v %q", err, out)
			}
		}()
		wg.Add(1)
		go func() {
			defer wg.Done()
			own, err := OpenLedger(root)
			if err != nil {
				errs <- err
				return
			}
			defer own.Close()
			for n := 0; n < perWriter; n++ {
				if err := increment(own); err != nil {
					errs <- err
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	_, value, _, err := ledger.Settings()
	if err != nil || value != strconv.Itoa(4*perWriter) {
		t.Fatalf("counter %q (%v), want %d: a transaction was lost", value, err, 4*perWriter)
	}
	ledger.Close()
	reopened := openLedger(t, root)
	defer reopened.Close()
	if _, value, _, _ := reopened.Settings(); value != strconv.Itoa(4*perWriter) {
		t.Fatalf("replayed counter %q", value)
	}
}

// A writer holding the lock blocks another for at most the busy timeout.
func TestLedgerLockTimeout(t *testing.T) {
	root := newLedgerRoot(t)
	first, second := openLedger(t, root), openLedger(t, root)
	defer first.Close()
	defer second.Close()
	if err := first.Begin(); err != nil {
		t.Fatal(err)
	}
	began := time.Now()
	if err := second.Begin(); !errors.Is(err, errLedgerLocked) {
		t.Fatalf("second writer: %v", err)
	}
	// sqlite3.connect(timeout=5): the busy timeout is five seconds.
	if elapsed := time.Since(began); elapsed < 4*time.Second || elapsed > 7*time.Second {
		t.Fatalf("busy timeout %v", elapsed)
	}
	// A lock-free reader is not blocked.
	if _, err := second.Operations(); err != nil {
		t.Fatal(err)
	}
	first.Rollback()
	if err := second.Begin(); err != nil {
		t.Fatal(err)
	}
	second.Rollback()
}

// Readers without the lock see whole committed transactions only.
func TestLedgerReaderDuringWrites(t *testing.T) {
	root := newLedgerRoot(t)
	writer, reader := openLedger(t, root), openLedger(t, root)
	defer writer.Close()
	defer reader.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		insertRows(t, writer, 0, 80, strings.Repeat("y", 5000))
	}()
	last := 0
	for running := true; running; {
		select {
		case <-done:
			running = false
		default:
		}
		rows, err := reader.Operations()
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) < last {
			t.Fatalf("reader went back from %d to %d rows", last, len(rows))
		}
		for i, row := range rows {
			if row.ID != fmt.Sprintf("%032x", i) || row.Result == nil || len(*row.Result) != 5000 {
				t.Fatalf("partial row %d", i)
			}
		}
		last = len(rows)
	}
	if rowCount(t, reader) != 80 {
		t.Fatal("reader missed rows")
	}
}

// Transactions roll back completely and leave nothing in the log.
func TestLedgerRollbackAndConstraints(t *testing.T) {
	root := newLedgerRoot(t)
	ledger := openLedger(t, root)
	defer ledger.Close()
	insertRows(t, ledger, 1, 1, "{}")
	size := fileSize(t, filepath.Join(root, ledgerLogName))
	if err := ledger.Begin(); err != nil {
		t.Fatal(err)
	}
	ledger.InsertOperation(ledgerRow(2, "{}"))
	ledger.InsertConfigurationChange(opID, "v")
	ledger.Rollback()
	if rowCount(t, ledger) != 1 || fileSize(t, filepath.Join(root, ledgerLogName)) != size {
		t.Fatal("rollback left state behind")
	}
	if _, ok, _ := ledger.ConfigurationChange(opID); ok {
		t.Fatal("rolled back change visible")
	}
	ledger.Begin()
	if err := ledger.InsertOperation(ledgerRow(1, "{}")); err == nil {
		t.Fatal("duplicate id accepted")
	}
	duplicate := ledgerRow(9, "{}")
	duplicate.Fingerprint = fmt.Sprintf("%064x", 1)
	if err := ledger.InsertOperation(duplicate); err == nil {
		t.Fatal("duplicate fingerprint accepted")
	}
	if err := ledger.InsertConfigurationChange(opID, "a"); err != nil {
		t.Fatal(err)
	}
	if err := ledger.InsertConfigurationChange(opID, "b"); err == nil {
		t.Fatal("duplicate change accepted")
	}
	if err := ledger.InsertOperation(ledgerRow(3, "\xed\xa0\x80")); err == nil {
		t.Fatal("non-UTF-8 value accepted")
	}
	ledger.Commit()
	if err := ledger.UpdateSettings("x", "y"); !errors.Is(err, errLedgerNoWriter) {
		t.Fatal("write outside a transaction accepted")
	}
	// finish and abandon follow the journal's WHERE clauses.
	ledger.Begin()
	ledger.FinishOperation(fmt.Sprintf("%032x", 1), "complete", 5, "r1")
	ledger.FinishOperation(fmt.Sprintf("%032x", 1), "failed", 6, "r2")
	ledger.AbandonOperation(fmt.Sprintf("%032x", 1))
	ledger.Commit()
	ledger.Close()
	reopened := openLedger(t, root)
	defer reopened.Close()
	rows, _ := reopened.Operations()
	if len(rows) != 1 || rows[0].State != "complete" || rows[0].Charged != 5 || *rows[0].Result != "r1" {
		t.Fatalf("replayed row %+v", rows)
	}
	if value, ok, _ := reopened.ConfigurationChange(opID); !ok || value != "a" {
		t.Fatal("change lost")
	}
}

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Size()
}

// An incomplete last frame is a torn write: readers ignore it, the next
// writer truncates it, and damage anywhere else is refused.
func TestLedgerTornTail(t *testing.T) {
	base := newLedgerRoot(t)
	ledger := openLedger(t, base)
	insertRows(t, ledger, 0, 3, "{}")
	ledger.Close()
	logData, err := os.ReadFile(filepath.Join(base, ledgerLogName))
	if err != nil {
		t.Fatal(err)
	}
	frame, _ := encodeLedgerFrame(ledgerFrame{V: 1, Kind: "commit", Ops: []ledgerOp{{Op: "insert", Row: func() *Operation { r := ledgerRow(50, "{}"); return &r }()}}})
	badCRC := append([]byte(nil), frame...)
	badCRC[len(badCRC)-2] ^= 0xff
	tails := map[string][]byte{
		"partial header":   frame[:7],
		"partial payload":  frame[:len(frame)-9],
		"checksum at end":  badCRC,
		"zero-filled tail": make([]byte, 300),
		"length past end":  append(append([]byte(nil), frame[:4]...), 0x7f, 0, 0, 0, 1, 2, 3, 4, 5),
	}
	for name, tail := range tails {
		t.Run(name, func(t *testing.T) {
			root := newLedgerRoot(t)
			copyFixture(t, "", root)
			path := filepath.Join(root, ledgerLogName)
			os.WriteFile(filepath.Join(root, ledgerLockName), nil, 0o600)
			os.WriteFile(path, append(append([]byte(nil), logData...), tail...), 0o600)
			reader := openLedger(t, root)
			defer reader.Close()
			if rowCount(t, reader) != 3 {
				t.Fatal("torn frame visible")
			}
			if fileSize(t, path) != int64(len(logData)+len(tail)) {
				t.Fatal("a reader modified the log")
			}
			insertRows(t, reader, 10, 1, "{}")
			if rowCount(t, reader) != 4 {
				t.Fatal("commit after recovery lost")
			}
			reopened := openLedger(t, root)
			defer reopened.Close()
			if rowCount(t, reopened) != 4 {
				t.Fatal("recovered log does not replay")
			}
		})
	}
	damaged := map[string]func([]byte) []byte{
		"checksum mid-log": func(data []byte) []byte {
			out := append([]byte(nil), data...)
			out[len(out)-len(frame)-20] ^= 0x01 // inside an earlier frame, a later frame follows
			return append(out, frame...)
		},
		"garbage tail": func(data []byte) []byte {
			return append(append([]byte(nil), data...), []byte("not a frame at all!")...)
		},
		"empty log": func([]byte) []byte { return nil },
	}
	for name, damage := range damaged {
		t.Run(name, func(t *testing.T) {
			root := newLedgerRoot(t)
			copyFixture(t, "", root)
			os.WriteFile(filepath.Join(root, ledgerLockName), nil, 0o600)
			os.WriteFile(filepath.Join(root, ledgerLogName), damage(logData), 0o600)
			if _, err := OpenLedger(root); !errors.Is(err, errLedgerCorrupt) {
				t.Fatalf("damaged log opened: %v", err)
			}
		})
	}
}

// A writer killed at an arbitrary point loses nothing it reported committed,
// and the log it leaves recovers.
func TestLedgerCrashRecovery(t *testing.T) {
	root := newLedgerRoot(t)
	openLedger(t, root).Close()
	random := rand.New(rand.NewSource(11))
	committed := map[string]bool{}
	for round := 0; round < 4; round++ {
		command := helperProcess(t, "commit-forever", "RT_LEDGER_ROOT="+root, "RT_LEDGER_FIRST="+strconv.Itoa(round*100000))
		stdout, _ := command.StdoutPipe()
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		lines := bufio.NewScanner(stdout)
		target := 5 + random.Intn(30)
		for i := 0; i < target && lines.Scan(); i++ {
			n, _ := strconv.Atoi(lines.Text())
			committed[fmt.Sprintf("%032x", n)] = true
		}
		command.Process.Kill() // SIGKILL mid-stream, possibly mid-write
		command.Wait()
		ledger := openLedger(t, root)
		rows, err := ledger.Operations()
		if err != nil {
			t.Fatal(err)
		}
		present := map[string]bool{}
		for _, row := range rows {
			present[row.ID] = true
		}
		for id := range committed {
			if !present[id] {
				t.Fatalf("round %d: committed row %s lost", round, id)
			}
		}
		insertRows(t, ledger, 900000+round, 1, "{}") // the next writer recovers the tail
		ledger.Close()
	}
}

// The log never passes the cap: it compacts into one snapshot (keeping the
// import record), and a journal larger than the cap refuses the write.
func TestLedgerCap(t *testing.T) {
	if ledgerCap != 16384*4096 {
		t.Fatalf("cap %d, want open_journal's 16384 pages of 4096 bytes", ledgerCap)
	}
	saved := ledgerCap
	ledgerCap = 48 << 10
	defer func() { ledgerCap = saved }()
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "pending"), root)
	ledger := openLedger(t, root)
	defer ledger.Close()
	record := ledger.Import()
	path := filepath.Join(root, ledgerLogName)
	info, _ := os.Stat(path)
	compacted := false
	n := 0
	for ; n < 200; n++ {
		if err := ledger.Begin(); err != nil {
			t.Fatal(err)
		}
		ledger.InsertOperation(ledgerRow(1000+n, strings.Repeat("c", 900)))
		before := rowCount(t, ledger)
		err := ledger.Commit()
		if size := fileSize(t, path); size > ledgerCap {
			t.Fatalf("log %d bytes passes the cap", size)
		}
		if now, _ := os.Stat(path); !os.SameFile(info, now) {
			compacted = true
		}
		if err != nil {
			if !errors.Is(err, errLedgerFull) {
				t.Fatal(err)
			}
			if rowCount(t, ledger) != before-1 {
				t.Fatal("a refused commit changed the state")
			}
			break
		}
	}
	if !compacted || n == 200 {
		t.Fatalf("compacted %v, writes %d: the cap was not reached", compacted, n)
	}
	rows := rowCount(t, ledger)
	ledger.Close()
	reopened := openLedger(t, root)
	defer reopened.Close()
	if rowCount(t, reopened) != rows || reopened.Import() != record {
		t.Fatal("compacted log lost rows or the import record")
	}
}

// The first open imports the legacy journal exactly once, records it, and
// never writes the sqlite files.
func TestLedgerImportOnce(t *testing.T) {
	for _, name := range []string{"real", "hot"} {
		t.Run(name, func(t *testing.T) {
			root := newLedgerRoot(t)
			copyFixture(t, fixtureDir(t, name), root)
			legacy := filepath.Join(root, legacyJournalName)
			before := fileSHA(t, legacy)
			journalBefore := ""
			if name == "hot" {
				journalBefore = fileSHA(t, legacy+"-journal")
			}
			os.WriteFile(filepath.Join(root, ledgerTempName), []byte("left by a crashed import"), 0o600)
			var wg sync.WaitGroup
			counts := make([]int, 4)
			for i := range counts {
				wg.Add(1)
				go func() {
					defer wg.Done()
					ledger, err := OpenLedger(root)
					if err != nil {
						t.Error(err)
						return
					}
					defer ledger.Close()
					counts[i] = rowCount(t, ledger)
				}()
			}
			wg.Wait()
			ledger := openLedger(t, root)
			record := ledger.Import()
			rows := rowCount(t, ledger)
			ledger.Close()
			if record.Source != legacyJournalName || record.SHA256 != before || record.Operations != rows ||
				counts[0] != rows || counts[1] != rows || counts[2] != rows || counts[3] != rows {
				t.Fatalf("import record %+v rows %d counts %v", record, rows, counts)
			}
			if name == "hot" && (record.HotJournalPages == 0 || rows != 13) {
				t.Fatalf("hot journal not rolled back: %+v rows %d", record, rows)
			}
			if fileSHA(t, legacy) != before || name == "hot" && fileSHA(t, legacy+"-journal") != journalBefore {
				t.Fatal("the legacy journal was modified")
			}
			if _, err := os.Lstat(filepath.Join(root, ledgerTempName)); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("stale import file left behind")
			}
			frames := countFrames(t, filepath.Join(root, ledgerLogName))
			if frames != 1 {
				t.Fatalf("%d frames after concurrent first opens, want one snapshot", frames)
			}
			// Later sqlite writes (a rolled-back relayd) are never re-imported:
			// the open refuses until the operator sets the sqlite file aside.
			os.WriteFile(legacy, nil, 0o600)
			var diverged *errLedgerDiverged
			if _, err := OpenLedger(root); !errors.As(err, &diverged) {
				t.Fatalf("changed legacy journal opened: %v", err)
			}
			os.Rename(legacy, legacy+".diverged")
			again := openLedger(t, root)
			defer again.Close()
			if rowCount(t, again) != rows || again.Import() != record {
				t.Fatal("import ran twice")
			}
		})
	}
	t.Run("no legacy journal", func(t *testing.T) {
		root := newLedgerRoot(t)
		ledger := openLedger(t, root)
		defer ledger.Close()
		if ledger.Import() != (LedgerImport{}) || rowCount(t, ledger) != 0 {
			t.Fatal("unexpected import")
		}
		if _, err := os.Lstat(filepath.Join(root, legacyJournalName)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("the ledger created a sqlite file")
		}
	})
}

func countFrames(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	frames := 0
	for len(data) >= ledgerFrameHeader {
		size := int(uint32(data[4])<<24 | uint32(data[5])<<16 | uint32(data[6])<<8 | uint32(data[7]))
		data = data[ledgerFrameHeader+size:]
		frames++
	}
	return frames
}

// Usage imported from the legacy journal counts toward today's limits.
func TestLedgerDailyLimitAcrossImport(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "legacy-migrated"), root)
	ledger := openLedger(t, root)
	now, _ := time.Parse("2006-01-02T15:04:05", journalNow)
	execute := func(_ context.Context, raw any) any {
		request := raw.(obj)
		evidence := request["evidence"].(string)
		return parseJSON(cannedDraft(request["operation_id"].(string), evidence,
			obj{"usage": obj{"input_tokens": int64(0), "output_tokens": int64(2_000_000)}}))
	}
	journal, err := OpenJournal(ledger, execute, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	status := journal.Status(nil)
	if status["requests_today"] != int64(11) || status["charged_today_microusd"] != int64(3_150_603) {
		t.Fatalf("imported usage %v %v", status["requests_today"], status["charged_today_microusd"])
	}
	// 3150603 + 1000000 fits the 5000000 daily limit; a second reservation does not.
	if result := journal.Submit(context.Background(), submitRequest(opID, "e1")); result["status"] != "complete" {
		t.Fatalf("first draft %v", result)
	}
	if outcome := goOutcome(func() any { return journal.Submit(context.Background(), submitRequest(opID2, "e2")) }); outcome["draft_error"] != "spending_limit" {
		t.Fatalf("second draft %v", outcome)
	}
}

func TestLedgerPermissions(t *testing.T) {
	code := func(err error) string {
		var coded interface{ Code() string }
		if errors.As(err, &coded) {
			return coded.Code()
		}
		return fmt.Sprint(err)
	}
	if _, err := OpenLedger("relative/rotation-text"); code(err) != "invalid_state_directory" {
		t.Fatal(err)
	}
	shared := newLedgerRoot(t)
	os.Mkdir(shared, 0o750)
	os.Chmod(shared, 0o750)
	if _, err := OpenLedger(shared); code(err) != "journal_permissions" {
		t.Fatalf("shared directory: %v", err)
	}
	for _, name := range []string{ledgerLogName, ledgerLockName, legacyJournalName} {
		t.Run(name, func(t *testing.T) {
			root := newLedgerRoot(t)
			copyFixture(t, "", root)
			target := filepath.Join(t.TempDir(), "elsewhere")
			os.WriteFile(target, nil, 0o600)
			os.Symlink(target, filepath.Join(root, name))
			if _, err := OpenLedger(root); code(err) != "journal_permissions" {
				t.Fatalf("symlinked %s: %v", name, err)
			}
		})
	}
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "fresh"), root)
	os.Chmod(filepath.Join(root, legacyJournalName), 0o644)
	if _, err := OpenLedger(root); code(err) != "journal_permissions" {
		t.Fatalf("readable legacy journal: %v", err)
	}
	linked := newLedgerRoot(t)
	openLedger(t, linked).Close()
	os.Link(filepath.Join(linked, ledgerLogName), filepath.Join(t.TempDir(), "second-link"))
	if _, err := OpenLedger(linked); code(err) != "journal_permissions" {
		t.Fatalf("hard-linked log: %v", err)
	}
}

// The import takes sqlite's SHARED lock: a committing writer (PENDING held)
// blocks it, and a journal owned by a live writer (RESERVED held) is not hot.
func TestLegacyJournalLocks(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "hot"), root)
	path := filepath.Join(root, legacyJournalName)
	hold := func(at int64) func() {
		command := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+path, "RT_LEDGER_BYTE="+strconv.FormatInt(at, 10))
		stdin, _ := command.StdinPipe()
		stdout, _ := command.StdoutPipe()
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		if line != "locked\n" {
			t.Fatalf("helper lock: %q", line)
		}
		return func() { stdin.Close(); command.Wait() }
	}
	release := hold(sqlitePendingByte)
	if _, err := readLegacyJournal(path, 300*time.Millisecond); !errors.Is(err, errSQLiteLocked) {
		t.Fatalf("read during a commit: %v", err)
	}
	release()
	release = hold(sqliteReservedByte)
	heldRead, err := readLegacyJournal(path, time.Second)
	release()
	hot, hotErr := readLegacyJournal(path, time.Second)
	if hotErr != nil || hot.hotJournalPages == 0 || len(hot.state.Rows) != 13 {
		t.Fatalf("hot journal: %v", hotErr)
	}
	// With RESERVED held the journal belongs to a live writer and is not
	// played back: the database is read as it is (here the spilled pages).
	if err == nil && heldRead.hotJournalPages != 0 {
		t.Fatal("a live writer's journal was played back")
	}
}

// Damaged legacy files are refused with an error; the reader never panics,
// loops, or reads outside its buffers.
func TestLegacyJournalDamage(t *testing.T) {
	random := rand.New(rand.NewSource(5))
	for _, name := range []string{"real", "overflow-1k", "hot"} {
		source := fixtureDir(t, name)
		original, _ := os.ReadFile(filepath.Join(source, legacyJournalName))
		for i := 0; i < 150; i++ {
			data := append([]byte(nil), original...)
			switch i % 3 {
			case 0:
				for n := 1 + random.Intn(8); n > 0; n-- {
					data[random.Intn(len(data))] = byte(random.Intn(256))
				}
			case 1:
				data = data[:random.Intn(len(data))]
			default:
				page := 4096
				if name == "overflow-1k" {
					page = 1024
				}
				at := random.Intn(len(data)/page) * page
				copy(data[at:at+page], bytes.Repeat([]byte{byte(random.Intn(256))}, page))
			}
			root := filepath.Join(t.TempDir(), "rotation-text")
			copyFixture(t, source, root)
			os.WriteFile(filepath.Join(root, legacyJournalName), data, 0o600)
			func() {
				defer func() {
					if value := recover(); value != nil {
						t.Fatalf("%s mutation %d: reader panicked: %v", name, i, value)
					}
				}()
				readLegacyJournal(filepath.Join(root, legacyJournalName), time.Second)
			}()
		}
	}
	if _, err := sqliteColumns("CREATE TABLE x (a TEXT, \"b,c\" INTEGER CHECK(a IN ('x,y')), UNIQUE(a), PRIMARY KEY(a))"); err != nil {
		t.Fatal(err)
	}
	columns, _ := sqliteColumns("CREATE TABLE x (a TEXT, \"b,c\" INTEGER CHECK(a IN ('x,y')), UNIQUE(a), PRIMARY KEY(a))")
	if strings.Join(columns, "|") != "a|b,c" {
		t.Fatalf("columns %q", columns)
	}
	for _, c := range []struct {
		raw   []byte
		value int64
		n     int
	}{{[]byte{0x05}, 5, 1}, {[]byte{0x81, 0x00}, 128, 2}, {[]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, -1, 9},
		{[]byte{0x81}, 0, 0}} {
		if value, n := sqliteVarint(c.raw); value != c.value || n != c.n {
			t.Fatalf("varint %x: %d %d", c.raw, value, n)
		}
	}
	if sqlitePageSize(1) != 65536 || sqlitePageSize(4096) != 4096 || sqlitePageSize(1000) != 0 || sqlitePageSize(256) != 0 {
		t.Fatal("page size decoding")
	}
}

// synchronous=FULL: each durable step is synced before it is acknowledged or
// renamed into place, and a failed sync is a failed commit that leaves nothing
// behind.
func TestLedgerDurability(t *testing.T) {
	type synced struct {
		name string
		size int64
	}
	var syncs []synced
	failLog := false
	saved := ledgerSync
	defer func() { ledgerSync = saved }()
	ledgerSync = func(file *os.File) error {
		info, err := file.Stat()
		if err != nil {
			return err
		}
		name := filepath.Base(file.Name())
		if info.IsDir() {
			name = "<dir>"
		}
		syncs = append(syncs, synced{name, info.Size()})
		if failLog && name == ledgerLogName {
			failLog = false // the commit's sync; the rollback's succeeds (else poisoned)
			return errors.New("injected sync failure")
		}
		return file.Sync()
	}
	index := func(name string, after int) int {
		for i := after + 1; i < len(syncs); i++ {
			if syncs[i].name == name {
				return i
			}
		}
		return -1
	}
	root := newLedgerRoot(t)
	ledger := openLedger(t, root)
	defer ledger.Close()
	path := filepath.Join(root, ledgerLogName)
	lock := index(ledgerLockName, -1)
	snapshot := index(ledgerTempName, -1)
	if lock < 0 || index("<dir>", lock) < 0 || snapshot < 0 || index("<dir>", snapshot) < 0 ||
		syncs[snapshot].size != fileSize(t, path) {
		t.Fatalf("creation not synced before rename: %v", syncs)
	}
	syncs = nil
	insertRows(t, ledger, 0, 1, "{}")
	if last := len(syncs) - 1; last < 0 || syncs[last].name != ledgerLogName || syncs[last].size != fileSize(t, path) {
		t.Fatalf("commit returned before its frame was synced: %v", syncs)
	}
	size := fileSize(t, path)
	failLog = true
	if err := ledger.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := ledger.InsertOperation(ledgerRow(1, "{}")); err != nil {
		t.Fatal(err)
	}
	if err := ledger.Commit(); err == nil {
		t.Fatal("a commit whose sync failed succeeded")
	}
	failLog = false
	reopened := openLedger(t, root)
	defer reopened.Close()
	if fileSize(t, path) != size || rowCount(t, ledger) != 1 || rowCount(t, reopened) != 1 {
		t.Fatal("an unsynced commit left a trace")
	}
	// A writer's torn-tail truncation is synced before its own frame.
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	file.Write([]byte("RTL1\x00\x00"))
	file.Close()
	syncs = nil
	insertRows(t, ledger, 2, 1, "{}")
	if len(syncs) < 2 || syncs[0] != (synced{ledgerLogName, size}) {
		t.Fatalf("torn tail truncation not synced: %v", syncs)
	}
}

// The reader refuses what it cannot read exactly as sqlite would: a live
// write-ahead log, and text that is not UTF-8 (Python's sqlite3 cannot decode
// it either).
func TestLegacyJournalRefusals(t *testing.T) {
	source := fixtureDir(t, "real")
	read := func(setup func(root string)) error {
		root := filepath.Join(t.TempDir(), "rotation-text")
		copyFixture(t, source, root)
		setup(root)
		_, err := readLegacyJournal(filepath.Join(root, legacyJournalName), time.Second)
		return err
	}
	if err := read(func(root string) {
		os.WriteFile(filepath.Join(root, legacyJournalName+"-wal"), nil, 0o600)
	}); err != nil {
		t.Fatal("an empty -wal refused", err)
	}
	if err := read(func(root string) {
		os.WriteFile(filepath.Join(root, legacyJournalName+"-wal"), []byte{0x37, 0x7f, 0x06, 0x82}, 0o600)
	}); err == nil {
		t.Fatal("a non-empty -wal was ignored")
	}
	imported, err := readLegacyJournal(filepath.Join(source, legacyJournalName), time.Second)
	if err != nil || len(imported.state.Rows) == 0 {
		t.Fatal(err)
	}
	fingerprint := []byte(imported.state.Rows[0].Fingerprint)
	if err := read(func(root string) {
		path := filepath.Join(root, legacyJournalName)
		data, _ := os.ReadFile(path)
		if !bytes.Contains(data, fingerprint) {
			t.Fatal("fingerprint not stored inline")
		}
		bad := append([]byte(nil), fingerprint...)
		bad[0] = 0xff
		os.WriteFile(path, bytes.ReplaceAll(data, fingerprint, bad), 0o600)
	}); err == nil {
		t.Fatal("non-UTF-8 text imported")
	}
}

// While the reader holds SHARED, no sqlite writer can take EXCLUSIVE: every
// byte of sqlite's shared range (PENDING+2, 510 bytes, as os_unix.c locks it)
// refuses a write lock, and the database file is never modified.
func TestLegacyJournalSharedLockRange(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "real"), root)
	path := filepath.Join(root, legacyJournalName)
	before := fileSHA(t, path)
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := sqliteSharedLock(context.Background(), file, time.Second); err != nil {
		t.Fatal(err)
	}
	writable := func(at int64) bool {
		command := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+path, "RT_LEDGER_BYTE="+strconv.FormatInt(at, 10))
		stdin, _ := command.StdinPipe()
		stdout, _ := command.StdoutPipe()
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		stdin.Close()
		command.Wait()
		return line == "locked\n"
	}
	for _, at := range []int64{0x40000002, 0x40000002 + 255, 0x40000002 + 509} {
		if writable(at) {
			t.Fatalf("a writer locked shared byte %#x while the reader held SHARED", at)
		}
	}
	if !writable(0x40000002+510) || !writable(0x40000000) {
		t.Fatal("the reader locked outside sqlite's SHARED lock")
	}
	if fileSHA(t, path) != before {
		t.Fatal("locking modified the database")
	}
}

// A journal whose header is zeroed (sqlite's hasHotJournal reads its first
// byte) or whose magic is wrong (pager_playback stops at the first bad
// header) plays nothing back: the database is read as it is.
func TestLegacyJournalInvalidHeaderIsNotPlayedBack(t *testing.T) {
	source := fixtureDir(t, "hot")
	for name, first := range map[string]byte{"zeroed": 0, "bad magic": 0x01} {
		root := newLedgerRoot(t)
		copyFixture(t, source, root)
		path := filepath.Join(root, legacyJournalName+"-journal")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		data[0] = first
		os.WriteFile(path, data, 0o600)
		imported, err := readLegacyJournal(filepath.Join(root, legacyJournalName), time.Second)
		if err != nil || imported.hotJournalPages != 0 {
			t.Fatalf("%s journal played back: %v", name, err)
		}
	}
}

// Without python3: an emulated legacy writer, taking sqlite's locks in another
// process, reaches RESERVED (BEGIN IMMEDIATE) but not EXCLUSIVE (COMMIT) while
// any ledger of this process is open, and commits after the last close.
func TestLedgerHoldBlocksAnEmulatedLegacyCommit(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "real"), root)
	legacy := filepath.Join(root, legacyJournalName)
	commit := func() string {
		output, err := helperProcess(t, "legacy-commit", "RT_LEDGER_FILE="+legacy).Output()
		if err != nil {
			t.Fatalf("legacy writer: %v", err)
		}
		return strings.TrimSpace(string(output))
	}
	if got := commit(); got != "exclusive" {
		t.Fatalf("unheld legacy commit: %q", got)
	}
	first, second := openLedger(t, root), openLedger(t, root)
	if got := commit(); got != "busy" {
		t.Fatalf("legacy commit while held: %q", got)
	}
	first.Close()
	if got := commit(); got != "busy" {
		t.Fatalf("legacy commit after one of two closes: %q", got)
	}
	second.Close()
	if got := commit(); got != "exclusive" {
		t.Fatalf("legacy commit after the last close: %q", got)
	}
}
