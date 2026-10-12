// Package loopbackproxy relays one private host-loopback TCP connection over
// an owned Relay host job's stdin/stdout. It never opens a remote transport,
// exposes a listening socket, reads credentials, or touches a terminal.
package loopbackproxy

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"time"
)

// Serve preserves the byte stream, including HTTP upgrades and WebSocket
// frames. Relay's existing job protocol owns sequencing, bounded output,
// cancellation and offset-based reads; httpgd's client owns token/body guards.
func Serve(ctx context.Context, port int, input io.Reader, output io.Writer) error {
	if port < 1 || port > 65535 {
		return errors.New("invalid loopback port")
	}
	if input == nil || output == nil {
		return errors.New("loopback streams required")
	}
	dialer := net.Dialer{Timeout: 8 * time.Second}
	connection, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		// Keep endpoint credentials and upstream content out of diagnostics.
		return errors.New("host loopback connection unavailable")
	}
	defer connection.Close()
	stopped := make(chan struct{})
	defer close(stopped)
	go func() {
		select {
		case <-ctx.Done():
			connection.Close()
		case <-stopped:
		}
	}()
	// This process owns stdin. Close it when the upstream finishes so a copy
	// goroutine cannot outlive a detached proxy lease.
	if closer, ok := input.(io.Closer); ok {
		defer closer.Close()
	}
	go func() {
		_, writeErr := io.CopyBuffer(connection, input, make([]byte, 64<<10))
		if writeErr != nil {
			connection.Close()
			return
		}
		// HTTP callers may half-close their request and still need the whole
		// response. Do not close the upstream read side on stdin EOF.
		if tcp, ok := connection.(*net.TCPConn); ok {
			tcp.CloseWrite()
		}
	}()
	_, err = io.CopyBuffer(output, connection, make([]byte, 64<<10))
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return errors.New("host loopback stream ended unexpectedly")
	}
	return nil
}
