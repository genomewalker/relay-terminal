package daemon

import (
	"bytes"
	"io"
	"testing"
)

func TestTerminalUnpressedMouseMotionPreservesEnrollmentAndDelivery(t *testing.T) {
	for _, data := range [][]byte{
		[]byte("\x1b[<35;12;10M"), []byte("\x1b[<51;12;10M"), []byte("\x1b[<63;12;10M"),
		// Bounded decimal fields accept leading zeroes without changing meaning.
		[]byte("\x1b[<035;0012;0010M"),
		[]byte("\x1b[O\x1b[<35;12;10M\x1b[I"), []byte("\x1b[<35;12;10M\x1b[<35;13;10M"),
	} {
		for _, acknowledged := range []bool{false, true} {
			for _, controlled := range []bool{false, true} {
				for _, guarded := range []bool{false, true} {
					session, reader := focusInputFixture(t)
					session.rotationControlled, session.rotationGuardInstalled = controlled, guarded
					client := [16]byte{3}
					var err error
					if acknowledged {
						err = session.acknowledgedInput(client, 1, data)
						if err == nil {
							err = session.acknowledgedInput(client, 1, data)
						}
					} else {
						err = session.input(data)
					}
					if err != nil {
						t.Fatal(err)
					}
					record := session.hostRotation.snapshot()
					if !record.Enabled || record.State != "monitoring" || record.Generation != 7 ||
						session.humanInputRevision != 0 || session.rotationHumanInputSeen {
						t.Fatalf("unpressed pointer motion caused takeover: data=%q ack=%v controlled=%v guarded=%v record=%+v", data, acknowledged, controlled, guarded, record)
					}
					if acknowledged && session.inputSequences[client] != 1 {
						t.Fatal("passive input was not acknowledged")
					}
					session.pty.Close()
					got, err := io.ReadAll(reader)
					if err != nil || !bytes.Equal(got, data) {
						t.Fatalf("passive input lost or replayed: %q -> %q %v", data, got, err)
					}
				}
			}
		}
	}
}

func TestTerminalPassiveReportsNeverHideButtonsWheelKeysOrMalformedInput(t *testing.T) {
	for _, data := range [][]byte{
		[]byte("\x1b[<0;12;10M"), []byte("\x1b[<0;12;10m"), []byte("\x1b[<32;12;10M"),
		[]byte("\x1b[<64;12;10M"), []byte("\x1b[<67;12;10M"), []byte("\x1b[<81;12;10M"),
		[]byte("\x1b[<163;12;10M"), []byte("\x1b[<35;12;10m"), []byte("\x1b[<35;;12;10M"),
		[]byte("\x1b[<35;0;10M"), []byte("\x1b[<35;12;0M"), []byte("\x1b[MC!!"),
		[]byte("\x1b[<35;1"), []byte("2;10M"), []byte("\x1b[<0000000000035;12;10M"),
		[]byte("\x1b[<35;12;10"), []byte("\x1b[<35;12;10Ma"), []byte("\x1b[I\x1b[<64;12;10M"),
		[]byte("\x1b[<999999999999999999999;12;10M"), []byte("\x1b[200~\x1b[<35;12;10M\x1b[201~"),
	} {
		for _, acknowledged := range []bool{false, true} {
			session, reader := focusInputFixture(t)
			var err error
			if acknowledged {
				err = session.acknowledgedInput([16]byte{4}, 1, data)
			} else {
				err = session.input(data)
			}
			if err != nil {
				t.Fatal(err)
			}
			record := session.hostRotation.snapshot()
			if record.Enabled || record.State != "human_takeover" || record.Generation != 8 || session.humanInputRevision != 1 {
				t.Fatalf("human or malformed input hidden: %q %+v", data, record)
			}
			session.pty.Close()
			got, err := io.ReadAll(reader)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("input changed: %q -> %q %v", data, got, err)
			}
		}
	}
}
