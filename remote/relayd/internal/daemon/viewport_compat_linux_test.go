//go:build linux

package daemon

import (
	"net"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

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
