package protocol

import (
	"bytes"
	"io"
	"sync"
	"testing"
	"time"
)

func TestFragmentsReassembleAndPassControlBetweenChunks(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), FragmentChunkBytes+7)
	var stream bytes.Buffer
	w := NewWriter(&stream)
	w.Write(FragmentFrame(1, HostResponse, len(payload), 0, payload[:FragmentChunkBytes]))
	w.Write(Frame{Type: Pong, Payload: []byte("pulse")})
	w.Write(FragmentFrame(1, HostResponse, len(payload), FragmentChunkBytes, payload[FragmentChunkBytes:]))
	r := NewFragmentReader(&stream)
	r.Enabled = true
	first, err := r.Read()
	if err != nil || first.Type != Pong {
		t.Fatal(first, err)
	}
	result, err := r.Read()
	if err != nil || result.Type != HostResponse || !bytes.Equal(result.Payload, payload) {
		t.Fatal("logical message mismatch", err)
	}
}
func TestFragmentsRejectUnnegotiatedAndBadOffsets(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		var stream bytes.Buffer
		NewWriter(&stream).Write(FragmentFrame(1, Output, 5, 1, []byte("bad")))
		r := NewFragmentReader(&stream)
		r.Enabled = enabled
		if _, err := r.Read(); err == nil {
			t.Fatal("invalid fragment accepted")
		}
	}
}
func TestSchedulerPreservesPerRouteOrder(t *testing.T) {
	a := &scheduledFrame{key: "pane:a", priority: 3}
	laterA := &scheduledFrame{key: "pane:a", priority: 0}
	b := &scheduledFrame{key: "pane:b", priority: 1}
	s := frameScheduler{pending: []*scheduledFrame{a, laterA, b}}
	if s.choose() != 2 {
		t.Fatal("later same-route control overtook output")
	}
	s.burst = 8
	if s.choose() != 0 {
		t.Fatal("oldest frame starved")
	}
}

type gatedDestination struct {
	bytes.Buffer
	count   int
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (g *gatedDestination) Write(data []byte) (int, error) {
	n, e := g.Buffer.Write(data)
	g.count++
	if g.count == 2 {
		g.once.Do(func() { close(g.entered) })
		<-g.release
	}
	return n, e
}
func TestScheduledFragmentsAllowHeartbeatDuringLargeTransfer(t *testing.T) {
	g := &gatedDestination{entered: make(chan struct{}), release: make(chan struct{})}
	w := NewScheduledWriter(g)
	w.EnableFragments()
	done := make(chan error, 1)
	payload := bytes.Repeat([]byte("z"), FragmentChunkBytes*3)
	go func() { done <- w.Write(Frame{Type: HostResponse, Payload: payload}) }()
	select {
	case <-g.entered:
	case <-time.After(time.Second):
		t.Fatal("writer did not start")
	}
	pulse := &scheduledFrame{frame: Frame{Type: Pong, Payload: []byte("heartbeat")}, key: "heartbeat", priority: 0, done: make(chan error, 1)}
	w.scheduler.mu.Lock()
	w.scheduler.pending = append(w.scheduler.pending, pulse)
	w.scheduler.bytes += len(pulse.frame.Payload)
	w.scheduler.mu.Unlock()
	close(g.release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("writer stalled")
	}
	r := NewFragmentReader(bytes.NewReader(g.Bytes()))
	r.Enabled = true
	first, e := r.Read()
	if e != nil || first.Type != Pong {
		t.Fatal("heartbeat did not pass partial bulk message", e)
	}
	bulk, e := r.Read()
	if e != nil || !bytes.Equal(bulk.Payload, payload) {
		t.Fatal("bulk message corrupted", e)
	}
	if _, e = r.Read(); e != io.EOF {
		t.Fatal(e)
	}
}
