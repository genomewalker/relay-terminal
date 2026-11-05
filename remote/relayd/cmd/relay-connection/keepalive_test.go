package main

import (
	"bytes"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

const second = int64(time.Second)

// keepaliveRun drives keepalive with a fake clock: tick k happens at 2k s.
// before runs ahead of each tick's check and may record inbound data.
func keepaliveRun(ticks int, before func(tick int, inbound *atomic.Int64, pings []int64)) (pings []int64, killedAt int) {
	var inbound atomic.Int64
	tick := 0
	keepalive(func() int64 { return int64(tick) * 2 * second },
		func() bool {
			tick++
			if tick > ticks {
				return false
			}
			if before != nil {
				before(tick, &inbound, pings)
			}
			return true
		},
		&inbound,
		func(payload []byte) error { pings = append(pings, int64(tick)*2*second); return nil },
		func() { killedAt = tick })
	return pings, killedAt
}

func TestHeartbeatThreshold(t *testing.T) {
	if heartbeatRestartMisses != 3 || heartbeatTimeout != 6*second || heartbeatInterval != 2*time.Second {
		t.Fatal("heartbeat policy changed", heartbeatRestartMisses, heartbeatTimeout, heartbeatInterval)
	}
}

func TestHeartbeatCheckDropsCoveredProbesUncounted(t *testing.T) {
	state := heartbeatState{pending: []int64{100, 100 + heartbeatTimeout}, misses: 2, lastMiss: 50}
	next, dead := state.check(101, 100+heartbeatTimeout)
	if dead || next.misses != 0 || len(next.pending) != 1 || next.pending[0] != 100+heartbeatTimeout {
		t.Fatalf("covered probe: dead=%v state=%+v", dead, next)
	}
	// Data older than the last counted miss neither covers nor resets.
	state = heartbeatState{pending: []int64{100}, misses: 2, lastMiss: 90}
	next, dead = state.check(80, 100+heartbeatTimeout)
	if !dead || next.misses != 3 {
		t.Fatalf("stale data reset the misses: dead=%v state=%+v", dead, next)
	}
}

func TestHeartbeatCheckBoundaries(t *testing.T) {
	// Age: exactly the timeout has expired, one nanosecond less has not.
	if next, _ := (heartbeatState{pending: []int64{100}}).check(0, 99+heartbeatTimeout); len(next.pending) != 1 || next.misses != 0 {
		t.Fatalf("expired early: %+v", next)
	}
	if next, _ := (heartbeatState{pending: []int64{100}}).check(0, 100+heartbeatTimeout); len(next.pending) != 0 || next.misses != 1 {
		t.Fatalf("not expired at the timeout: %+v", next)
	}
	// Data at the send instant does not cover the probe.
	if next, _ := (heartbeatState{pending: []int64{100}}).check(100, 100+heartbeatTimeout); next.misses != 1 {
		t.Fatalf("send-instant data covered the probe: %+v", next)
	}
	// Threshold: two prior misses plus one is fatal, one plus one is not.
	if _, dead := (heartbeatState{pending: []int64{100}, misses: 1, lastMiss: 90}).check(0, 100+heartbeatTimeout); dead {
		t.Fatal("killed below the threshold")
	}
	if _, dead := (heartbeatState{pending: []int64{100}, misses: 2, lastMiss: 90}).check(0, 100+heartbeatTimeout); !dead {
		t.Fatal("not killed at the threshold")
	}
}

func TestHeartbeatTotalSilenceKillsAfterExactlyTheThreshold(t *testing.T) {
	pings, killedAt := keepaliveRun(20, nil)
	// Probes at 2..10 s; misses counted at 8 and 10 s; the third at 12 s kills.
	if killedAt != 6 || len(pings) != 5 {
		t.Fatalf("killed at tick %d after %d pings, want tick 6 after 5", killedAt, len(pings))
	}
}

func TestHeartbeatSingleSlowReplyKeepsTheSSH(t *testing.T) {
	pings, killedAt := keepaliveRun(30, func(tick int, inbound *atomic.Int64, pings []int64) {
		switch {
		case tick == 5: // one slow reply, after the first miss was counted at 8 s
			inbound.Store(9 * second)
		case tick > 5: // later probes are answered promptly
			inbound.Store(pings[len(pings)-1] + second/10)
		}
	})
	if killedAt != 0 || len(pings) != 30 {
		t.Fatalf("killed at tick %d after %d pings", killedAt, len(pings))
	}
}

func TestHeartbeatInboundDataResetsTheMisses(t *testing.T) {
	pings, killedAt := keepaliveRun(30, func(tick int, inbound *atomic.Int64, _ []int64) {
		if tick == 6 { // misses counted at 8 and 10 s; pane output at 10.5 s
			inbound.Store(10*second + second/2)
		}
	})
	// Probes sent up to 10 s are covered; three fresh misses follow at 18, 20, 22 s.
	if killedAt != 11 || len(pings) != 10 {
		t.Fatalf("killed at tick %d after %d pings, want tick 11 after 10", killedAt, len(pings))
	}
}

func TestHeartbeatPingFailureStopsWithoutKilling(t *testing.T) {
	var inbound atomic.Int64
	ticks, killed := 0, false
	keepalive(func() int64 { return int64(ticks) * 2 * second },
		func() bool { ticks++; return ticks < 10 }, &inbound,
		func([]byte) error { return errors.New("closed") }, func() { killed = true })
	if killed || ticks != 1 {
		t.Fatalf("ticks=%d killed=%v", ticks, killed)
	}
}

func TestInboundReaderRecordsEveryRead(t *testing.T) {
	var last atomic.Int64
	reader := inboundReader{bytes.NewReader([]byte("x")), &last}
	before := time.Now().UnixNano()
	if n, _ := reader.Read(make([]byte, 4)); n != 1 || last.Load() < before {
		t.Fatalf("read %d bytes, last=%d before=%d", n, last.Load(), before)
	}
	last.Store(0)
	if n, _ := reader.Read(make([]byte, 4)); n != 0 || last.Load() != 0 {
		t.Fatal("an empty read counted as inbound data")
	}
}
