package daemon

import (
	"context"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"
)

// Run only inside the private child selected by the focused regression.
func TestPHWaitCommandChild(t *testing.T) {
	mode := os.Getenv("RELAY_TEST_PH_WAIT_CHILD")
	if mode == "" {
		return
	}
	if err := os.Stdout.Close(); err != nil {
		os.Exit(91)
	}
	if mode == "exit" {
		os.Exit(0)
	}
	// A long-lived direct child, with no descendants or process-group signals.
	// Production cancellation or the test cleanup must reap it before this.
	time.Sleep(30 * time.Second)
	os.Exit(92)
}

func phEOFChild(t *testing.T, mode string) *exec.Cmd {
	t.Helper()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(binary, "-test.run=^TestPHWaitCommandChild$")
	command.Env = append(os.Environ(), "RELAY_TEST_PH_WAIT_CHILD="+mode)
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if command.ProcessState == nil {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	})
	drained := make(chan error, 1)
	go func() { _, err := io.Copy(io.Discard, output); drained <- err }()
	select {
	case err := <-drained:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("private child did not close stdout")
	}
	// Reaching here proves real EOF before the cancellation below: no sleep
	// or production-only test hook guesses which read/wait phase is active.
	return command
}

func TestPHWaitCommandCancellationAfterEOF(t *testing.T) {
	command := phEOFChild(t, "hold")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	began := time.Now()
	raised := phRaised(t, func() { newPHReader(ctx).waitCommand(command, 2*time.Second) })
	elapsed := time.Since(began)
	if raised == nil || raised.kind != phTimeout || raised.msg != "Command cancelled" {
		t.Fatalf("PH_WAIT_EOF_CANCELLATION: expected cancellation, got %+v", raised)
	}
	if elapsed >= time.Second {
		t.Fatalf("PH_WAIT_EOF_CANCELLATION: cancellation waited %s for local timeout", elapsed)
	}
	if command.ProcessState == nil {
		t.Fatal("PH_WAIT_EOF_CANCELLATION: direct child was not reaped")
	}
	if command.ProcessState.Success() {
		t.Fatal("PH_WAIT_EOF_CANCELLATION: canceled child reported success")
	}
}

func TestPHWaitCommandCompletedChildCancellation(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		command := phEOFChild(t, "exit")
		ctx, cancel := context.WithCancel(context.Background())
		if canceled {
			cancel()
		}
		raised := phRaised(t, func() { newPHReader(ctx).waitCommand(command, 2*time.Second) })
		cancel()
		if canceled {
			if raised == nil || raised.kind != phTimeout || raised.msg != "Command cancelled" {
				t.Fatalf("PH_WAIT_COMPLETION_CANCELLATION: canceled completion admitted: %+v", raised)
			}
		} else if raised != nil || command.ProcessState == nil || !command.ProcessState.Success() {
			t.Fatalf("PH_WAIT_COMPLETION_CANCELLATION: uncanceled completion changed: %+v", raised)
		}
	}
}
