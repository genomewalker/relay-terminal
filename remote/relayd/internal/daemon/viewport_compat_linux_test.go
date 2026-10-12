//go:build linux

package daemon

import (
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestLegacyRepaintObserverPreservesRequestingClientLease(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "worker.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	session := &Session{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		connection, err := listener.Accept()
		if err != nil {
			t.Error(err)
			return
		}
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			t.Error(err)
			return
		}
		var hello protocol.HelloPayload
		if err := protocol.DecodeJSON(frame, &hello); err != nil {
			t.Error(err)
			return
		}
		if hello.ClientID != "native-pane" {
			t.Errorf("helper stole identity: %q", hello.ClientID)
		}
		if !session.acquireControl(hello.ClientID) {
			t.Error("initial lease denied")
		}
		// Simulate a legacy worker: even Detach retains a five-second lease.
		defer session.releaseControl(hello.ClientID, false)
		caughtUp, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "caught_up"})
		if err := protocol.NewWriter(connection).Write(caughtUp); err != nil {
			t.Error(err)
			return
		}
		if _, err := protocol.ReadFrame(connection); err != nil {
			t.Error(err)
		}
	}()
	observer, err := openLegacyRepaintObserver(workerManifest{SocketPath: socket}, "native-pane")
	if err != nil {
		t.Fatal(err)
	}
	observer.close()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("helper did not detach")
	}
	if !session.acquireControl("native-pane") {
		t.Fatal("repaint helper locked out the actual terminal during legacy grace period")
	}
	session.releaseControl("native-pane", true)
	if !session.acquireControl("replacement-pane") {
		t.Fatal("repaint helper left its lease pinned against a different viewer")
	}
	session.releaseControl("replacement-pane", true)
}

func TestLegacyRepaintRejectsMissingClientIdentity(t *testing.T) {
	if _, err := openLegacyRepaintObserver(workerManifest{}, ""); err == nil {
		t.Fatal("legacy repaint accepted a missing client identity")
	}
}

func TestLegacyRepaintObserverWaitsForNewOutputAndQuiet(t *testing.T) {
	observerConnection, workerConnection := net.Pipe()
	defer observerConnection.Close()
	defer workerConnection.Close()
	observer := &legacyRepaintObserver{connection: observerConnection, sequence: 40}
	writeErr := make(chan error, 1)
	go func() {
		writer := protocol.NewWriter(workerConnection)
		if err := writer.Write(protocol.OutputFrame(40, []byte("old"))); err != nil {
			writeErr <- err
			return
		}
		if err := writer.Write(protocol.OutputFrame(41, []byte("repaint"))); err != nil {
			writeErr <- err
			return
		}
		writeErr <- nil
	}()

	sequence, err := observer.waitForOutputUntil(40, 250*time.Millisecond, 5*time.Millisecond)
	if err != nil {
		t.Fatalf("wait for repaint output: %v", err)
	}
	if sequence != 41 || observer.sequence != 41 {
		t.Fatalf("repaint sequence = %d, observer = %d; want 41", sequence, observer.sequence)
	}
	if err := <-writeErr; err != nil {
		t.Fatalf("write repaint output: %v", err)
	}
}

func TestLegacyRepaintObserverRejectsDeadlineWithoutOutput(t *testing.T) {
	observerConnection, workerConnection := net.Pipe()
	defer observerConnection.Close()
	defer workerConnection.Close()
	observer := &legacyRepaintObserver{connection: observerConnection, sequence: 7}

	sequence, err := observer.waitForOutputUntil(7, 10*time.Millisecond, time.Millisecond)
	if err == nil {
		t.Fatal("wait without repaint output unexpectedly succeeded")
	}
	if sequence != 7 || observer.sequence != 7 {
		t.Fatalf("deadline changed sequence to %d/%d", sequence, observer.sequence)
	}
}
