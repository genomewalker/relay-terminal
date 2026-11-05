package nativemsg

import (
	"context"
	"errors"
	"io"
	"net"
	"runtime"
	"time"
)

// pySocket is a Python AF_UNIX stream socket after settimeout: every recv
// and every sendall has its own timeout. The run's context bounds them all,
// as the adapter process was killed at its deadline.
type pySocket struct {
	ctx     context.Context
	conn    *net.UnixConn
	timeout time.Duration
}

func (s *pySocket) deadline() time.Time {
	deadline := time.Now().Add(s.timeout)
	if limit, ok := s.ctx.Deadline(); ok && limit.Before(deadline) {
		return limit
	}
	return deadline
}

func sunPathLimit() int {
	if runtime.GOOS == "linux" {
		return 108
	}
	return 104
}

// dialUnix is socket.socket(AF_UNIX); settimeout(timeout); connect(path).
func dialUnix(ctx context.Context, path string, timeout time.Duration) (*pySocket, error) {
	if err := nulError(path); err != nil {
		return nil, err
	}
	if len(path) > sunPathLimit() {
		return nil, &pyErr{class: classOS, msg: "AF_UNIX path too long"}
	}
	if err := ctx.Err(); err != nil {
		return nil, &pyErr{class: classTimeout, msg: "timed out"}
	}
	s := &pySocket{ctx: ctx, timeout: timeout}
	dialer := net.Dialer{Deadline: s.deadline()}
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, fromOS(err)
	}
	s.conn = conn.(*net.UnixConn)
	return s, nil
}

func (s *pySocket) close() { s.conn.Close() }

// recv is socket.recv(n): an empty result means the peer closed.
func (s *pySocket) recv(n int) ([]byte, error) {
	if err := s.conn.SetReadDeadline(s.deadline()); err != nil {
		return nil, fromOS(err)
	}
	buffer := make([]byte, n)
	got, err := s.conn.Read(buffer)
	if got > 0 {
		return buffer[:got], nil
	}
	if err != nil && !isEOF(err) {
		return nil, fromOS(err)
	}
	return nil, nil
}

func (s *pySocket) sendall(data []byte) error {
	if s.ctx.Err() != nil {
		return &pyErr{class: classTimeout, msg: "timed out"}
	}
	if err := s.conn.SetWriteDeadline(s.deadline()); err != nil {
		return fromOS(err)
	}
	_, err := s.conn.Write(data)
	return fromOS(err)
}

func isEOF(err error) bool { return errors.Is(err, io.EOF) }
