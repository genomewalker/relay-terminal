package daemon

import (
	"bytes"
	"io"
	"testing"
)

// Terminal replies to a program's capability query (Ghostty answers DA1/DA2
// when an agent or editor starts) are not human input. Observed live:
// 06:28:38Z a 12-byte DA1 and 10-byte DA2 reply caused human_takeover.
func TestTerminalDeviceRepliesPreserveEnrollment(t *testing.T) {
	for _, data := range [][]byte{
		[]byte("\x1b[?62;22;52c"), []byte("\x1b[>1;10;0c"), []byte("\x1b[?1;2c"),
		[]byte("\x1b[?2026;2$y"), []byte("\x1b[?0u"), []byte("\x1b[?15u"),
		[]byte("\x1b[24;80R"), []byte("\x1b[1;1R"), []byte("\x1b[1;17R"), []byte("\x1b[4;600;800t"), []byte("\x1b[8;40;120t"),
		[]byte("\x1b[O\x1b[?62;22;52c\x1b[>1;10;0c\x1b[I"),
	} {
		for _, acknowledged := range []bool{false, true} {
			session, reader := focusInputFixture(t)
			var err error
			if acknowledged {
				err = session.acknowledgedInput([16]byte{11}, 1, data)
			} else {
				err = session.input(data)
			}
			if err != nil {
				t.Fatal(err)
			}
			record := session.hostRotation.snapshot()
			if !record.Enabled || record.State != "monitoring" || record.Generation != 7 || session.humanInputRevision != 0 {
				t.Fatalf("device reply caused takeover: %q ack=%v %+v", data, acknowledged, record)
			}
			session.pty.Close()
			if got, _ := io.ReadAll(reader); !bytes.Equal(got, data) {
				t.Fatalf("device reply not delivered: %q -> %q", data, got)
			}
		}
	}
}

// Anything a key can produce still takes over: modified F3 looks like a
// cursor report, kitty key events end in u, and so on.
func TestTerminalDeviceReplyRuleNeverHidesKeys(t *testing.T) {
	for _, data := range [][]byte{
		[]byte("\x1b[1;5R"), []byte("\x1b[1;2R"), []byte("\x1b[1;16R"), []byte("\x1b[0;0R"),
		[]byte("\x1b[97;5u"), []byte("\x1b[13u"), []byte("\x1b[A"), []byte("\x1b[2~"), []byte("\x1b[c"),
		[]byte("\x1b[62;22c"), []byte("\x1b[?62;22"), []byte("\x1b[?62;22ca"), []byte("\x1b[?;c"),
		[]byte("\x1b[?2026$y"), []byte("\x1b[3;1;1t"), []byte("\x1b[4;1t"), []byte("x\x1b[?62;22c"),
		[]byte("\x1b[200~\x1b[?62;22c\x1b[201~"),
	} {
		session, _ := focusInputFixture(t)
		if err := session.input(data); err != nil {
			t.Fatal(err)
		}
		record := session.hostRotation.snapshot()
		if record.Enabled || record.State != "human_takeover" || session.humanInputRevision != 1 {
			t.Fatalf("key or malformed input hidden as a device reply: %q %+v", data, record)
		}
	}
}
