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
	run := observeAgentTranscriptsFrom(source, nil)
	return run.frames, run.stop
}

// transcriptCursor is one provider transcript reader's position. A pane worker
// that re-executes itself resumes from these instead of re-reading transcripts
// from the start.
type transcriptCursor struct {
	Agent               string          `json:"agent"`
	RootPID             int             `json:"root_pid"`
	RootStart           uint64          `json:"root_start"`
	Path                string          `json:"path,omitempty"`
	Offset              int64           `json:"offset"`
	DiscardingOversized bool            `json:"discarding_oversized,omitempty"`
	Identity            [2]uint64       `json:"identity"`
	Known               map[string]bool `json:"known,omitempty"`
	Active              map[string]bool `json:"active,omitempty"`
}

type transcriptRun struct {
	frames <-chan protocol.Frame
	// stop cancels at once, possibly mid-transcript; used on worker exit.
	stop func()
	// drain stops after the current poll has delivered every frame it read
	// and returns the cursors. The consumer must keep reading frames until
	// the channel closes, or drain does not return.
	drain func() []transcriptCursor
}

func observeAgentTranscriptsFrom(source agentProcessSource, seed []transcriptCursor) transcriptRun {
	frames := make(chan protocol.Frame, 64)
	stopped := make(chan struct{})
	quit := make(chan struct{})
	finished := make(chan struct{})
	var cursors []transcriptCursor
	var stopOnce, quitOnce sync.Once
	codexReaders := make(map[int]*codexTranscriptReader)
	claudeReaders := make(map[int]*claudeTranscriptReader)
	for _, c := range seed {
		switch c.Agent {
		case "codex":
			codexReaders[c.RootPID] = &codexTranscriptReader{rootPID: c.RootPID, rootStart: c.RootStart, path: c.Path,
				offset: c.Offset, discardingOversized: c.DiscardingOversized, identity: c.Identity,
				known: nonNilFlags(c.Known), active: nonNilFlags(c.Active)}
		case "claude":
			claudeReaders[c.RootPID] = &claudeTranscriptReader{rootPID: c.RootPID, rootStart: c.RootStart, path: c.Path,
				offset: c.Offset, discardingOversized: c.DiscardingOversized, identity: c.Identity,
				known: nonNilFlags(c.Known), active: nonNilFlags(c.Active)}
		}
	}
	go func() {
		defer close(finished)
		defer close(frames)
		defer func() {
			for _, r := range codexReaders {
				cursors = append(cursors, transcriptCursor{Agent: "codex", RootPID: r.rootPID, RootStart: r.rootStart,
					Path: r.path, Offset: r.offset, DiscardingOversized: r.discardingOversized, Identity: r.identity,
					Known: r.known, Active: r.active})
			}
			for _, r := range claudeReaders {
				cursors = append(cursors, transcriptCursor{Agent: "claude", RootPID: r.rootPID, RootStart: r.rootStart,
					Path: r.path, Offset: r.offset, DiscardingOversized: r.discardingOversized, Identity: r.identity,
					Known: r.known, Active: r.active})
			}
		}()
		timer := time.NewTimer(0)
		defer timer.Stop()
		var changed <-chan struct{}
		idlePolls := 0

		poll := func() (bool, bool) {
			processes, nextChanged := source()
			changed = nextChanged
			activity := false
			for pid, agent := range processes {
				start, startErr := processStartTime(pid)
				if startErr != nil || start == 0 {
					delete(codexReaders, pid)
					delete(claudeReaders, pid)
					continue
				}
				switch agent {
				case "codex":
					reader := codexReaders[pid]
					if reader == nil || reader.rootStart != start {
						reader = &codexTranscriptReader{
							rootPID: pid, rootStart: start, known: make(map[string]bool), active: make(map[string]bool),
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
					if reader == nil || reader.rootStart != start {
						reader = &claudeTranscriptReader{
							rootPID: pid, rootStart: start, known: make(map[string]bool), active: make(map[string]bool),
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
			case <-quit:
				return
			}
		}
	}()
	return transcriptRun{
		frames: frames,
		stop:   func() { stopOnce.Do(func() { close(stopped) }) },
		drain: func() []transcriptCursor {
			quitOnce.Do(func() { close(quit) })
			<-finished
			return cursors
		},
	}
}

func nonNilFlags(flags map[string]bool) map[string]bool {
	if flags == nil {
		return make(map[string]bool)
	}
	return flags
}
