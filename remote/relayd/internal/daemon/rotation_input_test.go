package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func guardedFixture(t *testing.T) (*Session, *os.File, uint64) {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close(); _ = writer.Close() })
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{pty: writer, process: &exec.Cmd{Process: &os.Process{Pid: os.Getpid()}},
		rotationControlled: true, rotationGuardDirectory: filepath.Join(t.TempDir(), "guard")}
	return session, reader, start
}

func TestGuardedInputClaimsBeforeWriteAndNeverReplays(t *testing.T) {
	session, reader, start := guardedFixture(t)
	if err := session.guardedRotationInput("receipt-intent-1", os.Getpid(), start+1, "receipt"); err == nil {
		t.Fatal("wrong process incarnation accepted")
	}
	if err := session.guardedRotationInput("receipt-intent-1", os.Getpid(), start, "receipt"); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, len("receipt\r"))
	if _, err := reader.Read(buffer); err != nil || string(buffer) != "receipt\r" {
		t.Fatalf("first guarded write: %q, %v", buffer, err)
	}
	if err := session.guardedRotationInput("receipt-intent-1", os.Getpid(), start, "receipt"); err == nil {
		t.Fatal("same operation replayed")
	}
	if err := session.input([]byte("human")); err == nil {
		t.Fatal("ordinary input bypassed rotation lease")
	}
	if err := session.acknowledgedInput([16]byte{1}, 1, []byte("retry")); err == nil {
		t.Fatal("reconnecting acknowledged input bypassed rotation lease")
	}
	// A new worker instance reading the same durable marker also refuses it.
	recovered := &Session{pty: session.pty, process: session.process, rotationControlled: true,
		rotationGuardDirectory: session.rotationGuardDirectory}
	if err := recovered.guardedRotationInput("receipt-intent-1", os.Getpid(), start, "receipt"); err == nil {
		t.Fatal("worker restart replayed guarded input")
	}
}

func TestHumanInputPermanentlyDisqualifiesControlledPane(t *testing.T) {
	session, _, start := guardedFixture(t)
	if err := session.input([]byte("user typing")); err != nil {
		t.Fatal(err)
	}
	if err := session.guardedRotationInput("exit-intent-2", os.Getpid(), start, "/exit"); err == nil {
		t.Fatal("rotation overwrote human input")
	}
	if _, err := os.Stat(filepath.Join(session.rotationGuardDirectory, "x")); err == nil {
		t.Fatal("unexpected guarded write marker")
	}
}

func TestFailedGuardedWritePermanentlyRequiresReconciliation(t *testing.T) {
	session, reader, start := guardedFixture(t)
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if err := session.guardedRotationInput("receipt-failed", os.Getpid(), start, "receipt"); err == nil {
		t.Fatal("closed PTY reader accepted guarded write")
	}
	if _, err := os.Stat(filepath.Join(session.rotationGuardDirectory, "outcome-unknown")); err != nil {
		t.Fatal("failed write lost durable unknown-outcome marker", err)
	}
	newReader, newWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = newReader.Close(); _ = newWriter.Close() })
	session.pty = newWriter
	if err := session.guardedRotationInput("exit-after-failure", os.Getpid(), start, "/exit"); err == nil {
		t.Fatal("second write bypassed unknown first outcome")
	}
}

func TestClaimedRotationPaneCannotStartOrdinaryWorker(t *testing.T) {
	server := NewServer()
	server.stateDir = t.TempDir()
	id := ClaudeRotationID("intent-test: pane")
	directory := filepath.Join(server.stateDir, "rotation-launches")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, id+".json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := server.ensureWorker(protocol.HelloPayload{SessionID: id, Command: "echo forbidden"}); err == nil {
		t.Fatal("ordinary attach launched a claimed rotation pane")
	}
}
