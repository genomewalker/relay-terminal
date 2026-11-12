package loopbackproxy

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func seqPayload(seq uint64) []byte {
	p := make([]byte, 8)
	binary.BigEndian.PutUint64(p, seq)
	return p
}

func TestNodeStatsRTTMatchesBySequenceAndSmooths(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1000, 0)}
	s := newNodeStats(clock.now)
	if s.pong(seqPayload(1)) || s.pong(nil) {
		t.Fatal("a Pong with no outstanding mux Ping was consumed")
	}
	first, ok := s.pingFrame()
	if !ok || first.Type != protocol.Ping {
		t.Fatal("first ping", first, ok)
	}
	clock.t = clock.t.Add(5 * time.Second)
	second, _ := s.pingFrame()
	clock.t = clock.t.Add(40 * time.Millisecond)
	if !s.pong(second.Payload) {
		t.Fatal("second pong not matched")
	}
	clock.t = clock.t.Add(60 * time.Millisecond)
	if !s.pong(first.Payload) {
		t.Fatal("out-of-order pong not matched")
	}
	if s.pong(first.Payload) {
		t.Fatal("same pong matched twice")
	}
	snap := s.snapshot()
	r := snap.RTT
	// samples: 40 ms, then 5100 ms
	if r.Samples != 2 || r.MinMs != 40 || r.MaxMs != 5100 || r.LastMs != 5100 {
		t.Fatal("rtt", r)
	}
	if want := 0.875*40 + 0.125*5100; r.SmoothedMs != want {
		t.Fatal("smoothed", r.SmoothedMs, want)
	}
	if want := 0.75*20 + 0.25*5060; r.VariationMs != want {
		t.Fatal("variation", r.VariationMs, want)
	}
}

func TestNodeStatsBoundsOutstandingAndCountsLost(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1000, 0)}
	s := newNodeStats(clock.now)
	for i := 0; i < nodeStatsMaxPending; i++ {
		if _, ok := s.pingFrame(); !ok {
			t.Fatal("ping refused early", i)
		}
	}
	if _, ok := s.pingFrame(); ok {
		t.Fatal("more than the cap outstanding")
	}
	clock.t = clock.t.Add(nodeStatsPingLost)
	if _, ok := s.pingFrame(); !ok {
		t.Fatal("expired pings still block new ones")
	}
	r := s.snapshot().RTT
	if r.Skipped != 1 || r.Lost != nodeStatsMaxPending || r.Outstanding != 1 {
		t.Fatal("counters", r)
	}
}

func TestNodeStatsDrainWindow(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1000, 0)}
	s := newNodeStats(clock.now)
	s.wrote(1000, 200*time.Millisecond)
	s.wrote(3000, 300*time.Millisecond)
	s.queued(5000, 3)
	s.queued(100, 1)
	clock.t = clock.t.Add(2 * time.Second)
	d := s.snapshot().Drain
	if d.BytesWritten != 4000 || d.WindowBytesPerS != 2000 || d.WindowBlockedPct != 25 || d.MaxWriteMs != 300 ||
		d.QueuedBytes != 100 || d.MaxQueuedBytes != 5000 || d.WriteBlockedMs != 500 {
		t.Fatal("drain", d)
	}
	clock.t = clock.t.Add(time.Second)
	d = s.snapshot().Drain
	if d.WindowBytesPerS != 0 || d.WindowBlockedPct != 0 || d.MaxWriteMs != 0 || d.MaxQueuedBytes != 100 || d.BytesWritten != 4000 {
		t.Fatal("second window", d)
	}
}

// End to end through the node mux: without node_ping_echo no Ping reaches the
// app; with it, the app's echo is consumed by the mux, an unmatched Pong still
// reaches the daemon, and a snapshot file appears next to the socket.
func TestNodeMuxMeasuresOnlyWithEchoCapability(t *testing.T) {
	for _, echo := range []bool{false, true} {
		pingEvery, sampleEvery, dir := nodeStatsPingEvery, nodeStatsSampleEvery, NodeStatsDir
		nodeStatsPingEvery, nodeStatsSampleEvery, NodeStatsDir = 20*time.Millisecond, 5*time.Millisecond, t.TempDir()
		func() {
			defer func() { nodeStatsPingEvery, nodeStatsSampleEvery, NodeStatsDir = pingEvery, sampleEvery, dir }()
			client, front := net.Pipe()
			upstream, supervisor := net.Pipe()
			defer client.Close()
			defer supervisor.Close()
			deadline := time.Now().Add(5 * time.Second)
			client.SetDeadline(deadline)
			supervisor.SetDeadline(deadline)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go RelayNode(ctx, front, front, upstream)
			daemonFrames := make(chan protocol.Frame, 16)
			go func() {
				_ = protocol.NewWriter(supervisor).Write(protocol.Frame{Type: protocol.Status, Payload: []byte(`{"state":"ready","capabilities":[]}`)})
				for {
					frame, err := protocol.ReadFrame(supervisor)
					if err != nil {
						close(daemonFrames)
						return
					}
					daemonFrames <- frame
				}
			}()
			if status, err := protocol.ReadFrame(client); err != nil || status.Type != protocol.Status {
				t.Fatal("ready", status, err)
			}
			writer := protocol.NewWriter(client)
			caps := `{"wire_fragments":true}`
			if echo {
				caps = `{"wire_fragments":true,"node_ping_echo":true}`
			}
			if err := writer.Write(protocol.Frame{Type: protocol.Capabilities, Payload: []byte(caps)}); err != nil {
				t.Fatal(err)
			}
			if !echo {
				client.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
				if frame, err := protocol.ReadFrame(client); err == nil {
					t.Fatal("mux sent a frame to an app without node_ping_echo", frame.Type)
				}
				return
			}
			ping, err := protocol.ReadFrame(client)
			if err != nil || ping.Type != protocol.Ping || len(ping.Payload) != 8 {
				t.Fatal("mux ping", ping, err)
			}
			if err := writer.Write(protocol.Frame{Type: protocol.Pong, Payload: ping.Payload}); err != nil {
				t.Fatal(err)
			}
			unmatched := seqPayload(1 << 60)
			if err := writer.Write(protocol.Frame{Type: protocol.Pong, Payload: unmatched}); err != nil {
				t.Fatal(err)
			}
			select {
			case frame := <-daemonFrames:
				if frame.Type != protocol.Pong || string(frame.Payload) != string(unmatched) {
					t.Fatal("daemon got the mux's own echo or something else", frame)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("unmatched Pong was not forwarded")
			}
			// Keep answering so the client side never blocks, until a snapshot shows the sample.
			go func() {
				for {
					frame, err := protocol.ReadFrame(client)
					if err != nil {
						return
					}
					if frame.Type == protocol.Ping {
						_ = writer.Write(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload})
					}
				}
			}()
			for time.Now().Before(deadline) {
				data, err := os.ReadFile(nodeStatsPath(NodeStatsDir, os.Getpid()))
				var snap NodeStatsSnapshot
				if err == nil && json.Unmarshal(data, &snap) == nil && snap.RTT.Samples >= 1 && snap.RTT.Enabled && snap.Drain.BytesWritten > 0 {
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			t.Fatal("no snapshot with an RTT sample")
		}()
	}
}
