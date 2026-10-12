package daemon

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestDedicatedReplayBatchesHistoryAndPassesLiveStreamUnchanged(t *testing.T) {
	var source, destination bytes.Buffer
	w := protocol.NewWriter(&source)
	attached, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "attached", Capabilities: []string{"event_cursor_v1"}})
	caughtUp, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "caught_up"})
	for _, f := range []protocol.Frame{attached, protocol.OutputFrame(1, []byte("first")), protocol.OutputFrame(2, []byte("second")), caughtUp, protocol.OutputFrame(3, []byte("live"))} {
		if err := w.Write(f); err != nil {
			t.Fatal(err)
		}
	}
	if err := forwardTerminalReplay(&destination, &source); err != nil {
		t.Fatal(err)
	}
	var frames []protocol.Frame
	for {
		f, err := protocol.ReadFrame(&destination)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		frames = append(frames, f)
	}
	if len(frames) != 4 || !bytes.Equal(frames[1].Payload, protocol.OutputFrame(2, []byte("firstsecond")).Payload) || !bytes.Equal(frames[3].Payload, protocol.OutputFrame(3, []byte("live")).Payload) {
		t.Fatal("dedicated replay lost bytes, cursor or live ordering")
	}
}

func TestTerminalReplayBatchPreservesBytesCursorAndBoundaries(t *testing.T) {
	var frames []protocol.Frame
	b := terminalReplayBatch{emit: func(f protocol.Frame) error { frames = append(frames, f); return nil }}
	status := func(state string) protocol.Frame {
		f, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: state, Capabilities: []string{"event_cursor_v1"}})
		return f
	}
	input := []protocol.Frame{status("attached"), protocol.OutputFrame(1, []byte("\x1b[")), protocol.OutputFrame(2, []byte("31mtext")), protocol.OutputFrame(0, []byte("reset")), protocol.OutputFrame(3, []byte("tail")), status("caught_up"), protocol.OutputFrame(4, []byte("live"))}
	for _, f := range input {
		if err := b.write(f); err != nil {
			t.Fatal(err)
		}
	}
	if len(frames) != 6 {
		t.Fatalf("frames=%d, want 6", len(frames))
	}
	if binary.BigEndian.Uint64(frames[1].Payload[:8]) != 2 || !bytes.Equal(frames[1].Payload[8:], []byte("\x1b[31mtext")) {
		t.Fatal("batched bytes or resume cursor changed")
	}
	if !bytes.Equal(frames[2].Payload, input[3].Payload) || !bytes.Equal(frames[5].Payload, input[6].Payload) {
		t.Fatal("reset or live output delayed/reordered")
	}
}

func TestTerminalReplayBatchBoundsMemoryAndKeepsLegacyOutputImmediate(t *testing.T) {
	var frames []protocol.Frame
	b := terminalReplayBatch{emit: func(f protocol.Frame) error { frames = append(frames, f); return nil }}
	if err := b.write(protocol.OutputFrame(1, []byte("legacy"))); err != nil {
		t.Fatal(err)
	}
	if len(frames) != 1 {
		t.Fatal("legacy output buffered without explicit boundary")
	}
	b.replaying = true
	chunk := bytes.Repeat([]byte("x"), 1000)
	for i := 2; i < 1002; i++ {
		if err := b.write(protocol.OutputFrame(uint64(i), chunk)); err != nil {
			t.Fatal(err)
		}
	}
	if err := b.flush(); err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, f := range frames[1:] {
		if len(f.Payload) > terminalReplayBatchBytes {
			t.Fatal("batch exceeded bound")
		}
		total += len(f.Payload) - 8
	}
	if total != 1000000 {
		t.Fatalf("lost bytes: %d", total)
	}
}
