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

// Bounds for compacting a full viewer queue: one merged frame stays well under
// the protocol's 16 MiB payload, and a viewer that is this far behind is cut
// as before rather than holding unbounded memory.
const (
	viewerCompactFrameBytes = 1 << 20
	viewerCompactTotalBytes = 32 << 20
)

// makeRoom reports whether n more frames fit in the viewer's queue, first
// merging the sequenced output already waiting there when it is full. A
// shared SSH link that stalls for a few seconds (dandy-07 after a restart,
// 2026-11-19) used to fill the 512-frame queue and cut the view, which the
// app showed as "Reconnecting" and answered with a full replay that added
// more traffic. Merging keeps every byte and the order of every frame; only
// adjacent output frames become one frame carrying the last sequence. The
// caller holds session.mu, so no other producer writes the queue meanwhile;
// the writer goroutine may still take frames, which only adds room.
func (viewer *client) makeRoom(n int) bool {
	if cap(viewer.frames)-len(viewer.frames) >= n {
		return true
	}
	pending := make([]protocol.Frame, 0, len(viewer.frames))
	for drained := false; !drained; {
		select {
		case frame := <-viewer.frames:
			pending = append(pending, frame)
		default:
			drained = true
		}
	}
	compacted, total := compactQueuedOutput(pending)
	for _, frame := range compacted {
		viewer.frames <- frame
	}
	return total <= viewerCompactTotalBytes && cap(viewer.frames)-len(viewer.frames) >= n
}

// compactQueuedOutput merges each run of adjacent sequenced output frames,
// up to viewerCompactFrameBytes per merged frame, and returns the frames in
// their original order with the total queued payload size.
func compactQueuedOutput(frames []protocol.Frame) ([]protocol.Frame, int) {
	out := make([]protocol.Frame, 0, len(frames))
	total := 0
	for _, frame := range frames {
		total += len(frame.Payload)
		if last := len(out) - 1; last >= 0 && sequencedOutput(frame) && sequencedOutput(out[last]) &&
			len(out[last].Payload)+len(frame.Payload)-8 <= viewerCompactFrameBytes {
			payload := out[last].Payload
			binary.BigEndian.PutUint64(payload[:8], binary.BigEndian.Uint64(frame.Payload[:8]))
			out[last].Payload = append(payload, frame.Payload[8:]...)
			continue
		}
		if sequencedOutput(frame) {
			frame.Payload = append(make([]byte, 0, len(frame.Payload)), frame.Payload...)
		}
		out = append(out, frame)
	}
	return out, total
}
