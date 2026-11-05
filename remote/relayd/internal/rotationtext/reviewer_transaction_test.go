package rotationtext

import (
	"bufio"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Root's reviewer tests from the rotation-text ledger review of 2026-10-21
// (reviewer/reviewer_transaction_test.go), gofmt-ed. The first is unchanged; the
// second is ported where marked, because its precondition and its deadline
// assertion both assumed the registry mutex is held across the wait.

func TestReviewerReadCannotObserveFailedCommit(t *testing.T) {
	root := newLedgerRoot(t)
	writer := openLedger(t, root)
	defer writer.Close()
	if err := writer.InitSettings("old-committed"); err != nil {
		t.Fatal(err)
	}
	reader := openLedger(t, root)
	defer reader.Close()
	if err := writer.Begin(); err != nil {
		t.Fatal(err)
	}
	if err := writer.UpdateSettings("fixture-change", "new-uncommitted"); err != nil {
		t.Fatal(err)
	}
	saved := ledgerSync
	defer func() { ledgerSync = saved }()
	entered := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	allow := func() { releaseOnce.Do(func() { close(release) }) }
	defer allow()
	var first atomic.Bool
	ledgerSync = func(file *os.File) error {
		if file == writer.log && first.CompareAndSwap(false, true) {
			close(entered)
			<-release
			return errors.New("reviewer injected fsync failure")
		}
		return saved(file)
	}
	committed := make(chan error, 1)
	go func() { committed <- writer.Commit() }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("commit did not reach sync fence")
	}
	type answer struct {
		value string
		err   error
	}
	read := make(chan answer, 1)
	go func() { _, value, _, err := reader.Settings(); read <- answer{value, err} }()
	var got answer
	early := false
	select {
	case got = <-read:
		early = true
	case <-time.After(80 * time.Millisecond):
	}
	allow()
	var commitErr error
	select {
	case commitErr = <-committed:
	case <-time.After(2 * time.Second):
		t.Fatal("commit did not end after released failure")
	}
	if commitErr == nil {
		t.Fatal("injected failed commit succeeded")
	}
	if !early {
		select {
		case got = <-read:
		case <-time.After(time.Second):
			t.Fatal("reader stayed blocked after writer ended")
		}
	}
	if got.err != nil {
		t.Fatal(got.err)
	}
	t.Logf("reader returned before failed commit ended=%v value=%q; commit error=%v", early, got.value, commitErr)
	if got.value != "old-committed" {
		t.Errorf("reader exposed settings from a transaction that failed to commit: %q", got.value)
	}
	_, after, _, err := reader.Settings()
	if err != nil || after != "old-committed" {
		t.Fatalf("post-rollback settings=%q err=%v", after, err)
	}
}
func TestReviewerLegacyRegistryWaitHonorsContext(t *testing.T) {
	firstRoot, secondRoot := newLedgerRoot(t), newLedgerRoot(t)
	copyFixture(t, fixtureDir(t, "fresh"), firstRoot)
	copyFixture(t, fixtureDir(t, "fresh"), secondRoot)
	path := filepath.Join(firstRoot, legacyJournalName)
	helper := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+path, "RT_LEDGER_BYTE="+strconv.FormatInt(sqlitePendingByte, 10))
	input, _ := helper.StdinPipe()
	output, _ := helper.StdoutPipe()
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { input.Close(); helper.Wait() }()
	if line, _ := bufio.NewReader(output).ReadString('\n'); line != "locked\n" {
		t.Fatalf("helper=%q", line)
	}
	firstCtx, firstCancel := context.WithCancel(context.Background())
	defer firstCancel()
	firstDone := make(chan error, 1)
	go func() {
		l, err := OpenLedgerContext(firstCtx, firstRoot)
		if l != nil {
			l.Close()
		}
		firstDone <- err
	}()
	// Ported: the fixed registry is never held during the wait, so wait for
	// the first opener's pending entry instead of for the mutex.
	deadline := time.Now().Add(time.Second)
	for !pendingLegacyHold(t, path) {
		if time.Now().After(deadline) {
			t.Fatal("first open never waited for the legacy lock")
		}
		time.Sleep(time.Millisecond)
	}
	secondCtx, secondCancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer secondCancel()
	type result struct {
		ledger *Ledger
		err    error
		after  time.Duration
	}
	done := make(chan result, 1)
	began := time.Now()
	go func() { l, err := OpenLedgerContext(secondCtx, secondRoot); done <- result{l, err, time.Since(began)} }()
	var got result
	returnedOnTime := false
	select {
	case got = <-done:
		returnedOnTime = true
	case <-time.After(180 * time.Millisecond):
	}
	firstCancel()
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("first canceled opener did not end")
	}
	if !returnedOnTime {
		select {
		case got = <-done:
		case <-time.After(time.Second):
			t.Fatal("second opener did not end after mutex released")
		}
	}
	if got.ledger != nil {
		got.ledger.Close()
	}
	elapsed := time.Since(began)
	t.Logf("40ms-deadline opener returned within 180ms=%v elapsed=%v err=%v ledgerOpened=%v", returnedOnTime, elapsed, got.err, got.ledger != nil)
	if !returnedOnTime {
		t.Errorf("canceled opener waited on the registry mutex and did not refuse at its own deadline")
	}
	// Ported: another root need not wait at all. An opener admitted within
	// its deadline may succeed; past it, it must refuse with no ledger.
	switch {
	case got.err == nil && (got.ledger == nil || got.after > 140*time.Millisecond):
		t.Errorf("opener succeeded after its 40ms deadline (%v)", got.after)
	case got.err != nil && (got.ledger != nil || !errors.Is(got.err, context.DeadlineExceeded)):
		t.Errorf("opener past its deadline = %v, ledger %v", got.err, got.ledger != nil)
	}
}
