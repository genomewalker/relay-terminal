package localbroker

import (
	"bytes"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"testing"
	"time"
)

func TestRoutesIsolateViewerIncarnations(t *testing.T) {
	remote, worker := net.Pipe()
	defer remote.Close()
	defer worker.Close()
	forwarded := make(chan protocol.Frame, 10)
	go func() {
		for {
			frame, err := protocol.ReadFrame(worker)
			if err != nil {
				return
			}
			forwarded <- frame
		}
	}()
	ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready"})
	b := New(remote, ready)
	defer b.Close()
	attach := func() (net.Conn, string) {
		app, broker := net.Pipe()
		_ = app.SetDeadline(time.Now().Add(2 * time.Second))
		go func() { _ = b.Serve(broker) }()
		if _, err := protocol.ReadFrame(app); err != nil {
			t.Fatal(err)
		}
		hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{SessionID: "durable-worker"})
		if err := protocol.NewWriter(app).Write(protocol.HostEventFrame("gui-pane", hello)); err != nil {
			t.Fatal(err)
		}
		for {
			select {
			case frame := <-forwarded:
				route, inner, err := protocol.ParseHostEvent(frame)
				if err != nil {
					t.Fatal(err)
				}
				if inner.Type == protocol.Hello {
					var got protocol.HelloPayload
					_ = protocol.DecodeJSON(inner, &got)
					if got.SessionID != "durable-worker" {
						t.Fatal("worker identity changed")
					}
					return app, route
				}
			case <-time.After(2 * time.Second):
				t.Fatal("missing forwarded hello")
			}
		}
	}
	first, old := attach()
	_ = first.Close()
	select {
	case frame := <-forwarded:
		_, inner, _ := protocol.ParseHostEvent(frame)
		if inner.Type != protocol.Detach {
			t.Fatal("viewer not detached")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("detach timeout")
	}
	second, current := attach()
	defer second.Close()
	if old == current {
		t.Fatal("route incarnation reused")
	}
	b.RemoteFrame(protocol.HostEventFrame(old, protocol.Frame{Type: protocol.Output, Payload: []byte("stale")}))
	b.RemoteFrame(protocol.HostEventFrame(current, protocol.Frame{Type: protocol.Output, Payload: []byte("current")}))
	frame, err := protocol.ReadFrame(second)
	if err != nil {
		t.Fatal(err)
	}
	pane, inner, _ := protocol.ParseHostEvent(frame)
	if pane != "gui-pane" || !bytes.Equal(inner.Payload, []byte("current")) {
		t.Fatal("stale output crossed viewer incarnations")
	}
}
func TestSlowViewerOverflowIsExplicitAndBounded(t *testing.T) {
	b := New(&bytes.Buffer{}, protocol.Frame{})
	app, conn := net.Pipe()
	defer app.Close()
	v := &viewer{conn: conn, frames: make(chan protocol.Frame, 16), routes: map[string]string{}, reverse: map[string]string{"route": "pane"}, stop: make(chan struct{})}
	b.viewer = v
	payload := bytes.Repeat([]byte("x"), 5<<20)
	b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: payload}))
	b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: payload}))
	if !v.closed || b.viewer != nil {
		t.Fatal("overflow was silently dropped")
	}
	if v.bytes > 8<<20 {
		t.Fatal("viewer queue exceeded budget")
	}
}

func TestFragmentedViewerIncarnationsKeepLogicalRoutes(t *testing.T) {
	remote, worker := net.Pipe()
	defer remote.Close()
	defer worker.Close()
	forwarded := make(chan protocol.Frame, 20)
	go func() {
		reader := protocol.NewFragmentReader(worker)
		reader.Enabled = true
		for {
			f, e := reader.Read()
			if e != nil {
				return
			}
			forwarded <- f
		}
	}()
	ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Capabilities: []string{"wire_fragments_v1"}})
	b := New(remote, ready)
	defer b.Close()
	payload := bytes.Repeat([]byte("fragment-route-proof"), 5000)
	var old string
	for generation := 0; generation < 2; generation++ {
		app, conn := net.Pipe()
		app.SetDeadline(time.Now().Add(3 * time.Second))
		done := make(chan error, 1)
		go func() { done <- b.Serve(conn) }()
		if _, e := protocol.ReadFrame(app); e != nil {
			t.Fatal(e)
		}
		writer := protocol.NewWriter(app)
		if e := writer.Write(protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"wire_fragments":true}`)}); e != nil {
			t.Fatal(e)
		}
		logical := protocol.HostEventFrame("pane", protocol.Frame{Type: protocol.Artifact, Payload: payload})
		for offset := 0; offset < len(logical.Payload); offset += protocol.FragmentChunkBytes {
			end := offset + protocol.FragmentChunkBytes
			if end > len(logical.Payload) {
				end = len(logical.Payload)
			}
			if e := writer.Write(protocol.FragmentFrame(1, logical.Type, len(logical.Payload), offset, logical.Payload[offset:end])); e != nil {
				t.Fatal(e)
			}
		}
		var routed protocol.Frame
		select {
		case routed = <-forwarded:
		case <-time.After(3 * time.Second):
			t.Fatal("logical frame missing")
		}
		route, inner, e := protocol.ParseHostEvent(routed)
		if e != nil || route == "pane" || route == old || !bytes.Equal(inner.Payload, payload) {
			t.Fatalf("route/fragment isolation failed: %s %v", route, e)
		}
		old = route
		b.RemoteFrame(protocol.HostEventFrame(route, protocol.Frame{Type: protocol.Artifact, Payload: payload}))
		reader := protocol.NewFragmentReader(app)
		reader.Enabled = true
		received, e := reader.Read()
		if e != nil {
			t.Fatal(e)
		}
		pane, inner, e := protocol.ParseHostEvent(received)
		if e != nil || pane != "pane" || !bytes.Equal(inner.Payload, payload) {
			t.Fatal("fragmented reply did not remap")
		}
		app.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Fatal("viewer did not stop")
		}
		select {
		case f := <-forwarded:
			_, inner, e := protocol.ParseHostEvent(f)
			if e != nil || inner.Type != protocol.Detach {
				t.Fatal("missing scoped detach")
			}
		case <-time.After(3 * time.Second):
			t.Fatal("detach timeout")
		}
	}
}
