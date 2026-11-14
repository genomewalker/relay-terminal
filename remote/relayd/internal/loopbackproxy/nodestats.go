package loopbackproxy

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// Measurement only (focus-aware-transport-proposal.md, step 1). The node mux
// sits at the SSH boundary, so it can see how long the app takes to answer a
// heartbeat and how fast the app side drains what relayd writes. Nothing here
// changes scheduling, ordering or backpressure.
//
// RTT needs an app that echoes a node-level Ping (capability
// "node_ping_echo":true in its Capabilities frame). Current apps drop
// node-level Pings, so without that capability the mux sends none and reports
// only drain and queue figures. Pongs are matched by their 8-byte sequence; a
// Pong that matches no outstanding mux Ping is forwarded upstream unchanged.

// NodeStatsDir, when set, receives one JSON snapshot per node process. The
// directory must be node-local (the daemon socket directory), not shared $HOME.
var NodeStatsDir string

const (
	nodeStatsPingInterval = 5 * time.Second
	nodeStatsMaxPending   = 8
)

type NodeRTT struct {
	Samples     uint64  `json:"samples"`
	LastMs      float64 `json:"last_ms"`
	SmoothedMs  float64 `json:"smoothed_ms"`
	VariationMs float64 `json:"variation_ms"`
	MinMs       float64 `json:"min_ms"`
	MaxMs       float64 `json:"max_ms"`
	Outstanding int     `json:"outstanding"`
	Skipped     uint64  `json:"skipped"`
	Lost        uint64  `json:"lost"`
	Enabled     bool    `json:"enabled"`
}

type NodeDrain struct {
	BytesWritten     uint64  `json:"bytes_written_total"`
	WriteBlockedMs   float64 `json:"write_blocked_ms_total"`
	MaxWriteMs       float64 `json:"max_single_write_ms"`
	WindowSeconds    float64 `json:"window_seconds"`
	WindowBytesPerS  float64 `json:"window_bytes_per_second"`
	WindowBlockedPct float64 `json:"window_blocked_percent"`
	QueuedBytes      int     `json:"queued_bytes"`
	QueuedFrames     int     `json:"queued_frames"`
	MaxQueuedBytes   int     `json:"max_queued_bytes"`
}

type NodeStatsSnapshot struct {
	PID       int       `json:"pid"`
	StartedAt time.Time `json:"started_at"`
	UpdatedAt time.Time `json:"updated_at"`
	RTT       NodeRTT   `json:"rtt"`
	Drain     NodeDrain `json:"drain"`
}

type nodeStats struct {
	now     func() time.Time
	mu      sync.Mutex
	started time.Time
	pending map[uint64]time.Time
	seq     uint64
	rtt     NodeRTT
	drain   NodeDrain
	// window start for the rate fields
	windowAt      time.Time
	windowBytes   uint64
	windowBlocked time.Duration
	blocked       time.Duration
}

func newNodeStats(now func() time.Time) *nodeStats {
	t := now()
	return &nodeStats{now: now, started: t, windowAt: t, pending: map[uint64]time.Time{}}
}

const nodeStatsPingLost = time.Minute

// pingFrame returns the next mux Ping, or false when too many are unanswered.
func (s *nodeStats) pingFrame() (protocol.Frame, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.now()
	for seq, sent := range s.pending {
		if t.Sub(sent) >= nodeStatsPingLost {
			delete(s.pending, seq)
			s.rtt.Lost++
		}
	}
	if len(s.pending) >= nodeStatsMaxPending {
		s.rtt.Skipped++
		return protocol.Frame{}, false
	}
	s.seq++
	s.pending[s.seq] = t
	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, s.seq)
	return protocol.Frame{Type: protocol.Ping, Payload: payload}, true
}

// pingNotSent forgets a Ping whose write failed before reaching the app.
func (s *nodeStats) pingNotSent(frame protocol.Frame) {
	s.mu.Lock()
	if len(frame.Payload) == 8 {
		delete(s.pending, binary.BigEndian.Uint64(frame.Payload))
	}
	s.mu.Unlock()
}

// pong reports whether the Pong answered a mux Ping (and so must not be
// forwarded upstream).
func (s *nodeStats) pong(payload []byte) bool {
	if len(payload) != 8 {
		return false
	}
	seq := binary.BigEndian.Uint64(payload)
	s.mu.Lock()
	defer s.mu.Unlock()
	sent, ok := s.pending[seq]
	if !ok {
		return false
	}
	delete(s.pending, seq)
	ms := float64(s.now().Sub(sent)) / float64(time.Millisecond)
	r := &s.rtt
	if r.Samples == 0 {
		r.SmoothedMs, r.VariationMs, r.MinMs, r.MaxMs = ms, ms/2, ms, ms
	} else {
		// RFC 6298 smoothing: alpha 1/8, beta 1/4.
		diff := r.SmoothedMs - ms
		if diff < 0 {
			diff = -diff
		}
		r.VariationMs = 0.75*r.VariationMs + 0.25*diff
		r.SmoothedMs = 0.875*r.SmoothedMs + 0.125*ms
		if ms < r.MinMs {
			r.MinMs = ms
		}
		if ms > r.MaxMs {
			r.MaxMs = ms
		}
	}
	r.LastMs = ms
	r.Samples++
	return true
}

// NodeQuality is the path summary relayd node sends upstream to the daemon
// (protocol.Quality) after each new RTT sample.
type NodeQuality struct {
	RTTLastMs      float64 `json:"rtt_last_ms"`
	RTTMinMs       float64 `json:"rtt_min_ms"`
	RTTSmoothedMs  float64 `json:"rtt_smoothed_ms"`
	RTTVariationMs float64 `json:"rtt_variation_ms"`
	RTTSamples     uint64  `json:"rtt_samples"`
	RTTLost        uint64  `json:"rtt_lost"`
	BytesWritten   uint64  `json:"bytes_written_total"`
	WriteBlockedMs float64 `json:"write_blocked_ms_total"`
}

// qualityFrame returns the path summary when an RTT sample arrived since
// sentSamples, without closing the snapshot's rate window.
func (s *nodeStats) qualityFrame(sentSamples uint64) (protocol.Frame, uint64, bool) {
	s.mu.Lock()
	quality := NodeQuality{RTTLastMs: s.rtt.LastMs, RTTMinMs: s.rtt.MinMs, RTTSmoothedMs: s.rtt.SmoothedMs,
		RTTVariationMs: s.rtt.VariationMs, RTTSamples: s.rtt.Samples, RTTLost: s.rtt.Lost,
		BytesWritten: s.drain.BytesWritten, WriteBlockedMs: float64(s.blocked) / float64(time.Millisecond)}
	s.mu.Unlock()
	if quality.RTTSamples == sentSamples {
		return protocol.Frame{}, sentSamples, false
	}
	frame, err := protocol.JSONFrame(protocol.Quality, quality)
	return frame, quality.RTTSamples, err == nil
}

func (s *nodeStats) enableRTT() {
	s.mu.Lock()
	s.rtt.Enabled = true
	s.mu.Unlock()
}

func (s *nodeStats) rttEnabled() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rtt.Enabled
}

func (s *nodeStats) wrote(n int, took time.Duration) {
	s.mu.Lock()
	s.drain.BytesWritten += uint64(n)
	s.blocked += took
	if ms := float64(took) / float64(time.Millisecond); ms > s.drain.MaxWriteMs {
		s.drain.MaxWriteMs = ms
	}
	s.mu.Unlock()
}

func (s *nodeStats) queued(bytes, frames int) {
	s.mu.Lock()
	s.drain.QueuedBytes, s.drain.QueuedFrames = bytes, frames
	if bytes > s.drain.MaxQueuedBytes {
		s.drain.MaxQueuedBytes = bytes
	}
	s.mu.Unlock()
}

// snapshot closes the current rate window and starts the next one.
func (s *nodeStats) snapshot() NodeStatsSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.now()
	window := t.Sub(s.windowAt)
	if window > 0 {
		s.drain.WindowSeconds = window.Seconds()
		s.drain.WindowBytesPerS = float64(s.drain.BytesWritten-s.windowBytes) / window.Seconds()
		s.drain.WindowBlockedPct = 100 * float64(s.blocked-s.windowBlocked) / float64(window)
	}
	s.windowAt, s.windowBytes, s.windowBlocked = t, s.drain.BytesWritten, s.blocked
	s.drain.WriteBlockedMs = float64(s.blocked) / float64(time.Millisecond)
	snap := NodeStatsSnapshot{PID: os.Getpid(), StartedAt: s.started, UpdatedAt: t, RTT: s.rtt, Drain: s.drain}
	snap.RTT.Outstanding = len(s.pending)
	s.drain.MaxQueuedBytes, s.drain.MaxWriteMs = s.drain.QueuedBytes, 0
	return snap
}

// timedWriter measures how long the SSH stdout pipe blocks each write.
type timedWriter struct {
	out   io.Writer
	stats *nodeStats
}

func (w timedWriter) Write(p []byte) (int, error) {
	start := w.stats.now()
	n, err := w.out.Write(p)
	w.stats.wrote(n, w.stats.now().Sub(start))
	return n, err
}

func nodeStatsPath(dir string, pid int) string {
	return filepath.Join(dir, strconv.Itoa(pid)+".json")
}

func writeNodeStats(dir string, snap NodeStatsSnapshot) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	encoded, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	final := nodeStatsPath(dir, snap.PID)
	tmp := final + ".tmp"
	if err := os.WriteFile(tmp, encoded, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, final)
}

// Variables only so tests can shorten them.
var (
	nodeStatsPingEvery   = nodeStatsPingInterval
	nodeStatsSampleEvery = time.Second
)

// runNodeStats starts after the app's first frame, so a heartbeat never
// precedes the app's own handshake. Pings go out only after the app has
// advertised node_ping_echo.
//
// After each new RTT sample the path summary goes upstream, so the daemon
// that schedules pane output sees the same measurements (step 2).
func runNodeStats(ctx context.Context, stats *nodeStats, client, upstream *protocol.Writer, measuring <-chan struct{}) {
	select {
	case <-measuring:
	case <-ctx.Done():
		return
	}
	dir := NodeStatsDir
	if dir != "" {
		defer os.Remove(nodeStatsPath(dir, os.Getpid()))
	}
	sample := time.NewTicker(nodeStatsSampleEvery)
	defer sample.Stop()
	ping := time.NewTicker(nodeStatsPingEvery)
	defer ping.Stop()
	samples := 0
	var reportedRTT uint64
	for {
		select {
		case <-ctx.Done():
			return
		case <-sample.C:
			stats.queued(client.Queued())
			if upstream != nil {
				if frame, reported, ok := stats.qualityFrame(reportedRTT); ok {
					reportedRTT = reported
					go func() { _ = upstream.Write(frame) }()
				}
			}
			samples++
			if dir != "" && samples%5 == 0 {
				_ = writeNodeStats(dir, stats.snapshot())
			}
		case <-ping.C:
			if !stats.rttEnabled() {
				continue
			}
			frame, ok := stats.pingFrame()
			if !ok {
				continue
			}
			go func() {
				if client.Write(frame) != nil {
					stats.pingNotSent(frame)
				}
			}()
		}
	}
}
