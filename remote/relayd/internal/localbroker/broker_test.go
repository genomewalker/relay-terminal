package localbroker

import (
	"bytes"
	"fmt"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"strings"
	"sync"
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
	v := &viewer{conn: conn, frames: make(chan protocol.Frame, viewerQueueFrames), routes: map[string]string{}, reverse: map[string]string{"route": "pane"}, stop: make(chan struct{})}
	b.viewer = v
	var reasons []string
	Logf = func(format string, args ...any) { reasons = append(reasons, fmt.Sprintf(format, args...)) }
	defer func() { Logf = func(string, ...any) {} }()
	payload := bytes.Repeat([]byte("x"), 20<<20)
	b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: payload}))
	b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: payload}))
	if !v.closed || b.viewer != nil {
		t.Fatal("overflow was silently dropped")
	}
	if v.bytes > viewerQueueBytes {
		t.Fatal("viewer queue exceeded budget")
	}
	if len(reasons) != 1 || !strings.Contains(reasons[0], "not draining") {
		t.Fatalf("overflow reason not logged: %q", reasons)
	}
}

// A scroll burst on dandy-07 (2026-11-22) was hundreds of small frames while
// the GUI was briefly busy; it must not cut the whole node connection.
func TestBurstOfSmallFramesKeepsTheViewer(t *testing.T) {
	b := New(&bytes.Buffer{}, protocol.Frame{})
	app, conn := net.Pipe()
	defer app.Close()
	v := &viewer{conn: conn, frames: make(chan protocol.Frame, viewerQueueFrames), routes: map[string]string{}, reverse: map[string]string{"route": "pane"}, stop: make(chan struct{})}
	b.viewer = v
	for i := 0; i < 2000; i++ {
		b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: bytes.Repeat([]byte("y"), 512)}))
	}
	if v.closed || b.viewer != v || len(v.frames) != 2000 {
		t.Fatalf("burst closed the viewer: closed=%v queued=%d", v.closed, len(v.frames))
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

// A GUI that stops reading for a few seconds (dandy-07, 2026-11-22 20:51:26Z,
// 5 s deadline) must keep its viewer; only a stall past the deadline ends it.
func TestViewerSurvivesStallShorterThanWriteDeadline(t *testing.T) {
	if viewerWriteTimeout < 30*time.Second {
		t.Fatalf("viewer write deadline %v is shorter than 30s", viewerWriteTimeout)
	}
	stall := func(timeout, pause time.Duration) (delivered bool, reasons []string) {
		saved := viewerWriteTimeout
		viewerWriteTimeout = timeout
		defer func() { viewerWriteTimeout = saved }()
		var mu sync.Mutex
		Logf = func(format string, args ...any) {
			mu.Lock()
			reasons = append(reasons, fmt.Sprintf(format, args...))
			mu.Unlock()
		}
		defer func() { Logf = func(string, ...any) {} }()
		b := New(&bytes.Buffer{}, protocol.Frame{Type: protocol.Status})
		app, conn := net.Pipe()
		defer app.Close()
		done := make(chan struct{})
		go func() { _ = b.Serve(conn); close(done) }()
		if _, err := protocol.ReadFrame(app); err != nil {
			t.Fatal(err)
		}
		b.mu.Lock()
		b.viewer.reverse["route"] = "pane"
		b.mu.Unlock()
		b.RemoteFrame(protocol.HostEventFrame("route", protocol.Frame{Type: protocol.Output, Payload: []byte("after-stall")}))
		time.Sleep(pause) // the GUI is not reading
		_ = app.SetReadDeadline(time.Now().Add(time.Second))
		frame, err := protocol.ReadFrame(app)
		if err == nil {
			_, inner, _ := protocol.ParseHostEvent(frame)
			delivered = string(inner.Payload) == "after-stall"
		}
		if delivered {
			b.mu.Lock()
			alive := b.viewer != nil && !b.viewer.closed
			b.mu.Unlock()
			if !alive {
				t.Fatal("viewer closed although the frame was delivered")
			}
		} else {
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("timed-out viewer did not end")
			}
		}
		mu.Lock()
		got := append([]string(nil), reasons...)
		mu.Unlock()
		_ = app.Close()
		<-done // let this viewer finish logging before the next run
		return delivered, got
	}
	if delivered, reasons := stall(800*time.Millisecond, 300*time.Millisecond); !delivered || len(reasons) != 0 {
		t.Fatalf("short stall dropped the viewer: delivered=%v reasons=%q", delivered, reasons)
	}
	delivered, reasons := stall(200*time.Millisecond, 600*time.Millisecond)
	if delivered || !strings.Contains(strings.Join(reasons, "\n"), "writing to viewer 1 failed") {
		t.Fatalf("stall past the deadline was not reported: delivered=%v reasons=%q", delivered, reasons)
	}
}
