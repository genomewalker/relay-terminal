package daemon

import (
	"sync/atomic"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// freshRedrawCapability: the worker can give one viewer a screen built only
// from a terminal reset and the agent's own redraw (protocol.FreshRedraw).
const freshRedrawCapability = "fresh_redraw_v1"

// Status states of one fresh redraw, in the order a viewer receives them.
const (
	freshRedrawBegin   = "fresh_redraw_begin"
	freshRedrawDone    = "fresh_redraw_done"
	freshRedrawRefused = "fresh_redraw_refused"
)

var freshRedrawActive atomic.Int32

// freshRedraw gives the requesting viewer one screen with no retained output.
// In order with its live output the viewer receives a begin status, a terminal
// reset and the current input modes (sequence zero, presentation only, never
// in the replay ring), then the foreground agent is told its unchanged grid
// changed, so it repaints, and a done status follows that repaint. Nothing is
// typed and the grid is not changed. Refused for a pane without an agent, with
// another viewer attached, or while another fresh redraw runs.
func (session *Session) freshRedraw(viewer *client) {
	if !freshRedrawActive.CompareAndSwap(0, 1) {
		session.queueFreshRedrawStatus(viewer, freshRedrawRefused, "another fresh redraw is running", 0)
		return
	}
	defer freshRedrawActive.Store(0)
	if !session.requiresAttachRepaint() {
		session.queueFreshRedrawStatus(viewer, freshRedrawRefused, "the pane runs no agent", 0)
		return
	}
	session.resizeMu.Lock()
	defer session.resizeMu.Unlock()

	session.mu.Lock()
	if _, attached := session.clients[viewer]; !attached || len(session.clients) != 1 {
		session.mu.Unlock()
		session.queueFreshRedrawStatus(viewer, freshRedrawRefused, "another viewer is attached", 0)
		return
	}
	begin, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: freshRedrawBegin})
	if err != nil || cap(viewer.frames)-len(viewer.frames) < 3 {
		session.mu.Unlock()
		session.queueFreshRedrawStatus(viewer, freshRedrawRefused, "the viewer is not keeping up", 0)
		return
	}
	before := session.sequence
	viewer.frames <- begin
	viewer.frames <- protocol.OutputFrame(0, []byte("\x1bc"))
	if prelude := session.terminalModes.presentationPrelude(); len(prelude) > 0 {
		viewer.frames <- protocol.OutputFrame(0, prelude)
	}
	session.mu.Unlock()

	message := "repainted"
	if err := session.signalForegroundResize(); err != nil {
		message = "no_signal"
	}
	sequence, repainted := session.waitForFreshRepaint(before, freshRepaintStart, freshRepaintQuiet, freshRepaintLimit)
	if message == "repainted" && !repainted {
		message = "no_repaint"
	}
	session.queueFreshRedrawStatus(viewer, freshRedrawDone, message, sequence)
}

func (session *Session) queueFreshRedrawStatus(viewer *client, state, message string, sequence uint64) {
	frame, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: state, Message: message, Sequence: sequence,
	})
	if err != nil {
		return
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if _, attached := session.clients[viewer]; !attached {
		return
	}
	select {
	case viewer.frames <- frame:
	default:
		viewer.markLagged()
		delete(session.clients, viewer)
	}
}

// An agent under load can take longer than an attach allows to start its
// redraw; the done status waits for the redraw to start and then go quiet.
const (
	freshRepaintStart = 2 * time.Second
	freshRepaintQuiet = 100 * time.Millisecond
	freshRepaintLimit = 3 * time.Second
)

// waitForFreshRepaint returns the output sequence once output after before
// has been quiet for quiet, or when no output started within start, or at
// limit. repainted reports whether any output followed before.
func (session *Session) waitForFreshRepaint(before uint64, start, quiet, limit time.Duration) (uint64, bool) {
	began := time.Now()
	lastSequence, lastChange := before, began
	for {
		sequence, exited, changed := session.outputSequenceWaitState()
		now := time.Now()
		if sequence != lastSequence {
			lastSequence, lastChange = sequence, now
		}
		repainted := sequence != before
		if exited || now.Sub(began) >= limit {
			return sequence, repainted
		}
		wake := began.Add(start)
		if repainted {
			wake = lastChange.Add(quiet)
		}
		if !now.Before(wake) {
			return sequence, repainted
		}
		if end := began.Add(limit); end.Before(wake) {
			wake = end
		}
		timer := time.NewTimer(time.Until(wake))
		select {
		case <-changed:
			timer.Stop()
		case <-timer.C:
		}
	}
}
