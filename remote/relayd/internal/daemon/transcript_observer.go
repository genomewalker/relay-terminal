package daemon

import (
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// agentProcessSource returns the current provider processes and a broadcast
// channel that closes when that set changes. A nil channel means the source is
// sampled on the transcript timer (used only for compatibility workers).
type agentProcessSource func() (map[int]string, <-chan struct{})

// observeAgentTranscripts shares discovery and scheduling between Codex and
// Claude. The durable worker feeds this from Session's single /proc watcher, so
// transcript support adds no extra process-tree traversals per pane.
func observeAgentTranscripts(source agentProcessSource) (<-chan protocol.Frame, func()) {
	frames := make(chan protocol.Frame, 64)
	stopped := make(chan struct{})
	var stopOnce sync.Once
	go func() {
		defer close(frames)
		timer := time.NewTimer(0)
		defer timer.Stop()
		codexReaders := make(map[int]*codexTranscriptReader)
		claudeReaders := make(map[int]*claudeTranscriptReader)
		var changed <-chan struct{}
		idlePolls := 0

		poll := func() (bool, bool) {
			processes, nextChanged := source()
			changed = nextChanged
			activity := false
			for pid, agent := range processes {
				switch agent {
				case "codex":
					reader := codexReaders[pid]
					if reader == nil {
						reader = &codexTranscriptReader{
							rootPID: pid, known: make(map[string]bool), active: make(map[string]bool),
						}
						codexReaders[pid] = reader
						activity = true
					}
					beforePath, beforeOffset := reader.path, reader.offset
					if !reader.poll(frames, stopped) {
						return false, activity
					}
					activity = activity || reader.path != beforePath || reader.offset != beforeOffset
				case "claude":
					reader := claudeReaders[pid]
					if reader == nil {
						reader = &claudeTranscriptReader{
							rootPID: pid, known: make(map[string]bool), active: make(map[string]bool),
						}
						claudeReaders[pid] = reader
						activity = true
					}
					beforePath, beforeOffset := reader.path, reader.offset
					if !reader.poll(frames, stopped) {
						return false, activity
					}
					activity = activity || reader.path != beforePath || reader.offset != beforeOffset
				}
			}
			for pid := range codexReaders {
				if processes[pid] != "codex" {
					delete(codexReaders, pid)
					activity = true
				}
			}
			for pid := range claudeReaders {
				if processes[pid] != "claude" {
					delete(claudeReaders, pid)
					activity = true
				}
			}
			return true, activity
		}
		resetTimer := func(activity bool) {
			if activity {
				idlePolls = 0
			} else if idlePolls < 3 {
				idlePolls++
			}
			timer.Reset(transcriptPollInterval(len(codexReaders)+len(claudeReaders), idlePolls))
		}

		for {
			select {
			case <-timer.C:
				keepRunning, activity := poll()
				if !keepRunning {
					return
				}
				resetTimer(activity)
			case <-changed:
				keepRunning, activity := poll()
				if !keepRunning {
					return
				}
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				resetTimer(activity)
			case <-stopped:
				return
			}
		}
	}()
	return frames, func() { stopOnce.Do(func() { close(stopped) }) }
}
