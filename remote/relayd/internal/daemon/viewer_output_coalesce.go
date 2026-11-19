package daemon

import (
	"encoding/binary"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// viewerCoalesceBytes bounds one merged live output frame.
const viewerCoalesceBytes = 256 << 10

// coalesceQueuedOutput merges sequenced output frames that are already waiting
// in a viewer's queue into one frame carrying the last sequence, as replay
// batching does. A TUI redraw (Claude scrolling, 2026-11-19 pane d62c62eb)
// arrives as hundreds of small PTY reads; sent one by one through the worker,
// supervisor and node hops they filled the 512-frame queue, the viewer was
// dropped, and every replay refilled it. Nothing waits for more output: only
// frames already queued are merged, so live latency is unchanged. The first
// frame that cannot be merged is returned after the merged one, in order.
func coalesceQueuedOutput(first protocol.Frame, queue <-chan protocol.Frame) []protocol.Frame {
	if !sequencedOutput(first) {
		return []protocol.Frame{first}
	}
	payload := append(make([]byte, 0, len(first.Payload)), first.Payload...)
	merged := false
	for len(payload) < viewerCoalesceBytes {
		select {
		case next := <-queue:
			if !sequencedOutput(next) || len(payload)+len(next.Payload)-8 > viewerCoalesceBytes {
				return []protocol.Frame{{Type: protocol.Output, Payload: payload}, next}
			}
			binary.BigEndian.PutUint64(payload[:8], binary.BigEndian.Uint64(next.Payload[:8]))
			payload = append(payload, next.Payload[8:]...)
			merged = true
		default:
			if !merged {
				return []protocol.Frame{first}
			}
			return []protocol.Frame{{Type: protocol.Output, Payload: payload}}
		}
	}
	return []protocol.Frame{{Type: protocol.Output, Payload: payload}}
}

func sequencedOutput(frame protocol.Frame) bool {
	return frame.Type == protocol.Output && len(frame.Payload) >= 8 && binary.BigEndian.Uint64(frame.Payload[:8]) != 0
}
