package subscriptionquota

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type readSocket struct {
	ctx    context.Context
	conn   net.Conn
	reader *bufio.Reader
	stop   func() bool
}

func (s *readSocket) close() {
	if s.stop != nil {
		s.stop()
	}
	_ = s.conn.Close()
}
func (s *readSocket) deadline(limit time.Time) error {
	if err := s.ctx.Err(); err != nil {
		return err
	}
	when := time.Now().Add(4 * time.Second)
	if !limit.IsZero() && limit.Before(when) {
		when = limit
	}
	if end, ok := s.ctx.Deadline(); ok && end.Before(when) {
		when = end
	}
	return s.conn.SetDeadline(when)
}

func privateSocket(path string, uid uint32) (string, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", nil, errUnavailable
	}
	if info.Mode()&os.ModeSymlink != 0 {
		parent, err := os.Stat(filepath.Dir(path))
		if err != nil || !parent.IsDir() || !owned(info, uid) || !owned(parent, uid) || parent.Mode().Perm()&0077 != 0 {
			return "", nil, errUnavailable
		}
		path, err = filepath.EvalSymlinks(path)
		if err != nil {
			return "", nil, errUnavailable
		}
		info, err = os.Lstat(path)
		if err != nil {
			return "", nil, errUnavailable
		}
	}
	if info.Mode()&os.ModeSocket == 0 || !owned(info, uid) || info.Mode().Perm() != 0600 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return "", nil, errUnavailable
	}
	return path, info, nil
}

func openReadSocket(ctx context.Context, path string, uid uint32) (*readSocket, error) {
	return openReadSocketWithDial(ctx, path, uid, func(ctx context.Context, path string) (net.Conn, error) {
		d := net.Dialer{Timeout: 4 * time.Second}
		return d.DialContext(ctx, "unix", path)
	})
}

func openReadSocketWithDial(ctx context.Context, path string, uid uint32, dial func(context.Context, string) (net.Conn, error)) (*readSocket, error) {
	resolved, before, err := privateSocket(path, uid)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	conn, err := dial(ctx, resolved)
	if err != nil {
		cancel()
		return nil, errUnavailable
	}
	s := &readSocket{ctx: ctx, conn: conn, reader: bufio.NewReaderSize(conn, 8192)}
	s.stop = context.AfterFunc(ctx, func() { _ = conn.Close() })
	// close owns cancellation as well as connection cleanup.
	stop := s.stop
	s.stop = func() bool { cancel(); return stop() }
	refuse := func() (*readSocket, error) { s.close(); return nil, errUnavailable }
	resolvedAfter, after, err := privateSocket(path, uid)
	if err != nil || resolvedAfter != resolved || !sameFile(before, after) {
		return refuse()
	}
	unixConn, ok := conn.(*net.UnixConn)
	if !ok || checkPeer(unixConn, uid) != nil {
		return refuse()
	}
	if err = s.deadline(time.Time{}); err != nil {
		return refuse()
	}
	var nonce [16]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return refuse()
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])
	request := "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
	if _, err = io.WriteString(conn, request); err != nil {
		return refuse()
	}
	if err = readUpgrade(s.reader, key); err != nil {
		return refuse()
	}
	return s, nil
}

func readUpgrade(r *bufio.Reader, key string) error {
	// Read no more than 8192 bytes without consuming any following WS frame.
	header := make([]byte, 0, 256)
	for len(header) < 8192 {
		b, err := r.ReadByte()
		if err != nil {
			return errUnavailable
		}
		header = append(header, b)
		if len(header) >= 4 && string(header[len(header)-4:]) == "\r\n\r\n" {
			break
		}
	}
	return parseUpgrade(header, key)
}

func parseUpgrade(header []byte, key string) error {
	if len(header) > 8192 || !strings.HasSuffix(string(header), "\r\n\r\n") {
		return errUnavailable
	}
	lines := strings.Split(string(header), "\r\n")
	if len(lines) < 3 {
		return errUnavailable
	}
	status := strings.Fields(lines[0])
	if len(status) < 2 || status[0] != "HTTP/1.1" || status[1] != "101" {
		return errUnavailable
	}
	fields := map[string]string{}
	for _, line := range lines[1 : len(lines)-2] {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			return errUnavailable
		}
		key = strings.ToLower(key)
		if _, duplicate := fields[key]; duplicate {
			return errUnavailable
		}
		fields[key] = strings.TrimSpace(value)
	}
	sum := sha1.Sum([]byte(key + websocketGUID))
	if fields["sec-websocket-accept"] != base64.StdEncoding.EncodeToString(sum[:]) {
		return errUnavailable
	}
	return nil
}

func (s *readSocket) send(value any) error {
	data, err := marshal(value)
	if err != nil {
		return err
	}
	return s.sendFrame(1, data)
}
func (s *readSocket) sendFrame(opcode byte, data []byte) error {
	if len(data) > Limit || opcode != 1 && opcode != 10 || opcode == 10 && len(data) > 125 {
		return errUnavailable
	}
	if err := s.deadline(time.Time{}); err != nil {
		return err
	}
	header := []byte{0x80 | opcode}
	if len(data) < 126 {
		header = append(header, 0x80|byte(len(data)))
	} else if len(data) <= 65535 {
		header = append(header, 0x80|126, byte(len(data)>>8), byte(len(data)))
	} else {
		header = append(header, 0x80|127)
		header = binary.BigEndian.AppendUint64(header, uint64(len(data)))
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	frame := append(header, mask[:]...)
	for i, b := range data {
		frame = append(frame, b^mask[i%4])
	}
	for len(frame) > 0 {
		n, err := s.conn.Write(frame)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		frame = frame[n:]
	}
	return nil
}

// readFrame rejects masked/fragmented/server-reserved frames before allocating
// their payload. Valid observations and pings are the only accepted opcodes.
func readFrame(r io.Reader) (byte, []byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, errUnavailable
	}
	if header[0]&0xf0 != 0x80 || header[1]&0x80 != 0 {
		return 0, nil, errUnavailable
	}
	opcode := header[0] & 15
	if opcode != 1 && opcode != 9 {
		return 0, nil, errUnavailable
	}
	length := uint64(header[1] & 127)
	if length == 126 {
		var b [2]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, nil, errUnavailable
		}
		length = uint64(binary.BigEndian.Uint16(b[:]))
	} else if length == 127 {
		var b [8]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, nil, errUnavailable
		}
		length = binary.BigEndian.Uint64(b[:])
	}
	if length > Limit || opcode == 9 && length > 125 {
		return 0, nil, errUnavailable
	}
	data := make([]byte, int(length))
	if _, err := io.ReadFull(r, data); err != nil {
		return 0, nil, errUnavailable
	}
	return opcode, data, nil
}

func (s *readSocket) rpc(ident int, method string, params any) (map[string]any, error) {
	if method != "initialize" && method != "account/rateLimits/read" {
		return nil, errors.New("quota RPC is observation-only")
	}
	if err := s.send(map[string]any{"id": ident, "method": method, "params": params}); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		if err := s.deadline(deadline); err != nil {
			return nil, err
		}
		opcode, data, err := readFrame(s.reader)
		if err != nil {
			return nil, err
		}
		if opcode == 9 {
			if err = s.sendFrame(10, data); err != nil {
				return nil, err
			}
			continue
		}
		reply, err := decodeObject(data, Limit)
		if err != nil {
			return nil, err
		}
		id, numeric := reply["id"].(json.Number)
		matched, numberError := id.Float64()
		if numeric && numberError == nil && matched == float64(ident) {
			if _, failed := reply["error"]; failed {
				return nil, errUnavailable
			}
			if reply["result"] == nil {
				return map[string]any{}, nil
			}
			result := object(reply["result"])
			if result == nil {
				return nil, errUnavailable
			}
			return result, nil
		}
	}
	return nil, errUnavailable
}
