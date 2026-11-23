package daemon

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func numberedInput(i int) protocol.Frame {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, uint32(i))
	return protocol.Frame{Type: protocol.InputV2, Payload: payload}
}

// A worker that is slow to take input (2026-11-22, d62c62eb: about 0.9 s per
// frame on a loaded NFS home) must slow the pane down, not cut its route.
// Every frame past the 128-frame queue is held and reaches the worker in the
// order it was sent once the worker catches up.
func TestSlowWorkerHoldsInputInOrderInsteadOfClosingTheRoute(t *testing.T) {
	supervisorSide, workerSide := net.Pipe()
	defer workerSide.Close()
	session := newMultiplexedSession(supervisorSide, false, "pane")
	defer session.close()
	go session.forwardToWorker()

	const total = 600 // beyond the 128-frame queue, as in the incident burst
	for i := 0; i < total; i++ {
		session.enqueueOrClose(numberedInput(i))
	}
	if reason := session.recordedCloseReason(); reason != "" {
		t.Fatalf("a slow worker closed the route: %q", reason)
	}

	_ = workerSide.SetReadDeadline(time.Now().Add(10 * time.Second))
	for i := 0; i < total; i++ {
		if i == total/2 {
			// More input while the worker is still behind keeps its place.
			for j := total; j < total+20; j++ {
				session.enqueueOrClose(numberedInput(j))
			}
		}
		frame, err := protocol.ReadFrame(workerSide)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if got := int(binary.BigEndian.Uint32(frame.Payload)); got != i {
			t.Fatalf("frame %d arrived as %d: input was reordered", i, got)
		}
	}
	for j := total; j < total+20; j++ {
		frame, err := protocol.ReadFrame(workerSide)
		if err != nil {
			t.Fatalf("late frame %d: %v", j, err)
		}
		if got := int(binary.BigEndian.Uint32(frame.Payload)); got != j {
			t.Fatalf("late frame %d arrived as %d", j, got)
		}
	}
	if reason := session.recordedCloseReason(); reason != "" {
		t.Fatalf("route closed after catching up: %q", reason)
	}
	session.overflowMu.Lock()
	held, bytes := len(session.overflow), session.overflowBytes
	session.overflowMu.Unlock()
	if held != 0 || bytes != 0 {
		t.Fatalf("overflow not empty after draining: %d frames, %d bytes", held, bytes)
	}
}

// The byte bound closes a route whose worker has stopped, even with few frames.
func TestOverflowByteBoundClosesAStoppedWorkerRoute(t *testing.T) {
	supervisorSide, workerSide := net.Pipe()
	defer workerSide.Close()
	session := newMultiplexedSession(supervisorSide, false, "pane")
	for i := 0; i < cap(session.outbound); i++ {
		session.enqueueOrClose(protocol.Frame{Type: protocol.InputV2, Payload: []byte{'x'}})
	}
	big := protocol.Frame{Type: protocol.InputV2, Payload: make([]byte, routeOverflowBytes/2)}
	session.enqueueOrClose(big)
	session.enqueueOrClose(big)
	if reason := session.recordedCloseReason(); reason != "" {
		t.Fatalf("closed within the byte bound: %q", reason)
	}
	session.enqueueOrClose(protocol.Frame{Type: protocol.InputV2, Payload: []byte{'y'}})
	select {
	case <-session.closed:
	default:
		t.Fatal("a stopped worker past the byte bound kept its route")
	}
}
