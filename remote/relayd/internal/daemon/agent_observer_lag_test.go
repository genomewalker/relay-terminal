package daemon

import (
	"bytes"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// A lagged observer must end its route (so the client can reopen from its
// cursor) and say so in the worker log instead of vanishing silently.
func TestLaggedAgentObserverClosesRouteAndLogs(t *testing.T) {
	var logged lockedBuffer
	previous := agentObserverLog
	agentObserverLog = &logged
	defer func() { agentObserverLog = previous }()

	session := &Session{
		id:      "f36f6368-a919-429d-b9e2-e4396b999f98",
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte),
	}
	server, peer := net.Pipe()
	defer peer.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer server.Close()
		serveAgentObserver(server, protocol.NewWriter(server), session, 0)
	}()
	// Read the attached status, then stop reading so the queue fills.
	if _, err := protocol.ReadFrame(peer); err != nil {
		t.Fatal(err)
	}
	// Publish until the worker drops the stalled observer from its queue set.
	deadline := time.Now().Add(5 * time.Second)
	for i := 0; ; i++ {
		session.mu.Lock()
		observing := len(session.agentClients)
		session.mu.Unlock()
		if observing == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("stalled observer was never marked lagged")
		}
		session.agentEvent([]byte(`{"agent":"codex","event":{"hook_event_name":"PreToolUse","item_id":"` +
			strconv.Itoa(i) + `"}}`))
	}
	// Let the route drain its pending write; it must then close, not wait.
	go func() { _, _ = io.Copy(io.Discard, peer) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("lagged observer route did not close")
	}
	if !strings.Contains(logged.String(), "agent observer for session f36f6368-a919-429d-b9e2-e4396b999f98 fell behind") {
		t.Fatalf("lagged observer closed without a log line: %q", logged.String())
	}
}
