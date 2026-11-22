package daemon

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"testing"

	"github.com/relay-terminal/relayd/internal/programstatus"
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

func programStatusTestFrame(t *testing.T, revision uint64, replay bool) protocol.Frame {
	t.Helper()
	records := []programstatus.Record{}
	frame, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "program_status", ProgramStatus: &records, ProgramStatusRevision: revision, ProgramStatusReplay: replay,
	})
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

// 2026-11-22: scrolling a Claude pane still showed "Reconnecting" (c0441e7b
// 10:03, 32655e54 12:40) on workers that already merge output. Claude's
// redraws arrive interleaved with program status updates, so no two output
// frames were adjacent, nothing merged, and the full queue cut the view.
func TestFullViewerQueueDropsSupersededProgramStatusBetweenOutput(t *testing.T) {
	viewer := newClient(512)
	var want bytes.Buffer
	sequence := uint64(0)
	replay := programStatusTestFrame(t, 1, true)
	viewer.frames <- replay
	var latest protocol.Frame
	for len(viewer.frames) < cap(viewer.frames) {
		if len(viewer.frames)%2 == 1 {
			sequence++
			chunk := []byte{byte(sequence), '\x1b', '[', 'K'}
			want.Write(chunk)
			viewer.frames <- protocol.OutputFrame(sequence, chunk)
		} else {
			latest = programStatusTestFrame(t, sequence+1, false)
			viewer.frames <- latest
		}
	}
	if !viewer.makeRoom(1) {
		t.Fatal("output interleaved with program status cut the view")
	}
	var got bytes.Buffer
	statuses, replays := 0, 0
	last := uint64(0)
	var lastStatus protocol.Frame
	for len(viewer.frames) > 0 {
		frame := <-viewer.frames
		if frame.Type == protocol.Status {
			var payload protocol.StatusPayload
			if err := protocol.DecodeJSON(frame, &payload); err != nil || payload.State != "program_status" {
				t.Fatalf("unexpected status %q err=%v", payload.State, err)
			}
			statuses++
			if payload.ProgramStatusReplay {
				replays++
			}
			lastStatus = frame
			continue
		}
		seq, data, err := protocol.ParseOutput(frame)
		if err != nil || seq <= last {
			t.Fatalf("output out of order: %d after %d err=%v", seq, last, err)
		}
		last = seq
		got.Write(data)
	}
	if !bytes.Equal(got.Bytes(), want.Bytes()) || last != sequence {
		t.Fatalf("output changed: %d bytes to %d; want %d bytes to %d", got.Len(), last, want.Len(), sequence)
	}
	if replays != 1 || statuses != 2 || !bytes.Equal(lastStatus.Payload, latest.Payload) {
		t.Fatalf("statuses=%d replays=%d; want the replay snapshot and only the latest update", statuses, replays)
	}
}

func agentEventTestFrame(n int) protocol.Frame {
	return protocol.Frame{Type: protocol.AgentEvent, Payload: []byte(fmt.Sprintf(`{"sequence":%d}`, n))}
}

// Dense agent events (a Claude turn streaming transcript events while it
// redraws) interleave with output the same way program status does. Events
// are sequenced and cannot be dropped or merged, so a full queue moves them
// after the output they separate: each stream keeps its order, artifacts and
// statuses stay where they are, and the output merges.
func TestFullViewerQueueMovesAgentEventsBehindOutputWithoutReorderingEither(t *testing.T) {
	viewer := newClient(512)
	var want bytes.Buffer
	var wantEvents []string
	sequence, events := uint64(0), 0
	artifactAt, seqAtArtifact := 300, uint64(0)
	for len(viewer.frames) < cap(viewer.frames) {
		switch {
		case len(viewer.frames) == artifactAt:
			seqAtArtifact = sequence
			viewer.frames <- protocol.ArtifactFrame("/tmp/a.png", []byte("img"))
		case len(viewer.frames)%2 == 0:
			sequence++
			chunk := []byte{byte(sequence), byte(sequence >> 8), '\x1b', '[', 'K'}
			want.Write(chunk)
			viewer.frames <- protocol.OutputFrame(sequence, chunk)
		default:
			events++
			frame := agentEventTestFrame(events)
			wantEvents = append(wantEvents, string(frame.Payload))
			viewer.frames <- frame
		}
	}
	if !viewer.makeRoom(1) {
		t.Fatal("output interleaved with agent events cut the view")
	}
	var got bytes.Buffer
	var gotEvents []string
	last := uint64(0)
	artifactSeen, crossed := false, false
	for len(viewer.frames) > 0 {
		frame := <-viewer.frames
		switch frame.Type {
		case protocol.AgentEvent:
			gotEvents = append(gotEvents, string(frame.Payload))
		case protocol.Output:
			seq, data, err := protocol.ParseOutput(frame)
			if err != nil || seq <= last {
				t.Fatalf("output out of order: %d after %d err=%v", seq, last, err)
			}
			if artifactSeen != (seq > seqAtArtifact) {
				crossed = true
			}
			last = seq
			got.Write(data)
		default:
			artifactSeen = true
		}
	}
	if !bytes.Equal(got.Bytes(), want.Bytes()) || last != sequence {
		t.Fatalf("output changed: %d bytes to %d; want %d bytes to %d", got.Len(), last, want.Len(), sequence)
	}
	if fmt.Sprint(gotEvents) != fmt.Sprint(wantEvents) {
		t.Fatalf("agent events lost or reordered: %d of %d", len(gotEvents), len(wantEvents))
	}
	if !artifactSeen || crossed {
		t.Fatalf("output crossed the artifact barrier (artifact seen=%v)", artifactSeen)
	}
}
