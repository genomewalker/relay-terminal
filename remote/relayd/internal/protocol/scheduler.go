package protocol

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
)

const maxQueuedBytes = 32 << 20
const maxQueuedFrames = 128

var ErrBackpressure = errors.New("node writer queue capacity exceeded; reconnect from acknowledged state")

type scheduledFrame struct {
	frame     Frame
	key       string
	priority  int
	done      chan error
	messageID uint64
	offset    int
}

type frameScheduler struct {
	mu            sync.Mutex
	sink          *Writer
	pending       []*scheduledFrame
	bytes         int
	draining      bool
	failure       error
	burst         int
	fragments     bool
	nextMessageID uint64
	// focus holds the scheduling keys ("pane:<route>") of the focused pane.
	focus map[string]bool
}

// NewScheduledWriter leaves the wire format untouched. Only independent route
// heads can overtake one another; replay/output/status order within a pane is
// retained. An in-flight frame is never split or preempted.
func NewScheduledWriter(destination io.Writer) *Writer {
	return &Writer{scheduler: &frameScheduler{sink: NewWriter(destination)}}
}

func schedulingClass(frame Frame) (string, int) {
	if frame.Type == HostEvent {
		route, inner, err := ParseHostEvent(frame)
		if err == nil {
			return "pane:" + route, framePriority(inner.Type)
		}
	}
	if frame.Type == HostResponse {
		var response struct {
			RequestID string `json:"request_id"`
		}
		if json.Unmarshal(frame.Payload, &response) == nil && response.RequestID != "" {
			return "rpc:" + response.RequestID, 3
		}
	}
	if frame.Type == Ping || frame.Type == Pong {
		return "heartbeat", 0
	}
	return "connection", framePriority(frame.Type)
}
func framePriority(kind Type) int {
	switch kind {
	case Ping, Pong, Input, InputV2, InputAck, Resize, Detach, ViewportAck:
		return 0
	case Output:
		return 1
	case AgentEvent, WorkspaceState:
		return 2
	case Artifact, HostResponse:
		return 3
	default:
		return 0
	}
}

func (s *frameScheduler) write(frame Frame) error {
	if len(frame.Payload) > MaxPayload {
		return errors.New("payload too large")
	}
	key, priority := schedulingClass(frame)
	item := &scheduledFrame{frame: frame, key: key, priority: priority, done: make(chan error, 1)}
	s.mu.Lock()
	if s.failure != nil {
		err := s.failure
		s.mu.Unlock()
		return err
	}
	if len(s.pending) >= maxQueuedFrames || s.bytes+len(frame.Payload) > maxQueuedBytes {
		s.mu.Unlock()
		return ErrBackpressure
	}
	s.pending = append(s.pending, item)
	s.bytes += len(frame.Payload)
	if !s.draining {
		s.draining = true
		go s.drain()
	}
	s.mu.Unlock()
	return <-item.done
}

// Eight priority selections are followed by an oldest-first selection to bound
// starvation under sustained interactive traffic.
func (s *frameScheduler) choose() int {
	if s.burst >= 8 {
		s.burst = 0
		return 0
	}
	seen := make(map[string]bool)
	best := 0
	for i, item := range s.pending {
		if seen[item.key] {
			continue
		}
		seen[item.key] = true
		if s.rank(item) < s.rank(s.pending[best]) {
			best = i
		}
	}
	if best != 0 {
		s.burst++
	} else {
		s.burst = 0
	}
	return best
}

// rank orders queue heads. With no focus it is the frame priority (doubled),
// so the order is unchanged. With a focus, an unfocused pane's frame ranks one
// step lower, so the focused pane's output goes before other panes' output of
// the same kind, while input, acks and heartbeats of every pane still go
// first. Connection-level frames are not affected.
func (s *frameScheduler) rank(item *scheduledFrame) int {
	rank := item.priority * 2
	if len(s.focus) > 0 && strings.HasPrefix(item.key, "pane:") && !s.focus[item.key] {
		rank++
	}
	return rank
}

// SetFocus names the routes of the focused pane; nil or empty clears it. It
// re-ranks frames already queued and never drops or splits one.
func (writer *Writer) SetFocus(routes []string) {
	if writer.scheduler == nil {
		return
	}
	focus := make(map[string]bool, len(routes))
	for _, route := range routes {
		focus["pane:"+route] = true
	}
	writer.scheduler.mu.Lock()
	writer.scheduler.focus = focus
	writer.scheduler.mu.Unlock()
}

// Queued reports the scheduler's waiting bytes and frames (measurement only).
func (writer *Writer) Queued() (bytes, frames int) {
	if writer.scheduler == nil {
		return 0, 0
	}
	writer.scheduler.mu.Lock()
	defer writer.scheduler.mu.Unlock()
	return writer.scheduler.bytes, len(writer.scheduler.pending)
}

func (writer *Writer) EnableFragments() {
	if writer.scheduler != nil {
		writer.scheduler.mu.Lock()
		writer.scheduler.fragments = true
		writer.scheduler.mu.Unlock()
	}
}

func (s *frameScheduler) drain() {
	for {
		s.mu.Lock()
		if len(s.pending) == 0 {
			s.draining = false
			s.mu.Unlock()
			return
		}
		index := s.choose()
		item := s.pending[index]
		outgoing := item.frame
		final := true
		if s.fragments && len(item.frame.Payload) > FragmentChunkBytes {
			if item.messageID == 0 {
				s.nextMessageID++
				item.messageID = s.nextMessageID
			}
			end := item.offset + FragmentChunkBytes
			if end > len(item.frame.Payload) {
				end = len(item.frame.Payload)
			}
			outgoing = FragmentFrame(item.messageID, item.frame.Type, len(item.frame.Payload), item.offset, item.frame.Payload[item.offset:end])
			item.offset = end
			final = end == len(item.frame.Payload)
		}
		if final {
			s.pending = append(s.pending[:index], s.pending[index+1:]...)
			s.bytes -= len(item.frame.Payload)
		}
		s.mu.Unlock()
		err := s.sink.Write(outgoing)
		if final || err != nil {
			item.done <- err
		}
		if err != nil {
			s.mu.Lock()
			s.failure = err
			remaining := s.pending
			s.pending = nil
			s.bytes = 0
			s.draining = false
			s.mu.Unlock()
			for _, next := range remaining {
				if next != item {
					next.done <- err
				}
			}
			return
		}
	}
}
