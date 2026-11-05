package daemon

import (
	"bytes"
	"io"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// Relay's own maintenance keystrokes (Ctrl-G, editor keys, /exit, resume,
// compiled prompts) must not look like a human takeover of context rotation.
func TestAutomationInputIsDeliveredWithoutHumanTakeover(t *testing.T) {
	for _, data := range [][]byte{[]byte("\x07"), []byte("\x1b[200~/exit\x1b[201~\r"), []byte("refined prompt 🧬\r")} {
		for _, controlled := range []bool{false, true} {
			session, reader := focusInputFixture(t)
			session.rotationControlled = controlled
			client := [16]byte{5}
			if err := session.acknowledgedInputFrom(client, 1, data, true); err != nil {
				t.Fatal(err)
			}
			// A replayed sequence is acknowledged without a second write.
			if err := session.acknowledgedInputFrom(client, 1, data, true); err != nil {
				t.Fatal(err)
			}
			record := session.hostRotation.snapshot()
			if !record.Enabled || record.State == "human_takeover" || record.Generation != 8 ||
				session.humanInputRevision != 0 || session.rotationHumanInputSeen || session.automationInputRevision != 1 {
				t.Fatalf("automation input caused takeover or was not fenced: %q controlled=%v record=%+v human=%d automation=%d seen=%v",
					data, controlled, record, session.humanInputRevision, session.automationInputRevision, session.rotationHumanInputSeen)
			}
			if record.State != "awaiting_completed_turn" || record.Decision != nil || record.Preparation != nil {
				t.Fatalf("automation input left a stale rotation decision: %+v", record)
			}
			if session.inputSequences[client] != 1 {
				t.Fatal("automation input was not acknowledged")
			}
			session.pty.Close()
			got, err := io.ReadAll(reader)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("automation input lost or replayed: %q -> %q %v", data, got, err)
			}
		}
	}
}

func TestSameBytesAsHumanInputStillTakeOver(t *testing.T) {
	session, _ := focusInputFixture(t)
	if err := session.acknowledgedInputFrom([16]byte{6}, 1, []byte("\x07"), false); err != nil {
		t.Fatal(err)
	}
	record := session.hostRotation.snapshot()
	if record.Enabled || record.State != "human_takeover" || session.humanInputRevision != 1 || session.automationInputRevision != 0 {
		t.Fatalf("human input no longer takes over: %+v", record)
	}
}

func TestAutomationInputIsRefusedWhileRotationOwnsInput(t *testing.T) {
	session, reader := focusInputFixture(t)
	session.rotationControlled, session.rotationGuardInstalled = true, true
	client := [16]byte{7}
	if err := session.acknowledgedInputFrom(client, 1, []byte("/exit\r"), true); err == nil {
		t.Fatal("automation input typed into a rotation-owned terminal")
	}
	record := session.hostRotation.snapshot()
	if !record.Enabled || record.State != "monitoring" || record.Generation != 7 ||
		session.automationInputRevision != 0 || session.inputSequences[client] != 0 {
		t.Fatalf("refused automation input changed state: %+v", record)
	}
	session.pty.Close()
	if got, _ := io.ReadAll(reader); len(got) != 0 {
		t.Fatalf("refused automation input reached the PTY: %q", got)
	}
}

func TestAutomationInputPassiveReportsChangeNothing(t *testing.T) {
	session, _ := focusInputFixture(t)
	if err := session.acknowledgedInputFrom([16]byte{8}, 1, []byte("\x1b[I"), true); err != nil {
		t.Fatal(err)
	}
	record := session.hostRotation.snapshot()
	if record.State != "monitoring" || record.Generation != 7 || session.automationInputRevision != 0 {
		t.Fatalf("passive report advanced automation state: %+v", record)
	}
}

func TestAutomationInputFrameRoundTrip(t *testing.T) {
	client := [16]byte{9, 9}
	frame := protocol.AutomationInputV2Frame(client, 42, []byte("/exit\r"))
	if frame.Type != protocol.AutomationInputV2 {
		t.Fatalf("type %d", frame.Type)
	}
	gotClient, sequence, data, err := protocol.ParseInputV2(frame)
	if err != nil || gotClient != client || sequence != 42 || string(data) != "/exit\r" {
		t.Fatalf("round trip: %v %v %d %q", err, gotClient, sequence, data)
	}
	if _, _, _, err := protocol.ParseInputV2(protocol.Frame{Type: protocol.Output, Payload: frame.Payload}); err == nil {
		t.Fatal("parsed a non-input frame")
	}
}
