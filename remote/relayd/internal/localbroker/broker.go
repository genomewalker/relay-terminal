// Package localbroker retains a node stream independently of the GUI.
// Pane routes are viewer incarnations; durable worker IDs remain untouched.
package localbroker

import (
	"fmt"
	"github.com/relay-terminal/relayd/internal/protocol"
	"io"
	"net"
	"sync"
	"time"
)

type viewer struct {
	conn    net.Conn
	writer  *protocol.Writer
	frames  chan protocol.Frame
	routes  map[string]string
	reverse map[string]string
	bytes   int
	closed  bool
	stop    chan struct{}
}

type Broker struct {
	mu     sync.Mutex
	remote *protocol.Writer
	ready  protocol.Frame
	viewer *viewer
	epoch  uint64
}

func New(remote io.Writer, ready protocol.Frame) *Broker {
	// The caller negotiates the retained remote stream before constructing us.
	writer := protocol.NewScheduledWriter(remote)
	var status protocol.StatusPayload
	if protocol.DecodeJSON(ready, &status) == nil {
		for _, capability := range status.Capabilities {
			if capability == "wire_fragments_v1" {
				writer.EnableFragments()
				break
			}
		}
	}
	return &Broker{remote: writer, ready: ready}
}

// RemoteFrame never blocks the shared reader behind a slow GUI. Overflow closes
// that viewer explicitly; the durable worker is the replay source, not this queue.
func (b *Broker) RemoteFrame(frame protocol.Frame) {
	if frame.Type == protocol.Ping {
		_ = b.remote.Write(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload})
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	v := b.viewer
	if v == nil || v.closed {
		return
	}
	if frame.Type == protocol.HostEvent {
		route, inner, err := protocol.ParseHostEvent(frame)
		if err != nil {
			return
		}
		original, ok := v.reverse[route]
		if !ok {
			return
		} // stale incarnation cannot reach the current viewer
		frame = protocol.HostEventFrame(original, inner)
	}
	size := len(frame.Payload) + 5
	if v.bytes > 0 && v.bytes+size > 8<<20 {
		b.closeLocked(v)
		return
	}
	select {
	case v.frames <- frame:
		v.bytes += size
	default:
		b.closeLocked(v)
	}
}

func (b *Broker) closeLocked(v *viewer) {
	if v.closed {
		return
	}
	v.closed = true
	close(v.stop)
	_ = v.conn.Close()
	if b.viewer == v {
		b.viewer = nil
	}
	// Detach only viewer routes, never terminate a worker. Route IDs are unique
	// across clients, so a delayed detach cannot detach the replacement.
	routes := make([]string, 0, len(v.routes))
	for _, route := range v.routes {
		routes = append(routes, route)
	}
	go func() {
		for _, route := range routes {
			_ = b.remote.Write(protocol.HostEventFrame(route, protocol.Frame{Type: protocol.Detach}))
		}
	}()
}

func (b *Broker) Ping(payload []byte) error {
	return b.remote.Write(protocol.Frame{Type: protocol.Ping, Payload: payload})
}

func (b *Broker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.viewer != nil {
		b.closeLocked(b.viewer)
	}
}

func (b *Broker) Serve(conn net.Conn) error {
	b.mu.Lock()
	if b.viewer != nil {
		b.mu.Unlock()
		_ = conn.Close()
		return fmt.Errorf("broker already has an active viewer")
	}
	b.epoch++
	epoch := b.epoch
	v := &viewer{conn: conn, writer: protocol.NewScheduledWriter(conn), frames: make(chan protocol.Frame, 16), routes: map[string]string{}, reverse: map[string]string{}, stop: make(chan struct{})}
	b.viewer = v
	b.mu.Unlock()
	defer func() { b.mu.Lock(); b.closeLocked(v); b.mu.Unlock() }()
	go func() {
		writer := v.writer
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if writer.Write(b.ready) != nil {
			_ = conn.Close()
			return
		}
		for {
			select {
			case frame := <-v.frames:
				_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if writer.Write(frame) != nil {
					_ = conn.Close()
					return
				}
				b.mu.Lock()
				v.bytes -= len(frame.Payload) + 5
				b.mu.Unlock()
			case <-v.stop:
				return
			}
		}
	}()
	// The reader owns client lifetime. Input is forwarded once; the broker never
	// replays an uncertain write. Relay's existing input acknowledgments apply.
	reader := protocol.NewFragmentReader(conn)
	for {
		frame, err := reader.Read()
		if err != nil {
			return err
		}
		if frame.Type == protocol.Capabilities {
			var negotiation struct {
				WireFragments bool `json:"wire_fragments"`
			}
			var status protocol.StatusPayload
			if protocol.DecodeJSON(frame, &negotiation) != nil || !negotiation.WireFragments ||
				protocol.DecodeJSON(b.ready, &status) != nil {
				return fmt.Errorf("invalid viewer fragment negotiation")
			}
			supported := false
			for _, capability := range status.Capabilities {
				if capability == "wire_fragments_v1" {
					supported = true
				}
			}
			if !supported {
				return fmt.Errorf("viewer fragments unsupported")
			}
			reader.Enabled = true
			v.writer.EnableFragments()
			continue
		}
		if frame.Type == protocol.HostEvent {
			original, inner, err := protocol.ParseHostEvent(frame)
			if err != nil {
				return err
			}
			b.mu.Lock()
			route := v.routes[original]
			if route == "" {
				route = fmt.Sprintf("b%d_%d", epoch, len(v.routes)+1)
				v.routes[original] = route
				v.reverse[route] = original
			}
			b.mu.Unlock()
			frame = protocol.HostEventFrame(route, inner)
		}
		if err := b.remote.Write(frame); err != nil {
			return err
		}
	}
}
