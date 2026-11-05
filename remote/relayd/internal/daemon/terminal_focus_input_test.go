package daemon

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func focusInputFixture(t *testing.T) (*Session, *os.File) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reader.Close(); writer.Close() })
	supervisor := &hostRotationSupervisor{path: filepath.Join(root, "state.json"),
		record: hostRotationRecord{Version: 1, Enabled: true, State: "monitoring", Generation: 7}}
	return &Session{pty: writer, hostRotation: supervisor, inputSequences: make(map[[16]byte]uint64)}, reader
}

func TestTerminalFocusReportsPreserveEnrollmentAndAcknowledgedInput(t *testing.T) {
	for _, controlled := range []bool{false, true} {
		for _, guarded := range []bool{false, true} {
			session, reader := focusInputFixture(t)
			session.rotationControlled, session.rotationGuardInstalled = controlled, guarded
			client := [16]byte{1}
			if err := session.input([]byte("\x1b[I")); err != nil {
				t.Fatal(err)
			}
			if err := session.acknowledgedInput(client, 1, []byte("\x1b[O")); err != nil {
				t.Fatal(err)
			}
			if err := session.acknowledgedInput(client, 1, []byte("\x1b[O")); err != nil {
				t.Fatal(err)
			}
			record := session.hostRotation.snapshot()
			if !record.Enabled || record.State != "monitoring" || record.Generation != 7 ||
				session.humanInputRevision != 0 || session.rotationHumanInputSeen {
				t.Fatalf("terminal focus report impersonated human input: controlled=%v guarded=%v record=%+v revision=%d seen=%v",
					controlled, guarded, record, session.humanInputRevision, session.rotationHumanInputSeen)
			}
			if session.inputSequences[client] != 1 {
				t.Fatal("focus report was not acknowledged")
			}
			if controlled && guarded {
				if err := session.acknowledgedInput(client, 2, []byte("a")); err == nil {
					t.Fatal("human input bypassed the rotation guard")
				}
				if session.inputSequences[client] != 1 {
					t.Fatal("blocked human input was acknowledged")
				}
				session.rotationGuardInstalled = false
			}
			if err := session.acknowledgedInput(client, 2, []byte("a")); err != nil {
				t.Fatal(err)
			}
			record = session.hostRotation.snapshot()
			if record.Enabled || record.State != "human_takeover" || record.Generation != 8 || session.humanInputRevision != 1 {
				t.Fatalf("real human input failed to pause enrollment exactly once: %+v revision=%d", record, session.humanInputRevision)
			}
			if err := session.pty.Close(); err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(reader)
			if err != nil || !bytes.Equal(got, []byte("\x1b[I\x1b[Oa")) {
				t.Fatalf("focus reports or human input were lost or replayed: %q %v", got, err)
			}
		}
	}
}

func TestTerminalFocusReportExceptionDoesNotHideKeysPastesOrMixedInput(t *testing.T) {
	for _, data := range [][]byte{[]byte("a"), []byte("\x1b[A"), []byte("\x1b[Ia"),
		[]byte("\x1b[O\x1b[Ia"), []byte("\x1b[O\x1b["), []byte("\x1b[I\x1b[A"),
		[]byte("\x1b[200~\x1b[I\x1b[201~"), []byte("\x1b"), []byte("[I")} {
		for _, acknowledged := range []bool{false, true} {
			session, reader := focusInputFixture(t)
			var err error
			if acknowledged {
				err = session.acknowledgedInput([16]byte{1}, 1, data)
			} else {
				err = session.input(data)
			}
			if err != nil {
				t.Fatal(err)
			}
			record := session.hostRotation.snapshot()
			if record.Enabled || record.State != "human_takeover" || session.humanInputRevision != 1 {
				t.Fatalf("ordinary input hidden as a focus report: %q %+v", data, record)
			}
			session.pty.Close()
			got, err := io.ReadAll(reader)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("ordinary input changed: %q -> %q %v", data, got, err)
			}
		}
	}
}

// A detached transport accumulates reports and flushes its backlog in one frame.
func TestTerminalFocusReportsCoalescedDuringReconnectPreserveEnrollment(t *testing.T) {
	for _, data := range [][]byte{[]byte("\x1b[O\x1b[I"), []byte("\x1b[I\x1b[I\x1b[O")} {
		for _, acknowledged := range []bool{false, true} {
			for _, controlled := range []bool{false, true} {
				for _, guarded := range []bool{false, true} {
					session, reader := focusInputFixture(t)
					session.rotationControlled, session.rotationGuardInstalled = controlled, guarded
					client := [16]byte{2}
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
						t.Fatalf("coalesced reports caused takeover: ack=%v controlled=%v guarded=%v data=%q record=%+v",
							acknowledged, controlled, guarded, data, record)
					}
					if acknowledged && session.inputSequences[client] != 1 {
						t.Fatal("coalesced reports were not acknowledged")
					}
					if err := session.pty.Close(); err != nil {
						t.Fatal(err)
					}
					got, err := io.ReadAll(reader)
					if err != nil || !bytes.Equal(got, data) {
						t.Fatalf("coalesced reports changed or replayed: %q -> %q %v", data, got, err)
					}
				}
			}
		}
	}
}
