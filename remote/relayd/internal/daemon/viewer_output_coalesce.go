package daemon

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

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
	compacted, total := compactQueuedOutput(gatherOutputPastAgentEvents(dropSupersededProgramStatus(pending)))
	for _, frame := range compacted {
		viewer.frames <- frame
	}
	fits := total <= viewerCompactTotalBytes && cap(viewer.frames)-len(viewer.frames) >= n
	if !fits {
		// The caller cuts this viewer next. Say why: which frames could not
		// merge and how many bytes were waiting. Without this a cut view on a
		// live host could not be told apart from any other closed route.
		fmt.Fprintf(os.Stderr, "relay: viewer cut: queue %d of %d frames after compaction (%d before), %d bytes, needed %d; %s\n",
			len(compacted), cap(viewer.frames), len(pending), total, n, queuedFrameKinds(compacted))
	}
	return fits
}

// queuedFrameKinds counts queued frames by kind for the cut log.
func queuedFrameKinds(frames []protocol.Frame) string {
	counts := map[string]int{}
	for _, frame := range frames {
		kind := fmt.Sprintf("type%d", frame.Type)
		switch {
		case sequencedOutput(frame):
			kind = "output"
		case frame.Type == protocol.Output:
			kind = "output-unsequenced"
		case frame.Type == protocol.AgentEvent:
			kind = "agent-event"
		case frame.Type == protocol.Status:
			var status struct {
				State string `json:"state"`
			}
			_ = json.Unmarshal(frame.Payload, &status)
			kind = "status:" + status.State
		}
		counts[kind]++
	}
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", key, counts[key]))
	}
	return strings.Join(parts, " ")
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

// dropSupersededProgramStatus keeps only the last live program_status update
// in a full queue. Each update is a complete snapshot with a revision, so an
// earlier one that has not been sent yet carries nothing the last one lacks.
// Claude's redraws arrive interleaved with these updates (2026-11-22, c0441e7b
// and 32655e54): with an update between every two output frames nothing could
// merge and the full queue cut the view. Replay snapshots, sent when a viewer
// attaches, and every other frame keep their place.
func dropSupersededProgramStatus(frames []protocol.Frame) []protocol.Frame {
	last := -1
	for i, frame := range frames {
		if liveProgramStatus(frame) {
			last = i
		}
	}
	if last < 0 {
		return frames
	}
	out := frames[:0:0]
	for i, frame := range frames {
		if i != last && liveProgramStatus(frame) {
			continue
		}
		out = append(out, frame)
	}
	return out
}

func liveProgramStatus(frame protocol.Frame) bool {
	if frame.Type != protocol.Status {
		return false
	}
	var status struct {
		State  string `json:"state"`
		Replay bool   `json:"program_status_replay"`
	}
	return json.Unmarshal(frame.Payload, &status) == nil && status.State == "program_status" && !status.Replay
}

// gatherOutputPastAgentEvents moves agent event frames in a full queue after
// the sequenced output they are interleaved with, so that output becomes
// adjacent and merges. Events are sequenced and cannot be dropped or merged,
// but they are a separate stream with their own cursor: each stream keeps
// its own order, and only their interleaving changes. Every other frame
// (artifacts, which belong to the output before them, and statuses) is a
// barrier that neither stream crosses. Raising the queue's frame count
// instead would let 32 KiB reads hold far more memory before compacting.
func gatherOutputPastAgentEvents(frames []protocol.Frame) []protocol.Frame {
	out := make([]protocol.Frame, 0, len(frames))
	var events []protocol.Frame
	flush := func() {
		out = append(out, events...)
		events = events[:0]
	}
	for _, frame := range frames {
		switch {
		case frame.Type == protocol.AgentEvent:
			events = append(events, frame)
		case sequencedOutput(frame):
			out = append(out, frame)
		default:
			flush()
			out = append(out, frame)
		}
	}
	flush()
	return out
}
