package daemon

import (
	"bytes"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// The child shell is a stand-in for a primary-screen TUI: on SIGWINCH it
// repaints only three cursor-addressed rows and never clears the screen.
// Everything printed before the resize is transcript the repaint does not
// replace, exactly like Codex or Claude history above the composer.
const attachRepaintScript = `exec /bin/sh -c '` +
	`trap "printf \"\\033[1;1Hrow-one %0300d\\033[10;1Hrow-ten\\033[20;1Hrow-twenty\" 0" WINCH; ` +
	`printf "transcript line one\r\ntranscript line two\r\nREADY\r\n"; ` +
	`while :; do sleep 0.05; done'`

func ringBytesAfter(session *Session, sequence uint64) []byte {
	session.mu.Lock()
	defer session.mu.Unlock()
	var stream []byte
	for _, item := range session.replay {
		if item.sequence > sequence {
			stream = append(stream, item.data...)
		}
	}
	return stream
}

func waitForRingBytes(t *testing.T, session *Session, marker string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if bytes.Contains(ringBytesAfter(session, 0), []byte(marker)) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("session never produced %q: ring=%q", marker, ringBytesAfter(session, 0))
}

type attachCapture struct {
	statuses     []protocol.StatusPayload
	frames       []protocol.Frame
	output       []byte   // sequenced terminal bytes, in wire order
	presentation [][]byte // sequence-zero frames (mode prelude only)
}

// attachAndCapture performs a real worker attach over an in-memory socket and
// reads until caught_up plus every live frame until stopMarker is observed.
func attachAndCapture(
	t *testing.T, session *Session, config WorkerConfig,
	cols, rows uint16, lastSequence uint64, stopMarker string,
) attachCapture {
	t.Helper()
	server, client := net.Pipe()
	defer client.Close()
	go serveWorkerConnection(server, config, session)

	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: config.SessionID, WorkerToken: config.Token,
		Cols: cols, Rows: rows, LastSeq: lastSequence, ClientID: "attach-test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := protocol.NewWriter(client).Write(hello); err != nil {
		t.Fatal(err)
	}

	var capture attachCapture
	caughtUp := false
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
		frame, readErr := protocol.ReadFrame(client)
		if readErr != nil {
			if caughtUp && bytes.Contains(capture.output, []byte(stopMarker)) {
				break
			}
			t.Fatalf("read failed before %q arrived (caught_up=%v): %v output=%q",
				stopMarker, caughtUp, readErr, capture.output)
		}
		capture.frames = append(capture.frames, frame)
		switch frame.Type {
		case protocol.Status:
			var status protocol.StatusPayload
			if err := protocol.DecodeJSON(frame, &status); err != nil {
				t.Fatal(err)
			}
			capture.statuses = append(capture.statuses, status)
			if status.State == "caught_up" {
				caughtUp = true
			}
		case protocol.Output:
			sequence, data, err := protocol.ParseOutput(frame)
			if err != nil {
				t.Fatal(err)
			}
			if sequence == 0 {
				capture.presentation = append(capture.presentation, data)
			} else {
				capture.output = append(capture.output, data...)
			}
		}
		if caughtUp && bytes.Contains(capture.output, []byte(stopMarker)) {
			break
		}
	}
	if !caughtUp {
		t.Fatalf("attach never reached caught_up: statuses=%+v", capture.statuses)
	}
	return capture
}

func assertNoSyntheticClear(t *testing.T, capture attachCapture, lastSequence uint64) {
	t.Helper()
	for _, frame := range capture.frames {
		if frame.Type != protocol.Output {
			continue
		}
		sequence, _, _ := protocol.ParseOutput(frame)
		if sequence != 0 && sequence <= lastSequence {
			t.Fatalf("attach replayed sequence %d at or below resume cursor %d", sequence, lastSequence)
		}
	}
	for _, clear := range []string{"\x1b[2J", "\x1b[3J", "\x1bc"} {
		if bytes.Contains(capture.output, []byte(clear)) {
			t.Fatalf("attach synthesized %q; the application never cleared its screen: %q", clear, capture.output)
		}
		// Sequence zero is reserved for the input-mode prelude. A clear there
		// is the exact frame older workers used to erase the transcript.
		for _, data := range capture.presentation {
			if bytes.Contains(data, []byte(clear)) {
				t.Fatalf("attach emitted a presentation-only %q frame: %q", clear, data)
			}
		}
	}
}

// Regression: an attach whose native grid differs from the PTY grid resizes
// the PTY, the TUI answers SIGWINCH with a partial cursor-addressed repaint,
// and the client must receive exactly the ring bytes after its resume cursor.
// Older workers classified that repaint as a full frame and prepended
// ESC[2J ESC[H, erasing every transcript row the repaint did not touch.
func TestAttachResizeReplayPreservesTranscriptBytes(t *testing.T) {
	config := WorkerConfig{SessionID: "attach-resize-test", Token: "token"}
	session, err := startSession(config.SessionID, attachRepaintScript, "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.terminate()
	waitForRingBytes(t, session, "READY")
	// Let the shell settle so the resume cursor is a clean pre-resize boundary.
	time.Sleep(50 * time.Millisecond)
	before, _, _, _ := session.snapshot()

	// Incremental reconnect: the client already rendered everything up to
	// `before` and only the post-resize repaint may follow.
	capture := attachAndCapture(t, session, config, 100, 30, before, "row-twenty")
	assertNoSyntheticClear(t, capture, before)
	expected := ringBytesAfter(session, before)
	if !bytes.HasPrefix(expected, capture.output) || !bytes.Contains(capture.output, []byte("row-one")) {
		t.Fatalf("incremental replay diverged from ring:\n got  %q\n ring %q", capture.output, expected)
	}
	if strings.Contains(string(capture.output), "transcript line") {
		t.Fatalf("incremental replay resent pre-cursor transcript: %q", capture.output)
	}
	if capture.statuses[0].State != "attached" || capture.statuses[0].OutputReset {
		t.Fatalf("unexpected attach status: %+v", capture.statuses[0])
	}

	// Fresh renderer at the now-current grid: the whole ring, transcript
	// included, must arrive verbatim with no synthetic clear in front.
	fresh := attachAndCapture(t, session, config, 100, 30, 0, "row-twenty")
	assertNoSyntheticClear(t, fresh, 0)
	whole := ringBytesAfter(session, 0)
	if !bytes.HasPrefix(whole, fresh.output) ||
		!bytes.Contains(fresh.output, []byte("transcript line one")) ||
		!bytes.Contains(fresh.output, []byte("row-twenty")) {
		t.Fatalf("fresh replay diverged from ring:\n got  %q\n ring %q", fresh.output, whole)
	}
}

// A cached agent frame still needs a repaint when its grid is unchanged.
// Exercise a real foreground PTY instead of assuming TIOCSWINSZ emits it.
func TestAttachUnchangedAgentGridProducesRepaint(t *testing.T) {
	command := strings.Replace(attachRepaintScript, `trap "printf`, `trap "stty size; printf`, 1)
	session, err := startSession("attach-unchanged-agent-test", command, "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	defer session.terminate()
	waitForRingBytes(t, session, "READY")
	session.mu.Lock()
	session.activeAgentRoots["fixture-agent"] = []byte(`{"agent":"codex"}`)
	session.mu.Unlock()

	before, _ := session.resizeForAttach(80, 24, true)
	waitForRingBytes(t, session, "row-twenty")
	output := ringBytesAfter(session, before)
	if !bytes.Contains(output, []byte("24 80")) || !bytes.Contains(output, []byte("row-twenty")) {
		t.Fatalf("repaint did not use the renderer's grid: %q", output)
	}
	if bytes.Contains(output, []byte("23 80")) {
		t.Fatalf("repaint used a temporary row count: %q", output)
	}
	if !bytes.Contains(ringBytesAfter(session, 0), []byte("transcript line one")) {
		t.Fatal("attach lost the screen base")
	}
}

// Random worker sequence origins are not evidence of replay-ring eviction.
func TestFreshAttachDistinguishesSequenceOriginFromEviction(t *testing.T) {
	for _, trimmed := range []bool{false, true} {
		t.Run(map[bool]string{false: "complete", true: "evicted"}[trimmed], func(t *testing.T) {
			origin := outputSequenceFromEntropy(42)
			transcript := []byte("transcript retained from worker start")
			session := &Session{
				sequence:      origin + 1,
				replay:        []record{{sequence: origin + 1, data: transcript}},
				replayTrimmed: trimmed,
				clients:       make(map[*client]struct{}),
				terminalModes: newTerminalModeState(),
			}
			if got := session.needsFreshAttachReplay(0); got != trimmed {
				t.Fatalf("needs repaint = %v, want %v", got, trimmed)
			}
			viewer, frames, _, _, _ := session.attach(0, 0, false)
			defer session.detach(viewer)
			var output []byte
			for _, frame := range frames {
				if frame.Type == protocol.Output {
					_, data, err := protocol.ParseOutput(frame)
					if err != nil {
						t.Fatal(err)
					}
					output = append(output, data...)
				}
			}
			if bytes.Contains(output, transcript) == trimmed {
				t.Fatalf("trimmed=%v: unexpected transcript replay %q", trimmed, output)
			}
			if bytes.Contains(output, []byte("\x1bc")) != trimmed {
				t.Fatalf("trimmed=%v: unexpected presentation reset %q", trimmed, output)
			}
		})
	}
}
