package daemon

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

// A client command (node, attach, observe, r-code) starts a supervisor when
// none is running. On a node that hosts no panes, for example one reached by a
// one-off SSH command on a shared home, that supervisor would otherwise stay
// for weeks. It exits once it has had no pane worker, client connection or
// running host job for daemonIdleExitAfter. The next client starts it again.
var (
	daemonIdleExitAfter  = 30 * time.Minute
	daemonIdleCheckEvery = time.Minute
)

// daemonIdleExitSetting reads RELAY_DAEMON_IDLE_EXIT: a Go duration, or 0 to
// keep an idle supervisor running.
func daemonIdleExitSetting() time.Duration {
	text := strings.TrimSpace(os.Getenv("RELAY_DAEMON_IDLE_EXIT"))
	if text == "" {
		return daemonIdleExitAfter
	}
	if text == "0" {
		return 0
	}
	if value, err := time.ParseDuration(text); err == nil && value > 0 {
		return value
	}
	return daemonIdleExitAfter
}

// busyReason names what keeps the supervisor in use, or "" when idle. Anything
// it cannot inspect counts as busy.
func (s *Server) busyReason() string {
	if clients := s.clients.Load(); clients > 0 {
		return fmt.Sprintf("%d client connections", clients)
	}
	// Worker sockets live in the node-local runtime directory; the state
	// directory may be shared with other nodes.
	if s.runtimeDir != "" {
		entries, err := os.ReadDir(s.runtimeDir)
		if err != nil && !os.IsNotExist(err) {
			return "worker directory unreadable"
		}
		workers := 0
		for _, entry := range entries {
			if filepath.Ext(entry.Name()) == ".sock" {
				workers++
			}
		}
		if workers > 0 {
			return fmt.Sprintf("%d pane workers", workers)
		}
	}
	running := 0
	s.hostJobs.Range(func(_, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		if job.record.State == "starting" || job.record.State == "running" {
			running++
		}
		job.mu.Unlock()
		return true
	})
	if running > 0 {
		return fmt.Sprintf("%d running host jobs", running)
	}
	return ""
}

// watchIdle closes the listener, ending Serve, after the supervisor has been
// idle for the configured time.
func (s *Server) watchIdle(ctx context.Context, listener net.Listener, exiting *atomic.Bool) {
	after := daemonIdleExitSetting()
	if after <= 0 {
		return
	}
	ticker := time.NewTicker(daemonIdleCheckEvery)
	defer ticker.Stop()
	idleSince := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if s.busyReason() != "" {
				idleSince = now
				continue
			}
			if now.Sub(idleSince) < after {
				continue
			}
			fmt.Fprintf(os.Stderr, "relay: no pane workers, clients or host jobs for %v; supervisor %d exiting (the next client starts it again)\n", after, os.Getpid())
			exiting.Store(true)
			_ = listener.Close()
			return
		}
	}
}

// waitForClients lets a connection accepted just before the idle exit finish.
func (s *Server) waitForClients(limit time.Duration) {
	deadline := time.Now().Add(limit)
	for s.clients.Load() > 0 && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
}
