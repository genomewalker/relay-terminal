package daemon

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// A supervisor started by a one-off client on a node without panes exits
// after the idle time; a pane worker, a client or a running host job keeps it.
func TestIdleSupervisorExitsOnlyWithoutWorkersClientsOrJobs(t *testing.T) {
	previousAfter, previousEvery := daemonIdleExitAfter, daemonIdleCheckEvery
	daemonIdleExitAfter, daemonIdleCheckEvery = 150*time.Millisecond, 10*time.Millisecond
	t.Cleanup(func() { daemonIdleExitAfter, daemonIdleCheckEvery = previousAfter, previousEvery })
	t.Setenv("RELAY_DAEMON_IDLE_EXIT", "")

	run := func(t *testing.T, s *Server, wait time.Duration) bool {
		t.Helper()
		directory, err := os.MkdirTemp("/tmp", "ri")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(directory)
		listener, err := net.Listen("unix", filepath.Join(directory, "s.sock"))
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		ctx, cancel := context.WithTimeout(context.Background(), wait)
		defer cancel()
		var exiting atomic.Bool
		s.watchIdle(ctx, listener, &exiting)
		return exiting.Load()
	}

	s := &Server{runtimeDir: t.TempDir()}
	worker := filepath.Join(s.runtimeDir, "0123456789abcdef0123.sock")
	if err := os.WriteFile(worker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if run(t, s, 500*time.Millisecond) {
		t.Fatal("exited with a pane worker")
	}
	if err := os.Remove(worker); err != nil {
		t.Fatal(err)
	}

	s.clients.Add(1)
	if run(t, s, 500*time.Millisecond) {
		t.Fatal("exited with a client connected")
	}
	s.clients.Add(-1)

	job := &hostJob{record: hostJobRecord{JobID: "job-running", State: "running"}}
	s.hostJobs.Store("job-running", job)
	if run(t, s, 500*time.Millisecond) {
		t.Fatal("exited with a running host job")
	}
	job.record.State = "exited"

	if !run(t, s, 2*time.Second) {
		t.Fatal("an idle supervisor did not exit")
	}
	if reason := s.busyReason(); reason != "" {
		t.Fatalf("idle supervisor reported busy: %s", reason)
	}

	t.Setenv("RELAY_DAEMON_IDLE_EXIT", "0")
	if run(t, s, 500*time.Millisecond) {
		t.Fatal("exited although RELAY_DAEMON_IDLE_EXIT=0")
	}
}

// Serve returns nil after the idle exit, so `relayd daemon` ends normally and
// removes its socket.
func TestServeEndsCleanlyAfterIdleExit(t *testing.T) {
	previousAfter, previousEvery := daemonIdleExitAfter, daemonIdleCheckEvery
	daemonIdleExitAfter, daemonIdleCheckEvery = 200*time.Millisecond, 20*time.Millisecond
	t.Cleanup(func() { daemonIdleExitAfter, daemonIdleCheckEvery = previousAfter, previousEvery })
	t.Setenv("RELAY_DAEMON_IDLE_EXIT", "")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp("/tmp", "rid")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	t.Setenv("XDG_STATE_HOME", filepath.Join(directory, "state"))
	server := NewServer()
	server.executable = executable
	socket := filepath.Join(directory, "d.sock")
	done := make(chan error, 1)
	go func() { done <- server.Serve(socket) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Serve after idle exit: %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("idle supervisor did not exit")
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket left behind: %v", err)
	}
}
