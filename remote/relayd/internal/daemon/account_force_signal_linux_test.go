//go:build linux

package daemon

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// This test signals only its own synthetic child; the second child is a
// sentinel proving that the single-PID path does not signal a process group.
func TestForceLinuxSignalsOnlySelectedSyntheticChild(t *testing.T) {
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill() }()
	wait := make(chan error, 1)
	go func() { wait <- child.Wait() }()
	sentinel := exec.Command("sleep", "30")
	if err := sentinel.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sentinel.Process.Kill(); _ = sentinel.Wait() }()
	pid := child.Process.Pid
	p, err := forceLinuxReadProcess("/proc", pid)
	if err != nil {
		t.Fatal(err)
	}
	target := forceAccountTarget{Pane: "synthetic", Provider: "claude", Session: "test", ProviderPID: os.Getpid(),
		ProviderStart: "synthetic", BlockerPID: pid, BlockerStart: p.Start, CommandDigest: forceAccountCommandDigest(p.Argv)}
	fd, err := forceLinuxProcessHandle(pid)
	if err != nil {
		t.Fatal(err)
	}
	if fd >= 0 {
		defer unix.Close(fd)
	}
	calls := 0
	_, _ = (&forceAccountAttempt{}).signalSelected(target, func() (forceAccountObservation, error) {
		o := forceAccountObservation{Target: target}
		current, err := forceLinuxReadProcess("/proc", pid)
		if err != nil {
			if syscall.Kill(pid, 0) == syscall.ESRCH {
				o.Complete = true
				return o, nil
			}
			return o, err
		}
		if current.Parent != os.Getpid() || current.Start != target.BlockerStart || forceAccountCommandDigest(current.Argv) != target.CommandDigest {
			return o, errors.New("synthetic child changed")
		}
		o.Complete, o.Present, o.Descendant, o.CommandMatches = true, true, true, true
		return o, nil
	}, func(selected int) error {
		calls++
		if selected != pid {
			return errors.New("wrong selected PID " + strconv.Itoa(selected))
		}
		return forceLinuxSignal(fd, selected)
	})
	if calls != 1 {
		t.Fatalf("signals sent: %d", calls)
	}
	select {
	case err := <-wait:
		if e, ok := err.(*exec.ExitError); !ok || !e.ProcessState.Sys().(syscall.WaitStatus).Signaled() || e.ProcessState.Sys().(syscall.WaitStatus).Signal() != syscall.SIGTERM {
			t.Fatalf("selected child did not exit on SIGTERM: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("selected child did not exit")
	}
	if err := syscall.Kill(sentinel.Process.Pid, 0); err != nil {
		t.Fatalf("sentinel was affected: %v", err)
	}
}
