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
