package daemon

import (
	"bytes"
	"io"
	"reflect"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestTerminalReplayPreservesPartialUpdatesAndSequenceBoundaries(t *testing.T) {
	for _, alternate := range []bool{false, true} {
		prefix := ""
		if alternate {
			prefix = "\x1b[?1049h"
		}
		frames := []protocol.Frame{
			protocol.OutputFrame(41, append([]byte(prefix), bytes.Repeat([]byte("text"), 80)...)),
			protocol.OutputFrame(42, []byte("\x1b[1;1Hone\x1b[10;1Htwo\x1b[20;1Hthree\x1b[3")),
			protocol.OutputFrame(43, []byte("1mstatus\x1b[0m")),
		}
		var wire bytes.Buffer
		if err := writeTerminalReplay(protocol.NewWriter(&wire), frames); err != nil {
			t.Fatal(err)
		}
		for _, want := range frames {
			got, err := protocol.ReadFrame(&wire)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("alternate=%v: replay changed: got %#v, want %#v, error %v", alternate, got, want, err)
			}
		}
		frame, err := protocol.ReadFrame(&wire)
		if err != nil || frame.Type != protocol.Status {
			t.Fatalf("missing completion status: %#v, %v", frame, err)
		}
		var status protocol.StatusPayload
		if err := protocol.DecodeJSON(frame, &status); err != nil || status.State != "caught_up" {
			t.Fatalf("invalid completion: %#v, %v", status, err)
		}
		if _, err := protocol.ReadFrame(&wire); err != io.EOF {
			t.Fatalf("unexpected trailing frame: %v", err)
		}
	}
}

func TestViewportMailboxKeepsAtomicCommitAheadOfAnimationResize(t *testing.T) {
	mailbox := make(chan viewportOperation, 1)
	commit := viewportOperation{generation: 7, cols: 120, rows: 40, commit: true}
	enqueueViewportOperation(mailbox, commit)
	enqueueViewportOperation(mailbox, viewportOperation{cols: 121, rows: 40})

	if got := <-mailbox; got != commit {
		t.Fatalf("ordinary resize displaced pending commit: %#v", got)
	}
}

func TestViewportMailboxCoalescesToNewestCommit(t *testing.T) {
	mailbox := make(chan viewportOperation, 1)
	enqueueViewportOperation(mailbox, viewportOperation{cols: 90, rows: 30})
	latest := viewportOperation{generation: 9, cols: 140, rows: 50, commit: true}
	enqueueViewportOperation(mailbox, latest)

	if got := <-mailbox; got != latest {
		t.Fatalf("new commit did not replace pending resize: %#v", got)
	}
}
