package daemon

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A Claude redraw is hundreds of small reads; they must leave the worker as
// one frame so the 512-frame viewer queue drains instead of dropping the pane.
func TestCoalesceQueuedOutputMergesARedrawBurstInOrder(t *testing.T) {
	queue := make(chan protocol.Frame, 512)
	var want bytes.Buffer
	for sequence := uint64(2); sequence <= 400; sequence++ {
		chunk := []byte{byte(sequence), '\x1b', '[', 'K'}
		want.Write(chunk)
		queue <- protocol.OutputFrame(sequence, chunk)
	}
	status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "exited"})
	queue <- status
	queue <- protocol.OutputFrame(401, []byte("after"))

	first := protocol.OutputFrame(1, []byte("first"))
	frames := coalesceQueuedOutput(first, queue)
	if len(frames) != 2 || frames[1].Type != protocol.Status {
		t.Fatalf("want merged output then the status, got %d frames", len(frames))
	}
	sequence, data, err := protocol.ParseOutput(frames[0])
	if err != nil || sequence != 400 || !bytes.Equal(data, append([]byte("first"), want.Bytes()...)) {
		t.Fatalf("merged frame: sequence=%d len=%d err=%v", sequence, len(data), err)
	}
	if len(queue) != 1 {
		t.Fatalf("output after the status must stay queued; %d left", len(queue))
	}
}

func TestCoalesceQueuedOutputNeverWaitsAndKeepsUnsequencedFrames(t *testing.T) {
	queue := make(chan protocol.Frame, 4)
	alone := protocol.OutputFrame(7, []byte("x"))
	if frames := coalesceQueuedOutput(alone, queue); len(frames) != 1 || !bytes.Equal(frames[0].Payload, alone.Payload) {
		t.Fatal("a lone frame must pass through unchanged")
	}
	unsequenced := protocol.OutputFrame(0, []byte("replay-control"))
	queue <- protocol.OutputFrame(8, []byte("y"))
	if frames := coalesceQueuedOutput(unsequenced, queue); len(frames) != 1 || len(queue) != 1 {
		t.Fatal("sequence-0 output is never merged")
	}
}

func TestCoalesceQueuedOutputBoundsOneFrame(t *testing.T) {
	queue := make(chan protocol.Frame, 64)
	big := bytes.Repeat([]byte("z"), 60<<10)
	for sequence := uint64(2); sequence <= 10; sequence++ {
		queue <- protocol.OutputFrame(sequence, big)
	}
	frames := coalesceQueuedOutput(protocol.OutputFrame(1, big), queue)
	total := 0
	for _, frame := range frames {
		total += len(frame.Payload) - 8
		if len(frame.Payload)-8 > viewerCoalesceBytes {
			t.Fatalf("frame of %d bytes exceeds the bound", len(frame.Payload)-8)
		}
	}
	last := frames[len(frames)-1]
	if binary.BigEndian.Uint64(last.Payload[:8]) >= 10 || len(queue) == 0 {
		t.Fatal("the bound must leave later output queued in order")
	}
	_ = total
}

// dandy-07, 2026-11-19: the shared SSH link stalled after a restart, d62c62eb's
// 512-frame queue filled and the view was cut ("Reconnecting"), every replay
// adding more traffic. A full queue now merges its waiting output instead.
func TestFullViewerQueueMergesOutputInsteadOfCuttingTheView(t *testing.T) {
	session := &Session{
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), eventHashes: make(map[[32]byte]struct{}),
	}
	viewer := newClient(512)
	session.clients[viewer] = struct{}{}
	var want bytes.Buffer
	for i := 0; i < 2000; i++ { // nothing drains: the link is stalled
		chunk := []byte{byte(i), byte(i >> 8), '\x1b', '[', 'K'}
		want.Write(chunk)
		session.publish(chunk)
	}
	select {
	case <-viewer.lagged:
		t.Fatal("a full queue of output cut the view")
	default:
	}
	if _, kept := session.clients[viewer]; !kept {
		t.Fatal("viewer was removed")
	}
	var got bytes.Buffer
	last := uint64(0)
	for len(viewer.frames) > 0 {
		sequence, data, err := protocol.ParseOutput(<-viewer.frames)
		if err != nil || sequence <= last {
			t.Fatalf("frame out of order: sequence=%d after %d err=%v", sequence, last, err)
		}
		last = sequence
		got.Write(data)
	}
	if last != 2000 || !bytes.Equal(got.Bytes(), want.Bytes()) {
		t.Fatalf("delivered %d bytes up to sequence %d; want %d bytes to 2000", got.Len(), last, want.Len())
	}
}

// Frames that are not output keep their place; with nothing to merge the view
// is still cut, and a merge never mutates a frame shared with other viewers.
func TestCompactQueuedOutputKeepsOrderAndCopiesSharedPayloads(t *testing.T) {
	shared := protocol.OutputFrame(1, []byte("a"))
	status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "clients"})
	frames, total := compactQueuedOutput([]protocol.Frame{shared, protocol.OutputFrame(2, []byte("b")), status, protocol.OutputFrame(3, []byte("c"))})
	if len(frames) != 3 || frames[1].Type != protocol.Status || total != 8*3+3+len(status.Payload) {
		t.Fatalf("got %d frames, total %d", len(frames), total)
	}
	if sequence, data, _ := protocol.ParseOutput(frames[0]); sequence != 2 || string(data) != "ab" {
		t.Fatalf("merged run: %d %q", sequence, data)
	}
	if sequence, data, _ := protocol.ParseOutput(shared); sequence != 1 || string(data) != "a" {
		t.Fatal("merging changed a frame another viewer shares")
	}
}
