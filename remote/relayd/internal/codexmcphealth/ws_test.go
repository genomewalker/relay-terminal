package codexmcphealth

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, bad bool, serve func(net.Conn) error) string {
	t.Helper()
	dir, e := os.MkdirTemp("/tmp", "health-ws-")
	if e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(dir, "s")
	l, e := net.Listen("unix", path)
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() {
		c, e := l.Accept()
		if e != nil {
			done <- e
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(3 * time.Second))
		r := bufio.NewReader(c)
		key := ""
		for {
			line, e := r.ReadString('\n')
			if e != nil {
				done <- e
				return
			}
			if line == "\r\n" {
				break
			}
			if strings.HasPrefix(line, "Sec-WebSocket-Key:") {
				key = strings.TrimSpace(strings.TrimPrefix(line, "Sec-WebSocket-Key:"))
			}
		}
		digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		accept := base64.StdEncoding.EncodeToString(digest[:])
		if bad {
			accept = "wrong"
		}
		_, e = fmt.Fprintf(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		if e == nil && !bad {
			e = serve(c)
		}
		done <- e
	}()
	t.Cleanup(func() {
		defer os.RemoveAll(dir)
		defer l.Close()
		select {
		case e := <-done:
			if e != nil {
				t.Error(e)
			}
		case <-time.After(4 * time.Second):
			t.Error("fixture worker did not finish")
		}
	})
	return path
}
func readClient(c net.Conn) (byte, []byte, error) {
	var h [2]byte
	if _, e := io.ReadFull(c, h[:]); e != nil {
		return 0, nil, e
	}
	if h[1]&128 == 0 {
		return 0, nil, fmt.Errorf("unmasked client request")
	}
	n := int(h[1] & 127)
	if n >= 126 {
		return 0, nil, fmt.Errorf("unexpected fixture request size")
	}
	var mask [4]byte
	if _, e := io.ReadFull(c, mask[:]); e != nil {
		return 0, nil, e
	}
	data := make([]byte, n)
	if _, e := io.ReadFull(c, data); e != nil {
		return 0, nil, e
	}
	for i := range data {
		data[i] ^= mask[i%4]
	}
	return h[0] & 15, data, nil
}
func TestMaskedRequestFragmentedResponseAndPing(t *testing.T) {
	path := fixture(t, false, func(c net.Conn) error {
		op, data, e := readClient(c)
		if e != nil {
			return e
		}
		var req map[string]any
		if e = json.Unmarshal(data, &req); e != nil {
			return e
		}
		if op != 1 || req["method"] != "inspect" {
			return fmt.Errorf("wrong request %d %v", op, req)
		}
		if _, e = c.Write([]byte{0x89, 1, 'p'}); e != nil {
			return e
		}
		op, data, e = readClient(c)
		if e != nil {
			return e
		}
		if op != 10 || string(data) != "p" {
			return fmt.Errorf("ping not answered")
		}
		response, _ := json.Marshal(map[string]any{"id": req["id"], "result": map[string]any{"healthy": true}})
		frame := append([]byte{1, 5}, response[:5]...)
		frame = append(frame, 128, byte(len(response)-5))
		frame = append(frame, response[5:]...)
		_, e = c.Write(frame)
		return e
	})
	c, e := Dial(context.Background(), path)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	v, e := c.Call("inspect", map[string]any{})
	if e != nil || v["healthy"] != true {
		t.Fatalf("fragmented RPC: %v %v", v, e)
	}
}
func TestRejectsIncorrectHandshake(t *testing.T) {
	c, e := Dial(context.Background(), fixture(t, true, nil))
	if e == nil {
		c.Close()
		t.Fatal("incorrect handshake accepted")
	}
}
func TestRejectsMaskedServerFrame(t *testing.T) {
	c, e := Dial(context.Background(), fixture(t, false, func(c net.Conn) error { _, e := c.Write([]byte{0x81, 0x80}); return e }))
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	if _, e = c.Receive(); e == nil {
		t.Fatal("masked server accepted")
	}
}

type memConn struct {
	*bytes.Reader
	out bytes.Buffer
}

func (m *memConn) Write(p []byte) (int, error)    { return m.out.Write(p) }
func (*memConn) Close() error                     { return nil }
func (*memConn) LocalAddr() net.Addr              { return nil }
func (*memConn) RemoteAddr() net.Addr             { return nil }
func (*memConn) SetDeadline(time.Time) error      { return nil }
func (*memConn) SetReadDeadline(time.Time) error  { return nil }
func (*memConn) SetWriteDeadline(time.Time) error { return nil }
func memoryConnection(raw []byte) *Connection {
	m := &memConn{Reader: bytes.NewReader(raw)}
	return &Connection{sock: m, reader: bufio.NewReader(m)}
}
func serverFrame(data []byte) []byte {
	h := []byte{0x81}
	if len(data) < 126 {
		h = append(h, byte(len(data)))
	} else if len(data) < 65536 {
		h = append(h, 126, byte(len(data)>>8), byte(len(data)))
	} else {
		h = append(h, 127)
		h = binary.BigEndian.AppendUint64(h, uint64(len(data)))
	}
	return append(h, data...)
}
func TestWebSocketBounds(t *testing.T) {
	for _, raw := range [][]byte{{0x81, 127, 0, 0, 0, 0, 0, 0x10, 0, 1}, {0x09, 0}, {0x89, 126, 0, 126}, {0x80, 0}, {0x82, 0}, bytes.Repeat([]byte{0x8a, 0}, 512)} {
		if _, e := memoryConnection(raw).Receive(); e == nil {
			t.Fatalf("invalid framing accepted: %x", raw[:2])
		}
	}
	if e := memoryConnection(nil).Send(make([]byte, Limit+1), 1); e == nil {
		t.Fatal("oversized request accepted")
	}
	notes := bytes.Repeat(serverFrame([]byte(`{"method":"notice"}`)), 256)
	if _, e := memoryConnection(notes).Call("inspect", map[string]any{}); e == nil || !strings.Contains(e.Error(), "too many notifications") {
		t.Fatal("notification bound bypassed")
	}
}
func FuzzWebSocketFrames(f *testing.F) {
	f.Add([]byte(`{"result":{"ok":true}}`))
	f.Add([]byte{})
	f.Add([]byte{0x81, 0x80})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		_, _ = memoryConnection(data).Receive()
		payload, _ := json.Marshal(map[string]any{"data": base64.StdEncoding.EncodeToString(data)})
		frame := serverFrame(payload)
		value, e := memoryConnection(frame).Receive()
		if e != nil || value["data"] != base64.StdEncoding.EncodeToString(data) {
			t.Fatal("frame roundtrip failed")
		}
		if _, e = memoryConnection(frame[:len(frame)-1]).Receive(); e == nil {
			t.Fatal("truncated frame accepted")
		}
		masked := append([]byte(nil), frame...)
		masked[1] |= 128
		if _, e = memoryConnection(masked).Receive(); e == nil {
			t.Fatal("masked server frame admitted")
		}
	})
}

func TestProtocolLimitReasons(t *testing.T) {
	raw := []byte{0x81, 127, 0, 0, 0, 0, 0, 0x10, 0, 1}
	if _, e := memoryConnection(raw).Receive(); e == nil || !strings.Contains(e.Error(), "response exceeds limit") {
		t.Fatal("frame allocation limit not checked before allocation", e)
	}
	if _, e := memoryConnection(bytes.Repeat([]byte{0x8a, 0}, 512)).Receive(); e == nil || !strings.Contains(e.Error(), "too many websocket frames") {
		t.Fatal("frame count bound changed", e)
	}
	c := memoryConnection(bytes.Repeat([]byte{'x'}, 16385))
	if e := c.handshake(); e == nil || !strings.Contains(e.Error(), "invalid websocket handshake") {
		t.Fatal("handshake bound changed", e)
	}
	for _, payload := range [][]byte{[]byte(`{"id":2,"result":{}}`), []byte(`{"id":1,"error":{"code":-1},"result":{}}`)} {
		if _, e := memoryConnection(serverFrame(payload)).Call("inspect", map[string]any{}); e == nil {
			t.Fatal("RPC identity or error gate bypassed")
		}
	}
	if _, e := memoryConnection(serverFrame([]byte{'{', '"', 'x', '"', ':', '"', 255, '"', '}'})).Receive(); e == nil {
		t.Fatal("invalid UTF8 accepted")
	}
}
