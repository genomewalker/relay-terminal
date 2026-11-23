package daemon

import (
	"net"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A route whose worker stops draining client frames, past the queue and its
// overflow, is closed by the
// supervisor, and the route_closed status must say so: the app cannot tell
// this cut from a worker that cut a lagging viewer (2026-11-22, d0b0ff50).
func TestFullInputQueueRecordsWhyTheRouteClosed(t *testing.T) {
	supervisorSide, workerSide := net.Pipe()
	defer workerSide.Close()
	session := newMultiplexedSession(supervisorSide, false, "pane")
	// The queue and the whole overflow fill without closing the route.
	for i := 0; i < cap(session.outbound)+routeOverflowFrames; i++ {
		session.enqueueOrClose(protocol.Frame{Type: protocol.Input, Payload: []byte{'x'}})
	}
	if session.recordedCloseReason() != "" {
		t.Fatalf("a queue with room closed the route: %q", session.recordedCloseReason())
	}
	session.enqueueOrClose(protocol.Frame{Type: protocol.Input, Payload: []byte{'x'}})
	select {
	case <-session.closed:
	default:
		t.Fatal("a full input queue did not close the route")
	}
	if reason := session.recordedCloseReason(); !strings.Contains(reason, "not draining") || !strings.Contains(reason, "128") {
		t.Fatalf("close reason %q does not name the full input queue", reason)
	}
	session.closeWith("a later reason")
	if reason := session.recordedCloseReason(); !strings.Contains(reason, "not draining") {
		t.Fatalf("a later close replaced the first reason: %q", reason)
	}
}
