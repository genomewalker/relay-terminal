package loopbackproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
	"golang.org/x/net/websocket"
)

type wireAnswer struct {
	RequestID string `json:"request_id"`
	Result    Result `json:"result"`
	Error     string `json:"error"`
}
type wireFixture struct {
	connection net.Conn
	writer     *protocol.Writer
	reader     *protocol.FragmentReader
	mu         sync.Mutex
	pending    map[string]chan wireAnswer
	count      atomic.Uint64
	done       chan struct{}
}

func newWireFixture(t *testing.T) *wireFixture {
	t.Helper()
	client, front := net.Pipe()
	upstream, supervisor := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = RelayNode(ctx, front, front, upstream) }()
	go func() {
		writer := protocol.NewWriter(supervisor)
		ready, _ := protocol.JSONFrame(protocol.Status, map[string]any{"state": "ready", "capabilities": []string{"host_rpc_v1"}})
		if writer.Write(ready) != nil {
			return
		}
		for {
			frame, err := protocol.ReadFrame(supervisor)
			if err != nil {
				return
			}
			if frame.Type != protocol.Ping {
				return
			}
			if writer.Write(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload}) != nil {
				return
			}
		}
	}()
	f := &wireFixture{connection: client, writer: protocol.NewScheduledWriter(client), reader: protocol.NewFragmentReader(client), pending: make(map[string]chan wireAnswer), done: make(chan struct{})}
	client.SetDeadline(time.Now().Add(15 * time.Second))
	if ready, err := f.reader.Read(); err != nil || ready.Type != protocol.Status {
		t.Fatal("wire fixture ready:", err)
	}
	if err := f.writer.Write(protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"wire_fragments":true}`)}); err != nil {
		t.Fatal(err)
	}
	f.writer.EnableFragments()
	f.reader.Enabled = true
	go func() {
		defer close(f.done)
		for {
			frame, err := f.reader.Read()
			if err != nil {
				return
			}
			if frame.Type != protocol.HostResponse {
				continue
			}
			var answer wireAnswer
			if json.Unmarshal(frame.Payload, &answer) != nil {
				return
			}
			f.mu.Lock()
			waiting := f.pending[answer.RequestID]
			delete(f.pending, answer.RequestID)
			f.mu.Unlock()
			if waiting != nil {
				waiting <- answer
			}
		}
	}()
	t.Cleanup(func() {
		cancel()
		client.Close()
		supervisor.Close()
		select {
		case <-f.done:
		case <-time.After(time.Second):
			t.Error("native response reader retained")
		}
	})
	return f
}
func (f *wireFixture) call(r Request) (Result, error) {
	r.RequestID = "wire-" + strconv.FormatUint(f.count.Add(1), 10)
	waiting := make(chan wireAnswer, 1)
	f.mu.Lock()
	f.pending[r.RequestID] = waiting
	f.mu.Unlock()
	raw, _ := json.Marshal(r)
	if err := f.writer.Write(protocol.Frame{Type: protocol.HostRequest, Payload: raw}); err != nil {
		return Result{}, err
	}
	select {
	case answer := <-waiting:
		if answer.Error != "" {
			return answer.Result, errors.New(answer.Error)
		}
		return answer.Result, nil
	case <-time.After(5 * time.Second):
		return Result{}, errors.New("native fixture request timed out")
	}
}

type wireByteStream struct {
	wire             *wireFixture
	scope, id        string
	readMu, writeMu  sync.Mutex
	pending          []byte
	offset, sequence int64
}

func newWireByteStream(t *testing.T, f *wireFixture, port int) *wireByteStream {
	t.Helper()
	caps, err := f.call(Request{Operation: "loopback_caps"})
	if err != nil {
		t.Fatal(err)
	}
	stream := &wireByteStream{wire: f, scope: caps.ScopeID, id: "socket-" + strconv.FormatUint(f.count.Add(1), 10)}
	opened, err := f.call(Request{Operation: "loopback_open", ScopeID: stream.scope, ProxyID: stream.id, Port: port})
	if err != nil || opened.State != "open" {
		t.Fatal("native stream open:", err)
	}
	t.Cleanup(func() { stream.Close() })
	return stream
}
func (s *wireByteStream) Read(out []byte) (int, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()
	for len(s.pending) == 0 {
		result, err := s.wire.call(Request{Operation: "loopback_read", ScopeID: s.scope, ProxyID: s.id, Offset: s.offset, WaitMillis: 1000})
		if err != nil {
			return 0, err
		}
		if result.NextOffset != s.offset+int64(len(result.Data)) {
			return 0, errors.New("native offset changed")
		}
		s.offset = result.NextOffset
		s.pending = result.Data
		if result.EOF {
			return 0, io.EOF
		}
	}
	count := copy(out, s.pending)
	s.pending = s.pending[count:]
	return count, nil
}
func (s *wireByteStream) Write(data []byte) (int, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	written := 0
	for written < len(data) {
		count := len(data) - written
		if count > ChunkBytes {
			count = ChunkBytes
		}
		s.sequence++
		result, err := s.wire.call(Request{Operation: "loopback_write", ScopeID: s.scope, ProxyID: s.id, Sequence: s.sequence, Data: data[written : written+count]})
		if err != nil {
			return written, err
		}
		if result.Sequence != s.sequence {
			return written, errors.New("native sequence changed")
		}
		written += count
	}
	return written, nil
}
func (s *wireByteStream) Close() error {
	_, err := s.wire.call(Request{Operation: "loopback_close", ScopeID: s.scope, ProxyID: s.id})
	return err
}
func (s *wireByteStream) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}
}
func (s *wireByteStream) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 2}
}
func (s *wireByteStream) SetDeadline(time.Time) error      { return nil }
func (s *wireByteStream) SetReadDeadline(time.Time) error  { return nil }
func (s *wireByteStream) SetWriteDeadline(time.Time) error { return nil }

func TestNativeWireHTTPImageBytesAndWebSocket(t *testing.T) {
	png := append([]byte{137, 80, 78, 71, 13, 10, 26, 10}, bytes.Repeat([]byte("render"), 512<<10)...)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/socket" {
			websocket.Handler(func(ws *websocket.Conn) {
				defer ws.Close()
				var payload []byte
				if websocket.Message.Receive(ws, &payload) == nil {
					websocket.Message.Send(ws, payload)
				}
			}).ServeHTTP(w, r)
			return
		}
		if r.Header.Get("X-HTTPGD-TOKEN") != "wire-secret" {
			w.WriteHeader(401)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Content-Length", strconv.Itoa(len(png)))
		w.Write(png)
	}))
	defer server.Close()
	wire := newWireFixture(t)
	httpStream := newWireByteStream(t, wire, serverPort(t, server))
	if _, err := httpStream.Write([]byte("GET /plot HTTP/1.1\r\nHost: localhost\r\nX-HTTPGD-TOKEN: wire-secret\r\nConnection: close\r\n\r\n")); err != nil {
		t.Fatal(err)
	}
	bytesOut, err := io.ReadAll(httpStream)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(bytesOut, png) || bytes.Contains(bytesOut, []byte("wire-secret")) {
		t.Fatal("native wire changed image or exposed header")
	}
	socketStream := newWireByteStream(t, wire, serverPort(t, server))
	config, err := websocket.NewConfig("ws://127.0.0.1:"+strconv.Itoa(serverPort(t, server))+"/socket", "http://127.0.0.1/")
	if err != nil {
		t.Fatal(err)
	}
	ws, err := websocket.NewClient(config, socketStream)
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte{0, 255, 1, 127}, 32<<10)
	if err := websocket.Message.Send(ws, payload); err != nil {
		t.Fatal(err)
	}
	var echoed []byte
	if err := websocket.Message.Receive(ws, &echoed); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(echoed, payload) {
		t.Fatal("native wire changed WebSocket bytes")
	}
	ws.Close()
}
func TestManagerStreamCapacityAndDisconnectCleanup(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("fixture")) }))
	defer server.Close()
	m := NewManager(context.Background())
	scope := managerScope(t, m)
	for i := 0; i < MaxStreams; i++ {
		if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: "capacity-" + strconv.Itoa(i), Port: serverPort(t, server)}); err != "" {
			t.Fatal(err)
		}
	}
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: "overflow", Port: serverPort(t, server)}); err == "" {
		t.Fatal("stream capacity exceeded")
	}
	m.Close()
	m.mu.Lock()
	count := len(m.active)
	m.mu.Unlock()
	if count != 0 {
		t.Fatal("disconnect retained streams")
	}
}
