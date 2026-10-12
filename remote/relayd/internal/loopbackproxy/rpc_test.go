package loopbackproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func managerRequest(t *testing.T, m *Manager, r Request) (Result, string) {
	t.Helper()
	if r.RequestID == "" {
		r.RequestID = "fixture-request"
	}
	payload, _ := json.Marshal(r)
	handled, raw := m.Handle(payload)
	if !handled {
		t.Fatal("loopback request forwarded")
	}
	var answer struct {
		Result Result `json:"result"`
		Error  string `json:"error"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil {
		t.Fatal(err)
	}
	return answer.Result, answer.Error
}
func managerScope(t *testing.T, m *Manager) string {
	result, err := managerRequest(t, m, Request{Operation: "loopback_caps"})
	if err != "" {
		t.Fatal(err)
	}
	return result.ScopeID
}
func TestManagerHTTPBoundedBufferAndSequencedInput(t *testing.T) {
	payload := bytes.Repeat([]byte("native-render"), 256<<10)
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("X-HTTPGD-TOKEN") != "fixture-secret" {
			t.Error("header changed")
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.Write(payload)
	}))
	defer server.Close()
	m := NewManager(context.Background())
	defer m.Close()
	scope := managerScope(t, m)
	id := "fixture-stream"
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: id, Port: serverPort(t, server)}); err != "" {
		t.Fatal(err)
	}
	request := []byte("GET /plot HTTP/1.1\r\nHost: localhost\r\nX-HTTPGD-TOKEN: fixture-secret\r\nConnection: close\r\n\r\n")
	write := Request{Operation: "loopback_write", ScopeID: scope, ProxyID: id, Sequence: 1, Data: request, CloseInput: true}
	if _, err := managerRequest(t, m, write); err != "" {
		t.Fatal(err)
	}
	if _, err := managerRequest(t, m, write); err != "" {
		t.Fatal("exact input replay failed:", err)
	}
	bad := write
	bad.Data = []byte("conflict")
	if _, err := managerRequest(t, m, bad); err == "" {
		t.Fatal("conflicting input accepted")
	}
	var output []byte
	var offset int64
	for {
		chunk, err := managerRequest(t, m, Request{Operation: "loopback_read", ScopeID: scope, ProxyID: id, Offset: offset, WaitMillis: 15000})
		if err != "" {
			t.Fatal(err)
		}
		if len(chunk.Data) > ChunkBytes {
			t.Fatal("unbounded chunk")
		}
		output = append(output, chunk.Data...)
		offset = chunk.NextOffset
		if chunk.EOF {
			break
		}
		m.mu.Lock()
		s := m.active[streamKey(scope, id)]
		m.mu.Unlock()
		if s != nil {
			s.mu.Lock()
			bounded := len(s.buffer) <= BufferBytes && cap(s.buffer) == BufferBytes
			s.mu.Unlock()
			if !bounded {
				t.Fatal("unbounded retained buffer")
			}
		}
	}
	if !bytes.HasSuffix(output, payload) {
		t.Fatal("large render truncated")
	}
	if bytes.Contains(output, []byte("fixture-secret")) {
		t.Fatal("request token leaked to output")
	}
	if calls.Load() != 1 {
		t.Fatal("input replay reached upstream twice")
	}
	m.mu.Lock()
	remaining := len(m.active)
	m.mu.Unlock()
	if remaining != 0 {
		t.Fatal("EOF lease retained")
	}
}
func TestManagerCloseBeforeOpenCannotAdmitLateLease(t *testing.T) {
	m := NewManager(context.Background())
	defer m.Close()
	scope := managerScope(t, m)
	_, err := managerRequest(t, m, Request{Operation: "loopback_close", ScopeID: scope, ProxyID: "late"})
	if err != "" {
		t.Fatal(err)
	}
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: "late", Port: 1}); err == "" {
		t.Fatal("closed lease reopened")
	}
}
func TestManagerScopeRotationBoundsTombstonesAndKeepsActiveStreams(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("kept")) }))
	defer server.Close()
	m := NewManager(context.Background())
	defer m.Close()
	old := managerScope(t, m)
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: old, ProxyID: "kept", Port: serverPort(t, server)}); err != "" {
		t.Fatal(err)
	}
	for i := 0; i <= closedHistory; i++ {
		scope := managerScope(t, m)
		id := fmt.Sprintf("closed-%d", i)
		if _, err := managerRequest(t, m, Request{Operation: "loopback_close", ScopeID: scope, ProxyID: id}); err != "" {
			t.Fatal(err)
		}
	}
	current := managerScope(t, m)
	if current == old {
		t.Fatal("admission namespace did not rotate")
	}
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: old, ProxyID: "closed-0", Port: serverPort(t, server)}); err == "" {
		t.Fatal("old closed namespace reopened")
	}
	if _, err := managerRequest(t, m, Request{Operation: "loopback_write", ScopeID: old, ProxyID: "kept", Sequence: 1, Data: []byte("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"), CloseInput: true}); err != "" {
		t.Fatal("active old scope was revoked:", err)
	}
	if _, err := managerRequest(t, m, Request{Operation: "loopback_read", ScopeID: old, ProxyID: "kept", WaitMillis: 15000}); err != "" {
		t.Fatal(err)
	}
	m.mu.Lock()
	retired := len(m.retired)
	m.mu.Unlock()
	if retired > closedHistory {
		t.Fatal("tombstones grew without bound")
	}
}
func TestManagerRejectsBoundsAndLeavesOtherRPCUntouched(t *testing.T) {
	m := NewManager(context.Background())
	defer m.Close()
	scope := managerScope(t, m)
	if handled, _ := m.Handle([]byte(`{"request_id":"file-1","operation":"file_stat","path":"/fixture"}`)); handled {
		t.Fatal("ordinary host operation intercepted")
	}
	for _, port := range []int{0, 65536} {
		if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: "bad", Port: port}); err == "" {
			t.Fatal("invalid port accepted")
		}
	}
}

func TestManagerWrittenAndUnclaimedLeasesExpire(t *testing.T) {
	for _, written := range []bool{false, true} {
		t.Run(fmt.Sprintf("written-%t", written), func(t *testing.T) {
			server, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			accepted := make(chan net.Conn, 1)
			go func() {
				conn, err := server.Accept()
				if err == nil {
					accepted <- conn
				}
			}()
			m := newManager(context.Background(), 200*time.Millisecond)
			defer m.Close()
			scope := managerScope(t, m)
			id := "expired-stream"
			if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: id, Port: server.Addr().(*net.TCPAddr).Port}); err != "" {
				t.Fatal(err)
			}
			conn := <-accepted
			defer conn.Close()
			if written {
				if _, err := managerRequest(t, m, Request{Operation: "loopback_write", ScopeID: scope, ProxyID: id, Sequence: 1, Data: []byte("x")}); err != "" {
					t.Fatal(err)
				}
				if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
					t.Fatal(err)
				}
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			if n, err := conn.Read(make([]byte, 1)); n != 0 || err != io.EOF {
				t.Fatalf("abandoned socket survived: %d %v", n, err)
			}
			m.mu.Lock()
			active := len(m.active)
			m.mu.Unlock()
			if active != 0 {
				t.Fatal("expired lease retained its admission slot")
			}
			if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: id, Port: server.Addr().(*net.TCPAddr).Port}); err == "" {
				t.Fatal("expired identity reopened")
			}
		})
	}
}

func TestManagerActiveEmptyReadsRenewWrittenLease(t *testing.T) {
	server, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := server.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	m := newManager(context.Background(), 500*time.Millisecond)
	defer m.Close()
	scope := managerScope(t, m)
	id := "active-stream"
	if _, err := managerRequest(t, m, Request{Operation: "loopback_open", ScopeID: scope, ProxyID: id, Port: server.Addr().(*net.TCPAddr).Port}); err != "" {
		t.Fatal(err)
	}
	conn := <-accepted
	defer conn.Close()
	if _, err := managerRequest(t, m, Request{Operation: "loopback_write", ScopeID: scope, ProxyID: id, Sequence: 1, Data: []byte("x")}); err != "" {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
		t.Fatal(err)
	}
	// More than two initial lease periods pass while the watcher receives no
	// messages. Its outstanding reads, not upstream traffic, keep it alive.
	for i := 0; i < 6; i++ {
		result, err := managerRequest(t, m, Request{Operation: "loopback_read", ScopeID: scope, ProxyID: id, WaitMillis: 200})
		if err != "" || result.EOF {
			t.Fatalf("healthy idle watcher expired: %v %s", result.EOF, err)
		}
	}
	m.mu.Lock()
	active := len(m.active)
	m.mu.Unlock()
	if active != 1 {
		t.Fatal("active watcher lost its lease")
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if n, err := conn.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("abandoned watcher did not expire: %d %v", n, err)
	}
}
