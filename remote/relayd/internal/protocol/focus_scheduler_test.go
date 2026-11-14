package protocol

import (
	"bytes"
	"sync"
	"testing"
	"time"
)

func head(key string, priority int) *scheduledFrame {
	return &scheduledFrame{key: key, priority: priority}
}

// With no focus, the order is exactly the old one: priority, then age.
func TestSchedulerWithoutFocusKeepsTheOldOrder(t *testing.T) {
	s := frameScheduler{pending: []*scheduledFrame{head("pane:a", 1), head("pane:b", 1), head("rpc:x", 3)}}
	if s.choose() != 0 {
		t.Fatal("oldest output did not go first without focus")
	}
}

// The focused pane's output goes before other panes' older output, but input,
// acks and heartbeats of any pane, and the focused pane's own order, still win.
func TestSchedulerSendsTheFocusedPaneFirst(t *testing.T) {
	s := frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:a", 1), head("pane:b", 1)}}
	if s.choose() != 1 {
		t.Fatal("focused output did not overtake another pane's output")
	}
	s = frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:b", 1), head("pane:a", 0)}}
	if got := s.choose(); got != 1 {
		t.Fatalf("an unfocused pane's input waited behind focused output (chose %d)", got)
	}
	s = frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:b", 0), head("heartbeat", 0)}}
	if got := s.choose(); got != 0 {
		t.Fatalf("focused input waited behind a later heartbeat (chose %d)", got)
	}
	s = frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:b", 1), head("heartbeat", 0)}}
	if got := s.choose(); got != 1 {
		t.Fatalf("a heartbeat waited behind focused output (chose %d)", got)
	}
	s = frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:b", 1), head("pane:b", 0), head("pane:a", 1)}}
	if got := s.choose(); got != 0 {
		t.Fatalf("the focused pane's later frame overtook its own head (chose %d)", got)
	}
	// Focused agent events still yield to any pane's output.
	s = frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:b", 2), head("pane:a", 1)}}
	if s.choose() != 1 {
		t.Fatal("focused agent event overtook another pane's output")
	}
}

// The oldest-first pick after eight priority picks still applies with focus.
func TestSchedulerFocusKeepsTheStarvationBound(t *testing.T) {
	s := frameScheduler{focus: map[string]bool{"pane:b": true},
		pending: []*scheduledFrame{head("pane:a", 1), head("pane:b", 1)}}
	s.burst = 8
	if s.choose() != 0 {
		t.Fatal("an unfocused pane starved")
	}
}

type firstWriteGate struct {
	mu      sync.Mutex
	buffer  bytes.Buffer
	writes  int
	entered chan struct{}
	release chan struct{}
}

func (g *firstWriteGate) Write(data []byte) (int, error) {
	g.mu.Lock()
	g.writes++
	first := g.writes == 1
	g.mu.Unlock()
	if first {
		close(g.entered)
		<-g.release
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.buffer.Write(data)
}

// Through a real writer: frames already queued behind a slow link are re-ranked
// when focus changes, and every frame is still delivered once.
func TestFocusChangeReRanksFramesAlreadyQueued(t *testing.T) {
	g := &firstWriteGate{entered: make(chan struct{}), release: make(chan struct{})}
	w := NewScheduledWriter(g)
	output := func(route, text string) Frame {
		return HostEventFrame(route, Frame{Type: Output, Payload: []byte(text)})
	}
	var wg sync.WaitGroup
	send := func(frame Frame) {
		wg.Add(1)
		go func() { defer wg.Done(); _ = w.Write(frame) }()
	}
	send(output("pane-x", "x"))
	<-g.entered
	pending := func() int {
		w.scheduler.mu.Lock()
		defer w.scheduler.mu.Unlock()
		return len(w.scheduler.pending)
	}
	for i, frame := range []Frame{output("pane-a", "a1"), output("pane-a", "a2"), output("pane-b", "b1")} {
		send(frame)
		deadline := time.Now().Add(time.Second)
		for pending() < i+1 {
			if time.Now().After(deadline) {
				t.Fatal("frame not queued")
			}
			time.Sleep(time.Millisecond)
		}
	}
	w.SetFocus([]string{"pane-b"})
	close(g.release)
	wg.Wait()
	stream := bytes.NewReader(g.buffer.Bytes())
	var order []string
	for {
		frame, err := ReadFrame(stream)
		if err != nil {
			break
		}
		_, inner, err := ParseHostEvent(frame)
		if err != nil {
			t.Fatal(err)
		}
		order = append(order, string(inner.Payload))
	}
	want := []string{"x", "b1", "a1", "a2"}
	if len(order) != len(want) {
		t.Fatalf("delivered %v", order)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order %v, want %v", order, want)
		}
	}
}
