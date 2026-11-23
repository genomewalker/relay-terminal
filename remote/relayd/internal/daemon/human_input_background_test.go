package daemon

import (
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// slowCapacityRevoke makes capacity revocation block until release is closed
// and counts the runs.
func slowCapacityRevoke(t *testing.T) (release chan struct{}, runs *atomic.Int32) {
	t.Helper()
	release = make(chan struct{})
	runs = &atomic.Int32{}
	saved := capacityRevokeHumanInputFunc
	capacityRevokeHumanInputFunc = func(root, pane string) error {
		runs.Add(1)
		<-release
		return nil
	}
	t.Cleanup(func() { capacityRevokeHumanInputFunc = saved })
	return release, runs
}

// A keystroke reaches the PTY while capacity revocation is stuck on the
// filesystem, and a burst of keystrokes costs at most two revocations.
func TestHumanInputWritesWithoutWaitingForCapacityRevocation(t *testing.T) {
	release, runs := slowCapacityRevoke(t)
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	root := t.TempDir()
	pane := "d62c62eb-7b02-44ce-9223-080417078764"
	supervisor := &hostRotationSupervisor{path: filepath.Join(root, "rotation-supervision", pane+".json")}
	session := &Session{pty: writer, inputSequences: map[[16]byte]uint64{}, hostRotation: supervisor}

	done := make(chan error, 1)
	go func() {
		var err error
		for i := uint64(1); i <= 300 && err == nil; i++ {
			err = session.acknowledgedInput([16]byte{1}, i, []byte{'k'})
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("KEYSTROKES_WAITED_FOR_CAPACITY_REVOCATION")
	}
	got := make([]byte, 300)
	_ = reader.SetReadDeadline(time.Now().Add(5 * time.Second))
	if n, err := io.ReadFull(reader, got); err != nil || n != 300 {
		t.Fatalf("pty got %d bytes: %v", n, err)
	}
	if session.humanInputRevision != 300 {
		t.Fatalf("human input revision %d, want 300", session.humanInputRevision)
	}
	close(release)
	supervisor.capacityRevoke.wait()
	if n := runs.Load(); n < 1 || n > 2 {
		t.Fatalf("%d revocations for one burst, want 1 or 2", n)
	}
}

// Input that arrives while a revocation runs is followed by one more run, so
// the last keystroke is always covered by a revocation that started after it.
func TestCapacityRevokerRunsAgainForInputDuringARun(t *testing.T) {
	var r capacityRevoker
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	var mu sync.Mutex
	order := []string{}
	run := func() {
		started <- struct{}{}
		<-release
		mu.Lock()
		order = append(order, "run")
		mu.Unlock()
	}
	r.schedule(run)
	<-started
	r.schedule(run) // during the first run
	r.schedule(run) // coalesced with the previous one
	close(release)
	r.wait()
	mu.Lock()
	defer mu.Unlock()
	if len(order) != 2 {
		t.Fatalf("%d runs, want 2 (one, then one for the input during it)", len(order))
	}
}
