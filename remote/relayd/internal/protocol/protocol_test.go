package protocol

import (
	"bytes"
	"encoding/json"
	"io"
	"testing"
)

type shortWriter struct {
	buffer bytes.Buffer
	limit  int
}

func (writer *shortWriter) Write(data []byte) (int, error) {
	if len(data) > writer.limit {
		data = data[:writer.limit]
	}
	return writer.buffer.Write(data)
}

type stalledWriter struct{}

func (stalledWriter) Write([]byte) (int, error) { return 0, nil }

func TestFrameRoundTrip(t *testing.T) {
	var wire bytes.Buffer
	w := NewWriter(&wire)
	want := OutputFrame(42, []byte("hello\x00terminal"))
	if err := w.Write(want); err != nil {
		t.Fatal(err)
	}
	got, err := ReadFrame(&wire)
	if err != nil {
		t.Fatal(err)
	}
	sequence, payload, err := ParseOutput(got)
	if err != nil {
		t.Fatal(err)
	}
	if sequence != 42 || !bytes.Equal(payload, []byte("hello\x00terminal")) {
		t.Fatalf("unexpected output: seq=%d payload=%q", sequence, payload)
	}
}

func TestWriterCompletesShortWritesWithoutDesynchronizingFrames(t *testing.T) {
	wire := &shortWriter{limit: 3}
	w := NewWriter(wire)
	want := []Frame{
		OutputFrame(41, bytes.Repeat([]byte("a"), 257)),
		OutputFrame(42, []byte("next frame")),
	}
	for _, frame := range want {
		if err := w.Write(frame); err != nil {
			t.Fatal(err)
		}
	}
	for index, expected := range want {
		got, err := ReadFrame(&wire.buffer)
		if err != nil {
			t.Fatalf("read frame %d: %v", index, err)
		}
		if got.Type != expected.Type || !bytes.Equal(got.Payload, expected.Payload) {
			t.Fatalf("frame %d was corrupted by short writes", index)
		}
	}
}

func TestWriterRejectsZeroProgress(t *testing.T) {
	if err := NewWriter(stalledWriter{}).Write(Frame{Type: Ping}); err != io.ErrShortWrite {
		t.Fatalf("zero-progress write error = %v, want %v", err, io.ErrShortWrite)
	}
}

func TestResizeRoundTrip(t *testing.T) {
	cols, rows, err := ParseResize(ResizeFrame(160, 48))
	if err != nil || cols != 160 || rows != 48 {
		t.Fatalf("got %dx%d, %v", cols, rows, err)
	}
}

func TestViewportCommitRoundTrip(t *testing.T) {
	generation, cols, rows, err := ParseViewportCommit(ViewportCommitFrame(42, 160, 48))
	if err != nil || generation != 42 || cols != 160 || rows != 48 {
		t.Fatalf("viewport commit = %d %d %d, %v", generation, cols, rows, err)
	}
	ackGeneration, repaintSequence, err := ParseViewportAck(ViewportAckFrame(42, 9001))
	if err != nil || ackGeneration != 42 || repaintSequence != 9001 {
		t.Fatalf("viewport ack = %d %d, %v", ackGeneration, repaintSequence, err)
	}
}

func TestArtifactRoundTrip(t *testing.T) {
	wantPath := "/home/user/generated.png"
	wantData := []byte{0x89, 'P', 'N', 'G'}
	path, data, err := ParseArtifact(ArtifactFrame(wantPath, wantData))
	if err != nil || path != wantPath || !bytes.Equal(data, wantData) {
		t.Fatalf("got path=%q data=%v err=%v", path, data, err)
	}
}

func TestAcknowledgedInputRoundTrip(t *testing.T) {
	clientID := [16]byte{1, 2, 3, 4, 5}
	frame := InputV2Frame(clientID, 42, []byte("command\n"))
	gotClientID, sequence, data, err := ParseInputV2(frame)
	if err != nil || gotClientID != clientID || sequence != 42 || !bytes.Equal(data, []byte("command\n")) {
		t.Fatalf("invalid input v2 round trip: client=%v sequence=%d data=%q err=%v", gotClientID, sequence, data, err)
	}
	ackClientID, ackSequence, err := ParseInputAck(InputAckFrame(clientID, sequence))
	if err != nil || ackClientID != clientID || ackSequence != sequence {
		t.Fatalf("invalid input ack round trip: client=%v sequence=%d err=%v", ackClientID, ackSequence, err)
	}
}

func TestHostEventRoundTrip(t *testing.T) {
	inner := Frame{Type: AgentEvent, Payload: []byte(`{"agent":"codex"}`)}
	outer := HostEventFrame("pane-123", inner)
	session, decoded, err := ParseHostEvent(outer)
	if err != nil || session != "pane-123" || decoded.Type != AgentEvent || !bytes.Equal(decoded.Payload, inner.Payload) {
		t.Fatalf("invalid host event: session=%q frame=%#v err=%v", session, decoded, err)
	}
}

func TestHelloRepaintPulseRoundTrip(t *testing.T) {
	want := HelloPayload{
		Version:               1,
		SessionID:             "pane-123",
		Cols:                  135,
		Rows:                  24,
		RepaintPulse:          true,
		RequireExistingWorker: true,
	}
	payload, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var got HelloPayload
	if err := json.Unmarshal(payload, &got); err != nil {
		t.Fatal(err)
	}
	if !got.RepaintPulse || !got.RequireExistingWorker || got.Cols != want.Cols || got.Rows != want.Rows {
		t.Fatalf("repaint hello did not round trip: %#v", got)
	}
}
