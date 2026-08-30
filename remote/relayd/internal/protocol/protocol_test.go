package protocol

import (
	"bytes"
	"testing"
)

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
