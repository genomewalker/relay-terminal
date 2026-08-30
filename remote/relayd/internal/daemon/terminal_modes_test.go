package daemon

import (
	"bytes"
	"errors"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestTerminalModeStateSurvivesPacketBoundaries(t *testing.T) {
	state := newTerminalModeState()
	for _, packet := range [][]byte{
		[]byte("\x1b[>"), []byte("7u\x1b[?20"), []byte("04h\x1b[?1006h"),
	} {
		state.ingest(packet)
	}
	prelude := state.presentationPrelude()
	for _, expected := range [][]byte{
		[]byte("\x1b[<65535u"), []byte("\x1b[>7u"),
		[]byte("\x1b[?1006h"), []byte("\x1b[?2004h"),
	} {
		if !bytes.Contains(prelude, expected) {
			t.Fatalf("presentation prelude %q does not contain %q", prelude, expected)
		}
	}
}

func TestTerminalModeStateTracksPopAndReset(t *testing.T) {
	state := newTerminalModeState()
	state.ingest([]byte("\x1b[>7u\x1b[>5u\x1b[<u\x1b[?2004h"))
	prelude := state.presentationPrelude()
	if !bytes.Contains(prelude, []byte("\x1b[>7u")) {
		t.Fatalf("keyboard pop did not restore prior flags: %q", prelude)
	}
	state.ingest([]byte("\x1bc"))
	prelude = state.presentationPrelude()
	if bytes.Contains(prelude, []byte("\x1b[>7u")) || bytes.Contains(prelude, []byte("\x1b[?2004h")) {
		t.Fatalf("RIS did not reset terminal modes: %q", prelude)
	}
}

func TestAttachReplaysDurableInputModesAfterScreenSuffix(t *testing.T) {
	session := &Session{
		clients:       make(map[*client]struct{}),
		agentClients:  make(map[*client]struct{}),
		terminalModes: newTerminalModeState(),
	}
	session.terminalModes.ingest([]byte("\x1b[>7u\x1b[?2004h"))
	session.sequence = 9
	session.replay = []record{{sequence: 9, data: []byte("\x1b[2Jcurrent composer")}}

	viewer, frames, _, _, _ := session.attach(0, 0, false)
	defer session.detach(viewer)
	if len(frames) < 2 {
		t.Fatalf("attach returned %d frames, want screen plus mode prelude", len(frames))
	}
	sequence, prelude, err := parseLastOutput(frames)
	if err != nil || sequence != 0 {
		t.Fatalf("last output is not a presentation frame: sequence=%d err=%v", sequence, err)
	}
	if !bytes.Contains(prelude, []byte("\x1b[>7u")) || !bytes.Contains(prelude, []byte("\x1b[?2004h")) {
		t.Fatalf("mode prelude was not replayed: %q", prelude)
	}
}

func parseLastOutput(frames []protocol.Frame) (uint64, []byte, error) {
	for index := len(frames) - 1; index >= 0; index-- {
		if frames[index].Type == protocol.Output {
			return protocol.ParseOutput(frames[index])
		}
	}
	return 0, nil, errors.New("no output frame")
}
