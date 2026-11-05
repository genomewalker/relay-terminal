package rotationtext

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// pauseCommitSync stops writer's next fsync of its log, after the frame is
// appended: paused is closed there, and the fsync returns result() once
// resumed. The hook is removed by the returned restore.
func pauseCommitSync(writer *Ledger, result func(*os.File) error) (paused, resume chan struct{}, restore func()) {
	saved := ledgerSync
	paused, resume = make(chan struct{}), make(chan struct{})
	armed := true
	ledgerSync = func(file *os.File) error {
		if armed && file == writer.log {
			armed = false
			close(paused)
			<-resume
			return result(file)
		}
		return saved(file)
	}
	return paused, resume, func() { ledgerSync = saved }
}

// startSettingsCommit begins a transaction that changes the settings to value
// and commits it in the background.
func startSettingsCommit(t *testing.T, writer *Ledger, value string) chan error {
	t.Helper()
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := writer.UpdateSettings("", value); err != nil {
		t.Fatal(err)
	}
	committed := make(chan error, 1)
	go func() { committed <- writer.Commit() }()
	return committed
}

// A reader outside a transaction sees only committed frames: while a commit's
// frame is appended but not yet synced it waits, and a commit whose fsync
// fails was never visible.
func TestLedgerReadersSeeOnlyCommittedFrames(t *testing.T) {
	for _, test := range []struct {
		name   string
		fsync  func(*os.File) error
		commit bool
	}{
		{"failed fsync", func(*os.File) error { return errors.New("injected fsync failure") }, false},
		{"durable fsync", func(file *os.File) error { return file.Sync() }, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := newLedgerRoot(t)
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

			paused, resume, restore := pauseCommitSync(writer, test.fsync)
			defer restore()
			committed := startSettingsCommit(t, writer, "new-uncommitted")
			select {
			case <-paused:
			case <-time.After(5 * time.Second):
				t.Fatal("commit never reached its fsync")
			}
			// The frame is in the file; both readers must wait for the commit.
			read := make(chan string, 1)
			go func() {
				_, value, _, err := reader.Settings()
				if err != nil {
					value = "error: " + err.Error()
				}
				read <- value
			}()
			remote := make(chan string, 1)
			io.WriteString(input, "read\n")
			go func() { line, _ := lines.ReadString('\n'); remote <- line }()
			select {
			case value := <-read:
				t.Fatalf("reader returned %q before the commit ended", value)
			case line := <-remote:
				t.Fatalf("reader in another process returned %q before the commit ended", line)
			case <-time.After(200 * time.Millisecond):
			}
			close(resume)
			if err := <-committed; (err == nil) != test.commit {
				t.Fatalf("commit = %v", err)
			}
			want := "old-committed"
			if test.commit {
				want = "new-uncommitted"
			}
			for name, got := range map[string]chan string{"this process": read, "another process": remote} {
				select {
				case value := <-got:
					if value != want && value != want+"\n" {
						t.Errorf("reader in %s saw %q, want %q", name, value, want)
					}
				case <-time.After(5 * time.Second):
					t.Fatalf("reader in %s never returned", name)
				}
			}
			restore()
			reopened := openLedger(t, root)
			defer reopened.Close()
			if _, value, _, err := reopened.Settings(); err != nil || value != want {
				t.Fatalf("reopened settings = %q, %v", value, err)
			}
		})
	}
}

// A reader's wait for a writer ends with the reader's context.
func TestLedgerReadWaitEndsWithTheContext(t *testing.T) {
	root := newLedgerRoot(t)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("value"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	reader, err := OpenLedgerContext(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	// An open transaction does not block the reader; its commit does.
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if _, value, _, err := reader.Settings(); err != nil || value != "value" {
		t.Fatalf("settings during a transaction = %q, %v", value, err)
	}
	if err := writer.Rollback(); err != nil {
		t.Fatal(err)
	}
	paused, resume, restore := pauseCommitSync(writer, func(file *os.File) error { return file.Sync() })
	defer restore()
	committed := startSettingsCommit(t, writer, "next")
	<-paused
	time.AfterFunc(100*time.Millisecond, cancel)
	began := time.Now()
	_, _, _, err = reader.Settings()
	elapsed := time.Since(began)
	close(resume)
	if err := <-committed; err != nil {
		t.Fatal(err)
	}
	if !errors.Is(err, context.Canceled) || elapsed > 2*time.Second {
		t.Fatalf("settings = %v after %v", err, elapsed)
	}
}

// pendingLegacyHold reports whether an opener in this process is waiting for
// the SHARED lock on path (or, wrongly, waits holding the registry).
func pendingLegacyHold(t *testing.T, path string) bool {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat := info.Sys().(*syscall.Stat_t)
	if !legacyHolds.TryLock() {
		return true
	}
	defer legacyHolds.Unlock()
	hold := legacyHolds.files[legacyKey{uint64(stat.Dev), uint64(stat.Ino)}]
	return hold != nil && hold.file == nil
}

// An opener waiting for a legacy journal's SHARED lock holds up no ledger in
// another root, and an opener past its own deadline fails with it, never
// returning a ledger.
func TestLegacyHoldWaitsAreIndependentAndHonourTheContext(t *testing.T) {
	blocked, other := newLedgerRoot(t), newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "fresh"), blocked)
	copyFixture(t, fixtureDir(t, "fresh"), other)
	path := filepath.Join(blocked, legacyJournalName)
	helper := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+path, "RT_LEDGER_BYTE="+strconv.FormatInt(sqlitePendingByte, 10))
	input, _ := helper.StdinPipe()
	output, _ := helper.StdoutPipe()
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	released := false
	release := func() {
		if !released {
			released = true
			input.Close()
			helper.Wait()
		}
	}
	defer release()
	if line, _ := bufio.NewReader(output).ReadString('\n'); line != "locked\n" {
		t.Fatalf("helper = %q", line)
	}

	firstCtx, firstCancel := context.WithCancel(context.Background())
	defer firstCancel()
	first := make(chan error, 1)
	go func() {
		ledger, err := OpenLedgerContext(firstCtx, blocked)
		if ledger != nil {
			ledger.Close()
		}
		first <- err
	}()
	for deadline := time.Now().Add(5 * time.Second); !pendingLegacyHold(t, path); time.Sleep(time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the first opener never waited for the legacy lock")
		}
	}

	// Another root opens at once, and a short deadline does not wait.
	for _, timeout := range []time.Duration{2 * time.Second, 40 * time.Millisecond} {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		began := time.Now()
		ledger, err := OpenLedgerContext(ctx, other)
		elapsed := time.Since(began)
		cancel()
		if ledger != nil {
			ledger.Close()
		}
		if elapsed > time.Second || (err == nil) != (ledger != nil) ||
			err != nil && !(timeout < time.Second && errors.Is(err, context.DeadlineExceeded)) {
			t.Fatalf("open of another root (deadline %v) = %v, ledger %v, after %v", timeout, err, ledger != nil, elapsed)
		}
	}
	expired, cancel := context.WithCancel(context.Background())
	cancel()
	if ledger, err := OpenLedgerContext(expired, other); ledger != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("open with an expired context = %v, ledger %v", err, ledger != nil)
	}

	// A second wait on the same file ends at its own deadline.
	ctx, cancelShort := context.WithTimeout(context.Background(), 40*time.Millisecond)
	began := time.Now()
	hold, err := holdLegacyJournal(ctx, path)
	cancelShort()
	if hold != nil || !errors.Is(err, context.DeadlineExceeded) || time.Since(began) > time.Second {
		t.Fatalf("second wait = %v, hold %v, after %v", err, hold != nil, time.Since(began))
	}

	// When the first opener gives up, a waiter takes the lock itself.
	waiter := make(chan *legacyHold, 1)
	waiterErr := make(chan error, 1)
	go func() {
		hold, err := holdLegacyJournal(context.Background(), path)
		waiter <- hold
		waiterErr <- err
	}()
	time.Sleep(50 * time.Millisecond) // let the waiter find the first opener's pending hold
	firstCancel()
	if err := <-first; !errors.Is(err, context.Canceled) {
		t.Fatalf("first opener = %v", err)
	}
	release()
	select {
	case hold := <-waiter:
		if err := <-waiterErr; err != nil || hold == nil || hold.refs != 1 {
			t.Fatalf("waiter = %v, hold %+v", err, hold)
		}
		hold.release()
	case <-time.After(10 * time.Second):
		t.Fatal("the waiter never took the lock")
	}
	legacyHolds.Lock()
	left := len(legacyHolds.files)
	legacyHolds.Unlock()
	if left != 0 {
		t.Fatalf("%d legacy holds left open", left)
	}
}

// An opener whose context ends during the open gets no ledger, even when no
// wait was left to notice it.
func TestLedgerOpenPastItsDeadlineReturnsNoLedger(t *testing.T) {
	root := newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "fresh"), root)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	saved := ledgerSync
	defer func() { ledgerSync = saved }()
	ledgerSync = func(file *os.File) error {
		if filepath.Base(file.Name()) == ledgerTempName {
			cancel() // the import's snapshot: every lock is already taken
		}
		return saved(file)
	}
	ledger, err := OpenLedgerContext(ctx, root)
	if ledger != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("open = %v, ledger %v", err, ledger != nil)
	}
	legacyHolds.Lock()
	left := len(legacyHolds.files)
	legacyHolds.Unlock()
	if left != 0 {
		t.Fatalf("%d legacy holds left open", left)
	}
}

// A commit waits for readers to leave the gate; when its context ends first
// the transaction is rolled back and nothing reaches the log.
func TestLedgerCommitGateWaitEndsWithTheContext(t *testing.T) {
	root := newLedgerRoot(t)
	setup := openLedger(t, root)
	if err := setup.InitSettings("old"); err != nil {
		t.Fatal(err)
	}
	setup.Close()
	ctx, cancel := context.WithCancel(context.Background())
	writer, err := OpenLedgerContext(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	gate, err := os.Open(filepath.Join(root, ledgerGateName))
	if err != nil {
		t.Fatal(err)
	}
	defer gate.Close()
	if err := syscall.Flock(int(gate.Fd()), syscall.LOCK_SH); err != nil { // a reader mid-read
		t.Fatal(err)
	}
	before := fileSHA(t, filepath.Join(root, ledgerLogName))
	committed := startSettingsCommit(t, writer, "new")
	time.AfterFunc(100*time.Millisecond, cancel)
	select {
	case err := <-committed:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("commit = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("commit kept waiting for the gate")
	}
	if after := fileSHA(t, filepath.Join(root, ledgerLogName)); after != before {
		t.Fatal("a commit that never passed the gate changed the log")
	}
	syscall.Flock(int(gate.Fd()), syscall.LOCK_UN)
	reader := openLedger(t, root)
	defer reader.Close()
	if _, value, _, err := reader.Settings(); err != nil || value != "old" {
		t.Fatalf("settings = %q, %v", value, err)
	}
	if writer.InTransaction() || writer.state.SettingsValue != "old" {
		t.Fatalf("writer kept the abandoned transaction: %q", writer.state.SettingsValue)
	}
}
