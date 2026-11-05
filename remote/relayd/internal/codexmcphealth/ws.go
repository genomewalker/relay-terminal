package codexmcphealth

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
	"unicode/utf8"
)

const Limit = 1 << 20

// Connection is single-user: one RPC and its notifications are consumed in order.
type Connection struct {
	sock     net.Conn
	reader   *bufio.Reader
	sequence int
}

func Dial(ctx context.Context, path string) (*Connection, error) {
	sock, e := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "unix", path)
	if e != nil {
		return nil, e
	}
	c := &Connection{sock: sock, reader: bufio.NewReader(sock)}
	if e = c.handshake(); e != nil {
		sock.Close()
		return nil, e
	}
	return c, nil
}
func (c *Connection) Close() error { return c.sock.Close() }
func (c *Connection) handshake() error {
	if e := c.sock.SetDeadline(time.Now().Add(10 * time.Second)); e != nil {
		return e
	}
	nonce := make([]byte, 16)
	if _, e := rand.Read(nonce); e != nil {
		return e
	}
	key := base64.StdEncoding.EncodeToString(nonce)
	if _, e := fmt.Fprintf(c.sock, "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n", key); e != nil {
		return e
	}
	raw := make([]byte, 0, 1024)
	for !strings.HasSuffix(string(raw), "\r\n\r\n") {
		if len(raw) >= 16384 {
			return errors.New("invalid websocket handshake")
		}
		b, e := c.reader.ReadByte()
		if e != nil {
			return e
		}
		if b > 127 {
			return errors.New("non-ASCII websocket handshake")
		}
		raw = append(raw, b)
	}
	lines := strings.Split(string(raw), "\r\n")
	status := strings.Fields(lines[0])
	headers := map[string]string{}
	for _, l := range lines[1:] {
		if k, v, ok := strings.Cut(l, ":"); ok {
			headers[strings.ToLower(k)] = strings.TrimSpace(v)
		}
	}
	h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	accept := base64.StdEncoding.EncodeToString(h[:])
	if len(status) < 2 || status[1] != "101" || headers["sec-websocket-accept"] != accept || strings.ToLower(headers["upgrade"]) != "websocket" {
		return errors.New("websocket upgrade rejected")
	}
	return nil
}
func (c *Connection) Send(data []byte, opcode byte) error {
	if len(data) > Limit {
		return errors.New("request exceeds limit")
	}
	mask := make([]byte, 4)
	if _, e := rand.Read(mask); e != nil {
		return e
	}
	frame := []byte{128 | opcode}
	n := len(data)
	switch {
	case n < 126:
		frame = append(frame, 128|byte(n))
	case n < 65536:
		frame = append(frame, 254, byte(n>>8), byte(n))
	default:
		frame = append(frame, 255)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	frame = append(frame, mask...)
	for i, b := range data {
		frame = append(frame, b^mask[i%4])
	}
	for len(frame) > 0 {
		n, e := c.sock.Write(frame)
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		frame = frame[n:]
	}
	return nil
}
func (c *Connection) Receive() (map[string]any, error) {
	message := make([]byte, 0)
	started := false
	for frames := 0; frames < 512; frames++ {
		header := [2]byte{}
		if _, e := io.ReadFull(c.reader, header[:]); e != nil {
			return nil, e
		}
		first, second := header[0], header[1]
		if first&0x70 != 0 || second&128 != 0 {
			return nil, errors.New("unsupported websocket frame")
		}
		op, n := first&15, uint64(second&127)
		if n == 126 {
			var x [2]byte
			if _, e := io.ReadFull(c.reader, x[:]); e != nil {
				return nil, e
			}
			n = uint64(binary.BigEndian.Uint16(x[:]))
		} else if n == 127 {
			var x [8]byte
			if _, e := io.ReadFull(c.reader, x[:]); e != nil {
				return nil, e
			}
			n = binary.BigEndian.Uint64(x[:])
		}
		if n > Limit || uint64(len(message))+n > Limit {
			return nil, errors.New("response exceeds limit")
		}
		data := make([]byte, int(n))
		if _, e := io.ReadFull(c.reader, data); e != nil {
			return nil, e
		}
		if op == 8 || op == 9 || op == 10 {
			if n > 125 || first&128 == 0 {
				return nil, errors.New("invalid control frame")
			}
			if op == 8 {
				return nil, errors.New("control endpoint closed")
			}
			if op == 9 {
				if e := c.Send(data, 10); e != nil {
					return nil, e
				}
			}
			continue
		}
		if !started && op != 1 || started && op != 0 {
			return nil, errors.New("unexpected message frame")
		}
		started = true
		message = append(message, data...)
		if first&128 != 0 {
			if !utf8.Valid(message) {
				return nil, errors.New("invalid UTF-8 message")
			}
			var result map[string]any
			if e := json.Unmarshal(message, &result); e != nil {
				return nil, e
			}
			if result == nil {
				return nil, errors.New("response must be an object")
			}
			return result, nil
		}
	}
	return nil, errors.New("too many websocket frames")
}
func (c *Connection) Call(method string, params any) (map[string]any, error) {
	if e := c.sock.SetDeadline(time.Now().Add(10 * time.Second)); e != nil {
		return nil, e
	}
	c.sequence++
	id := c.sequence
	raw, e := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
	if e != nil {
		return nil, e
	}
	if e = c.Send(raw, 1); e != nil {
		return nil, e
	}
	for n := 0; n < 256; n++ {
		v, e := c.Receive()
		if e != nil {
			return nil, e
		}
		if v["id"] == float64(id) {
			if _, ok := v["error"]; ok {
				return nil, errors.New("control request rejected")
			}
			result, ok := v["result"].(map[string]any)
			if !ok {
				return nil, errors.New("control result must be an object")
			}
			return result, nil
		}
	}
	return nil, errors.New("too many notifications")
}
