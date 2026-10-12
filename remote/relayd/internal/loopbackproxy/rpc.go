package loopbackproxy

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const MaxStreams = 32
const BufferBytes = 256 << 10
const ChunkBytes = 64 << 10
const closedHistory = 256

var rpcID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,96}$`)

type Request struct {
	RequestID  string `json:"request_id"`
	Operation  string `json:"operation"`
	ScopeID    string `json:"scope_id"`
	ProxyID    string `json:"proxy_id"`
	Port       int    `json:"port"`
	Data       []byte `json:"data"`
	Sequence   int64  `json:"sequence"`
	CloseInput bool   `json:"close_input"`
	Offset     int64  `json:"offset"`
	WaitMillis int    `json:"wait_millis"`
}
type Result struct {
	ScopeID    string `json:"scope_id"`
	ProxyID    string `json:"proxy_id,omitempty"`
	State      string `json:"state"`
	Sequence   int64  `json:"sequence,omitempty"`
	Data       []byte `json:"data"`
	NextOffset int64  `json:"next_offset"`
	EOF        bool   `json:"eof"`
}
type writeReceipt struct {
	hash [32]byte
	err  string
}
type stream struct {
	mu                       sync.Mutex
	writeMu                  sync.Mutex
	readMu                   sync.Mutex
	ready                    chan struct{}
	changed                  chan struct{}
	conn                     net.Conn
	port                     int
	scope, id                string
	buffer                   []byte
	base                     int64
	eof, closed, inputClosed bool
	failure                  string
	sequence                 int64
	writes                   map[int64]writeReceipt
	idleTimer                *time.Timer
	idleTimeout              time.Duration
	lastAccess               time.Time
	expiring                 bool
}
type Manager struct {
	mu          sync.Mutex
	ctx         context.Context
	cancel      context.CancelFunc
	scope       string
	active      map[string]*stream
	retired     map[string]bool
	closed      bool
	idleTimeout time.Duration
}

func NewManager(ctx context.Context) *Manager { return newManager(ctx, time.Minute) }

// Shorter durations are used only by deterministic lifecycle tests.
func newManager(ctx context.Context, idleTimeout time.Duration) *Manager {
	ctx, cancel := context.WithCancel(ctx)
	m := &Manager{ctx: ctx, cancel: cancel, scope: nonce(), active: make(map[string]*stream), retired: make(map[string]bool), idleTimeout: idleTimeout}
	go func() { <-ctx.Done(); m.Close() }()
	return m
}
func nonce() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic("secure loopback scope unavailable")
	}
	return hex.EncodeToString(value[:])
}
func streamKey(scope, id string) string { return scope + ":" + id }
func (s *stream) notifyLocked()         { close(s.changed); s.changed = make(chan struct{}) }
func (s *stream) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	if s.idleTimer != nil {
		s.idleTimer.Stop()
	}
	conn := s.conn
	s.notifyLocked()
	s.mu.Unlock()
	if conn != nil {
		conn.Close()
	}
}

// Reads wait at most 15 seconds; a healthy watcher refreshes well inside the
// one-minute idle lease. Only client RPC activity renews it: unread upstream
// traffic must not keep an abandoned UI's connection alive.
func (s *stream) touchLease() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.expiring {
		return false
	}
	s.lastAccess = time.Now()
	if s.idleTimer != nil {
		s.idleTimer.Reset(s.idleTimeout)
	}
	return true
}

func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	remaining := m.active
	m.active = make(map[string]*stream)
	m.mu.Unlock()
	m.cancel()
	for _, s := range remaining {
		s.close()
	}
}
func (m *Manager) retire(key string, expected *stream) {
	m.mu.Lock()
	if m.active[key] != expected {
		m.mu.Unlock()
		return
	}
	delete(m.active, key)
	// Rotating the admission namespace bounds tombstones. Old closed IDs cannot
	// reopen after rotation; still-active old-scope streams remain addressable.
	if expected.scope == m.scope {
		if len(m.retired) >= closedHistory {
			m.scope = nonce()
			m.retired = make(map[string]bool)
		}
		if expected.scope == m.scope {
			m.retired[key] = true
		}
	}
	m.mu.Unlock()
	expected.close()
}
func (m *Manager) Handle(payload []byte) (bool, []byte) {
	var head struct {
		RequestID string `json:"request_id"`
		Operation string `json:"operation"`
	}
	if json.Unmarshal(payload, &head) != nil || !strings.HasPrefix(head.Operation, "loopback_") {
		return false, nil
	}
	var result any
	var err error
	var r Request
	if len(payload) > 128<<10 || !rpcID.MatchString(head.RequestID) || json.Unmarshal(payload, &r) != nil {
		err = errors.New("invalid bounded loopback request")
	} else {
		result, err = m.request(r)
	}
	response := map[string]any{"request_id": head.RequestID, "result": result}
	if err != nil {
		response["error"] = err.Error()
	}
	raw, _ := json.Marshal(response)
	return true, raw
}
func (m *Manager) request(r Request) (any, error) {
	if r.Operation == "loopback_caps" {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.closed {
			return nil, errors.New("loopback node closed")
		}
		return map[string]any{"scope_id": m.scope, "state": "ready", "chunk_bytes": ChunkBytes, "buffer_bytes": BufferBytes, "max_streams": MaxStreams,
			"idle_timeout_millis": m.idleTimeout.Milliseconds(), "active_streams": len(m.active), "retired_streams": len(m.retired)}, nil
	}
	if !rpcID.MatchString(r.ProxyID) {
		return nil, errors.New("valid loopback proxy identity required")
	}
	key := streamKey(r.ScopeID, r.ProxyID)
	if r.Operation == "loopback_open" {
		return m.open(r, key)
	}
	m.mu.Lock()
	s := m.active[key]
	m.mu.Unlock()
	if r.Operation == "loopback_close" {
		// Closing before an open goroutine reserves the lease must prevent its
		// later admission too. This tombstone is bounded by namespace rotation.
		if s == nil {
			m.mu.Lock()
			if r.ScopeID == m.scope {
				if len(m.retired) >= closedHistory {
					m.scope = nonce()
					m.retired = make(map[string]bool)
				}
				if r.ScopeID == m.scope {
					m.retired[key] = true
				}
			}
			m.mu.Unlock()
		} else {
			m.retire(key, s)
		}
		return Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "closed"}, nil
	}
	if s == nil {
		return nil, errors.New("loopback stream unavailable; do not replay input")
	}
	select {
	case <-s.ready:
	case <-m.ctx.Done():
		return nil, errors.New("loopback node closed")
	}
	switch r.Operation {
	case "loopback_write":
		if !s.touchLease() {
			return nil, errors.New("loopback lease expired; do not replay input")
		}
		return s.write(r)
	case "loopback_read":
		if !s.touchLease() {
			return nil, errors.New("loopback lease expired; do not replay input")
		}
		result, err := s.read(m.ctx, r)
		if result.EOF {
			m.retire(key, s)
		}
		return result, err
	default:
		return nil, errors.New("unsupported loopback operation")
	}
}
func (m *Manager) open(r Request, key string) (any, error) {
	if r.Port < 1 || r.Port > 65535 {
		return nil, errors.New("invalid host loopback port")
	}
	m.mu.Lock()
	if m.closed || r.ScopeID != m.scope || m.retired[key] {
		m.mu.Unlock()
		return nil, errors.New("loopback admission scope changed or lease closed")
	}
	if existing := m.active[key]; existing != nil {
		if existing.port != r.Port {
			m.mu.Unlock()
			return nil, errors.New("loopback identity conflicts with existing port")
		}
		m.mu.Unlock()
		select {
		case <-existing.ready:
		case <-m.ctx.Done():
			return nil, errors.New("loopback node closed")
		}
		existing.mu.Lock()
		defer existing.mu.Unlock()
		if existing.closed || existing.expiring || existing.conn == nil {
			return nil, errors.New("loopback open failed")
		}
		existing.lastAccess = time.Now()
		if existing.idleTimer != nil {
			existing.idleTimer.Reset(existing.idleTimeout)
		}
		return Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "open"}, nil
	}
	if len(m.active) >= MaxStreams {
		m.mu.Unlock()
		return nil, errors.New("loopback stream capacity reached")
	}
	s := &stream{port: r.Port, scope: r.ScopeID, id: r.ProxyID, ready: make(chan struct{}), changed: make(chan struct{}), buffer: make([]byte, 0, BufferBytes), writes: make(map[int64]writeReceipt)}
	m.active[key] = s
	m.mu.Unlock()
	connection, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(m.ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(r.Port)))
	s.mu.Lock()
	if err != nil || s.closed || m.ctx.Err() != nil {
		if connection != nil {
			connection.Close()
		}
		close(s.ready)
		s.mu.Unlock()
		m.retire(key, s)
		return nil, errors.New("host loopback connection unavailable")
	}
	s.conn = connection
	s.idleTimeout = m.idleTimeout
	s.lastAccess = time.Now()
	s.idleTimer = time.AfterFunc(s.idleTimeout, func() {
		s.mu.Lock()
		if s.closed || s.expiring {
			s.mu.Unlock()
			return
		}
		remaining := s.idleTimeout - time.Since(s.lastAccess)
		if remaining > 0 {
			s.idleTimer.Reset(remaining)
			s.mu.Unlock()
			return
		}
		// Prevent a concurrent request from reviving an expired lease before
		// retirement takes the manager lock and closes only this socket.
		s.expiring = true
		s.mu.Unlock()
		m.retire(key, s)
	})
	close(s.ready)
	s.mu.Unlock()
	go s.pump(m.ctx)
	return Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "open"}, nil
}
func (s *stream) pump(ctx context.Context) {
	scratch := make([]byte, 16<<10)
	for {
		n, err := s.conn.Read(scratch)
		if n > 0 {
			for {
				s.mu.Lock()
				if s.closed {
					s.mu.Unlock()
					return
				}
				if len(s.buffer)+n <= BufferBytes {
					s.buffer = append(s.buffer, scratch[:n]...)
					s.notifyLocked()
					s.mu.Unlock()
					break
				}
				changed := s.changed
				s.mu.Unlock()
				select {
				case <-changed:
				case <-ctx.Done():
					return
				}
			}
		}
		if err != nil {
			s.mu.Lock()
			s.eof = true
			if err != io.EOF && !s.closed {
				s.failure = "host loopback stream ended unexpectedly"
			}
			s.notifyLocked()
			s.mu.Unlock()
			return
		}
	}
}
func (s *stream) write(r Request) (any, error) {
	if len(r.Data) > ChunkBytes || r.Sequence < 1 {
		return nil, errors.New("bounded loopback data and positive sequence required")
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	hashed := make([]byte, len(r.Data)+1)
	copy(hashed, r.Data)
	if r.CloseInput {
		hashed[len(r.Data)] = 1
	}
	hash := sha256.Sum256(hashed)
	s.mu.Lock()
	if prior, ok := s.writes[r.Sequence]; ok {
		s.mu.Unlock()
		if prior.hash != hash {
			return nil, errors.New("loopback sequence conflicts with existing input")
		}
		if prior.err != "" {
			return nil, errors.New(prior.err)
		}
		return Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "open", Sequence: r.Sequence}, nil
	}
	if s.closed || s.inputClosed || r.Sequence != s.sequence+1 {
		s.mu.Unlock()
		return nil, errors.New("loopback input gap or closed stream")
	}
	s.sequence = r.Sequence
	s.writes[r.Sequence] = writeReceipt{hash: hash}
	delete(s.writes, r.Sequence-256)

	if r.CloseInput {
		s.inputClosed = true
	}
	connection := s.conn
	s.mu.Unlock()
	connection.SetWriteDeadline(time.Now().Add(15 * time.Second))
	written, err := connection.Write(r.Data)
	if err == nil && written != len(r.Data) {
		err = io.ErrShortWrite
	}
	if err == nil && r.CloseInput {
		if tcp, ok := connection.(*net.TCPConn); ok {
			err = tcp.CloseWrite()
		}
	}
	if err != nil {
		s.mu.Lock()
		s.writes[r.Sequence] = writeReceipt{hash: hash, err: "loopback input outcome unknown; do not replay"}
		s.mu.Unlock()
		s.close()
		return nil, errors.New("loopback input outcome unknown; do not replay")
	}
	return Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "open", Sequence: r.Sequence}, nil
}
func (s *stream) read(ctx context.Context, r Request) (Result, error) {
	result := Result{ScopeID: r.ScopeID, ProxyID: r.ProxyID, State: "open", Data: []byte{}, NextOffset: r.Offset}
	if r.Offset < 0 || r.WaitMillis < 0 || r.WaitMillis > 15000 {
		return result, errors.New("invalid loopback read bounds")
	}
	s.readMu.Lock()
	defer s.readMu.Unlock()
	timer := time.NewTimer(time.Duration(r.WaitMillis) * time.Millisecond)
	defer timer.Stop()
	for {
		s.mu.Lock()
		if r.Offset < s.base || r.Offset > s.base+int64(len(s.buffer)) {
			s.mu.Unlock()
			return result, errors.New("loopback read offset changed")
		}
		acknowledged := int(r.Offset - s.base)
		if acknowledged > 0 {
			copy(s.buffer, s.buffer[acknowledged:])
			s.buffer = s.buffer[:len(s.buffer)-acknowledged]
			s.base = r.Offset
			s.notifyLocked()
		}
		if len(s.buffer) > 0 {
			count := len(s.buffer)
			if count > ChunkBytes {
				count = ChunkBytes
			}
			result.Data = append(result.Data, s.buffer[:count]...)
			result.NextOffset = r.Offset + int64(count)
			s.mu.Unlock()
			return result, nil
		}
		if s.closed || s.eof {
			result.EOF = true
			failure := s.failure
			s.mu.Unlock()
			if failure != "" {
				return result, errors.New(failure)
			}
			return result, nil
		}
		changed := s.changed
		s.mu.Unlock()
		if r.WaitMillis == 0 {
			return result, nil
		}
		select {
		case <-changed:
		case <-timer.C:
			return result, nil
		case <-ctx.Done():
			return result, fmt.Errorf("loopback node closed")
		}
	}
}
