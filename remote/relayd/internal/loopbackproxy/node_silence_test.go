package loopbackproxy

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func shortenClientSilence(t *testing.T) {
	t.Helper()
	silence, check := nodeClientSilence, nodeSilenceCheck
	nodeClientSilence, nodeSilenceCheck = 150*time.Millisecond, 20*time.Millisecond
	t.Cleanup(func() { nodeClientSilence, nodeSilenceCheck = silence, check })
}

// startSilenceNode runs a node whose supervisor side discards everything and
// whose client side is never closed: the half-open link a VPN change leaves.
func startSilenceNode(t *testing.T) (net.Conn, <-chan error) {
	t.Helper()
	client, front := net.Pipe()
	upstream, supervisor := net.Pipe()
	t.Cleanup(func() { client.Close(); supervisor.Close() })
	go func() { _, _ = io.Copy(io.Discard, supervisor) }()
	go func() { _, _ = io.Copy(io.Discard, client) }()
	done := make(chan error, 1)
	go func() { done <- RelayNode(context.Background(), front, front, upstream) }()
	return client, done
}

// An app link that died without a FIN kept its relayd node, and the node's
// pane attachments, alive for hours. Every dandy-07 pane then reported two
// viewers and Relay refused to move or restart them.
func TestNodeEndsWhenHeartbeatingClientFallsSilent(t *testing.T) {
	shortenClientSilence(t)
	client, done := startSilenceNode(t)
	if err := protocol.NewWriter(client).Write(protocol.Frame{Type: protocol.Ping, Payload: make([]byte, 8)}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrClientSilent) {
			t.Fatalf("node ended with %v, want ErrClientSilent", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("node kept a silent client's link open")
	}
}

func TestNodeKeepsHeartbeatingClient(t *testing.T) {
	shortenClientSilence(t)
	client, done := startSilenceNode(t)
	writer := protocol.NewWriter(client)
	deadline := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(deadline) {
		if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: make([]byte, 8)}); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-done:
			t.Fatalf("node ended while the client heartbeat: %v", err)
		case <-time.After(40 * time.Millisecond):
		}
	}
}

func TestNodeNeverCutsClientThatDoesNotHeartbeat(t *testing.T) {
	shortenClientSilence(t)
	_, done := startSilenceNode(t)
	select {
	case err := <-done:
		t.Fatalf("node ended a client that never sent a heartbeat: %v", err)
	case <-time.After(500 * time.Millisecond):
	}
}
