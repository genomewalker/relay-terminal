package daemon

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type WorkerConfig struct {
	SocketPath       string
	ManifestPath     string
	SessionID        string
	Token            string
	Command          string
	WorkingDirectory string
	Cols             uint16
	Rows             uint16
}

func ServeWorker(config WorkerConfig) error {
	if !validSessionID.MatchString(config.SessionID) || config.Token == "" {
		return errors.New("invalid worker identity")
	}
	if err := os.MkdirAll(filepath.Dir(config.SocketPath), 0o700); err != nil {
		return err
	}
	if err := os.Remove(config.SocketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := net.Listen("unix", config.SocketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(config.SocketPath)
	defer removeManifest(config.ManifestPath)
	if err := os.Chmod(config.SocketPath, 0o600); err != nil {
		return err
	}

	session, err := startSession(config.SessionID, config.Command, config.WorkingDirectory, config.Cols, config.Rows)
	if err != nil {
		return err
	}
	eventPath := filepath.Join(filepath.Dir(filepath.Dir(config.ManifestPath)), "events", config.SessionID+".jsonl")
	if err := session.enableEventJournal(eventPath); err != nil {
		_ = session.signal(syscall.SIGTERM)
		return err
	}
	transcriptFrames, stopTranscripts := observeAgentTranscripts(session.agentProcessSnapshot)
	defer stopTranscripts()
	go forwardTranscriptEvents(session, transcriptFrames)
	bootID, err := nodeBootID()
	if err != nil {
		_ = session.signal(syscall.SIGTERM)
		return err
	}
	workerStartTime, err := processStartTime(os.Getpid())
	if err != nil {
		_ = session.signal(syscall.SIGTERM)
		return err
	}
	manifest := workerManifest{
		Version: workerProtocolVersion, SessionID: config.SessionID,
		WorkerPID: os.Getpid(), WorkerStartTime: workerStartTime,
		ShellPID: session.processID(), NodeBootID: bootID,
		SocketPath: config.SocketPath, Token: config.Token,
		Command: config.Command, WorkingDirectory: config.WorkingDirectory,
		State: "running", Capabilities: []string{"input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1", "viewport_attach_v1", "viewport_attach_v2", "viewport_commit_v1", "viewport_commit_v2", "client_count_v1", "terminal_mode_state_v1"}, CreatedAt: time.Now().UTC(),
	}
	if err := storeManifest(config.ManifestPath, manifest); err != nil {
		_ = session.signal(syscall.SIGTERM)
		return err
	}

	stopped := make(chan struct{})
	persistenceDone := make(chan struct{})
	defer func() {
		close(stopped)
		<-persistenceDone
	}()
	go func() {
		defer close(persistenceDone)
		persistWorkerState(stopped, config.ManifestPath, manifest, session)
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	go func() {
		select {
		case <-signals:
			session.terminate()
			_ = listener.Close()
		case <-stopped:
		}
	}()

	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if errors.Is(acceptErr, net.ErrClosed) {
				return nil
			}
			return acceptErr
		}
		go serveWorkerConnection(connection, config, session)
	}
}

func forwardTranscriptEvents(session *Session, frames <-chan protocol.Frame) {
	for frame := range frames {
		if frame.Type == protocol.AgentEvent {
			session.agentEvent(frame.Payload)
		}
	}
}

func persistWorkerState(stopped <-chan struct{}, path string, manifest workerManifest, session *Session) {
	// The manifest is recovery metadata, not a live telemetry stream. Persist
	// only changed cursors and coalesce them to avoid waking every idle worker
	// once per second.
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	lastSequence := manifest.LastSequence
	lastState := manifest.State
	unchangedPolls := 0
	for {
		select {
		case <-stopped:
			return
		case <-ticker.C:
			sequence, eventSequence, exited, exitCode := session.snapshot()
			state := "running"
			if exited {
				state = "exited"
			}
			if sequence == lastSequence && eventSequence == manifest.LastEventSequence && state == lastState {
				unchangedPolls++
				ticker.Reset(workerManifestPollInterval(unchangedPolls))
				continue
			}
			unchangedPolls = 0
			manifest.LastSequence = sequence
			manifest.LastEventSequence = eventSequence
			manifest.State = state
			manifest.ExitCode = exitCode
			_ = storeManifest(path, manifest)
			lastSequence = sequence
			lastState = state
			ticker.Reset(workerManifestPollInterval(unchangedPolls))
		}
	}
}

func workerManifestPollInterval(unchangedPolls int) time.Duration {
	if unchangedPolls >= 2 {
		return 30 * time.Second
	}
	return 5 * time.Second
}

type viewportOperation struct {
	generation uint64
	cols       uint16
	rows       uint16
	commit     bool
}

func enqueueViewportOperation(mailbox chan viewportOperation, operation viewportOperation) {
	select {
	case mailbox <- operation:
		return
	default:
	}

	// A queued commit is an atomic presentation boundary and must not be
	// displaced by a later ordinary animation resize. A new commit supersedes
	// any unstarted operation; ordinary resizes only replace ordinary resizes.
	select {
	case pending := <-mailbox:
		if pending.commit && !operation.commit {
			operation = pending
		}
	default:
	}
	select {
	case mailbox <- operation:
	default:
	}
}

func serveWorkerConnection(connection net.Conn, config WorkerConfig, session *Session) {
	defer connection.Close()
	first, err := protocol.ReadFrame(connection)
	if err != nil || first.Type != protocol.Hello {
		return
	}
	var hello protocol.HelloPayload
	if err := protocol.DecodeJSON(first, &hello); err != nil ||
		hello.Version != workerProtocolVersion || hello.SessionID != config.SessionID ||
		hello.WorkerToken != config.Token {
		return
	}
	writer := protocol.NewWriter(connection)
	if hello.Probe {
		_, _, exited, exitCode := session.snapshot()
		state := "ready"
		if exited {
			state = "exited"
		}
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
			State: state, ExitCode: exitCode, WorkerPID: os.Getpid(),
		})
		_ = writer.Write(status)
		return
	}
	if hello.EventOnly {
		// One-shot hook commands close after one frame; provider-native adapters
		// keep the same authenticated connection open and stream JSONL events.
		for {
			event, readErr := protocol.ReadFrame(connection)
			if readErr != nil {
				return
			}
			if event.Type != protocol.AgentEvent {
				return
			}
			session.agentEvent(event.Payload)
		}
	}
	if hello.ObserveEvents {
		serveAgentObserver(connection, writer, session, hello.LastEventSeq)
		return
	}
	controlGranted := session.acquireControl(hello.ClientID)
	gracefulDetach := false
	repaintAfterSequence := uint64(0)
	attachRedrew := false
	if controlGranted {
		defer func() { session.releaseControl(hello.ClientID, gracefulDetach) }()
		// A replay is cursor-addressed for the PTY grid that produced it. Apply
		// the native pane geometry and capture its SIGWINCH redraw before taking
		// the attachment snapshot.
		repaintAfterSequence, attachRedrew = session.resizeForAttach(hello.Cols, hello.Rows)
	}

	viewer, replay, outputReset, eventReset, clientCount := session.attach(
		hello.LastSeq, hello.LastEventSeq, !hello.TerminalOnly,
	)
	defer session.detach(viewer)
	attached, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "attached", WorkerPID: os.Getpid(), Capabilities: []string{"input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1", "viewport_attach_v1", "viewport_attach_v2", "viewport_commit_v1", "viewport_commit_v2", "client_count_v1", "terminal_mode_state_v1"},
		OutputReset: outputReset, EventReset: eventReset,
		ControlGranted: &controlGranted, ClientCount: clientCount,
	})
	if err := writer.Write(attached); err != nil {
		return
	}
	if attachRedrew && reconnectRepaintNeedsBarrier(replay, repaintAfterSequence, hello.Rows) {
		// SIGWINCH repaints from primary-screen TUIs such as Codex and Claude
		// are usually cursor-addressed deltas. Make this connection's captured
		// repaint authoritative so a local renderer cannot retain stale cells
		// from its previous presentation. This frame is deliberately not added
		// to the session ring or broadcast to other attached clients.
		// Sequence zero is presentation-only. It cannot move the resume cursor
		// backwards or resurrect an invalid high cursor after output_reset.
		if err := writer.Write(protocol.OutputFrame(0, []byte("\x1b[2J\x1b[H"))); err != nil {
			return
		}
	}
	for _, frame := range replay {
		if err := writer.Write(frame); err != nil {
			return
		}
	}
	caughtUp, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "caught_up"})
	if err := writer.Write(caughtUp); err != nil {
		return
	}
	stopWriter := make(chan struct{})
	defer close(stopWriter)
	writerDone := make(chan struct{})
	viewportOperations := make(chan viewportOperation, 1)
	go func() {
		defer close(writerDone)
		for {
			select {
			case frame := <-viewer.frames:
				if err := writer.Write(frame); err != nil {
					return
				}
			case <-viewer.lagged:
				_ = connection.Close()
				return
			case <-stopWriter:
				return
			}
		}
	}()
	// Resize repaint detection may wait briefly for a TUI's output. Keep every
	// geometry operation off the connection reader so keystrokes and heartbeats
	// are never queued behind either that wait or a concurrent reconnect commit.
	// The one-slot mailbox coalesces animation bursts to their newest useful grid.
	go func() {
		for {
			select {
			case operation := <-viewportOperations:
				if operation.commit {
					sequence, resizeErr := session.resizeForViewportCommit(
						operation.cols, operation.rows,
					)
					if resizeErr == nil {
						_ = writer.Write(protocol.ViewportAckFrame(operation.generation, sequence))
					}
				} else {
					_ = session.resize(operation.cols, operation.rows)
				}
			case <-stopWriter:
				return
			}
		}
	}()

	for {
		frame, readErr := protocol.ReadFrame(connection)
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				_ = readErr
			}
			return
		}
		switch frame.Type {
		case protocol.Input:
			if controlGranted {
				_ = session.input(frame.Payload)
			}
		case protocol.InputV2:
			clientID, sequence, data, parseErr := protocol.ParseInputV2(frame)
			if controlGranted && parseErr == nil && session.acknowledgedInput(clientID, sequence, data) == nil {
				_ = writer.Write(protocol.InputAckFrame(clientID, sequence))
			}
		case protocol.Resize:
			cols, rows, parseErr := protocol.ParseResize(frame)
			if controlGranted && parseErr == nil {
				enqueueViewportOperation(viewportOperations, viewportOperation{
					cols: cols, rows: rows,
				})
			}
		case protocol.ViewportCommit:
			generation, cols, rows, parseErr := protocol.ParseViewportCommit(frame)
			if controlGranted && parseErr == nil {
				enqueueViewportOperation(viewportOperations, viewportOperation{
					generation: generation, cols: cols, rows: rows, commit: true,
				})
			}
		case protocol.Ping:
			_ = writer.Write(protocol.Frame{Type: protocol.Pong})
		case protocol.Detach:
			gracefulDetach = true
			return
		case protocol.AgentEvent:
			session.agentEvent(frame.Payload)
		}
		select {
		case <-writerDone:
			return
		default:
		}
	}
}

// A resize can coincide with unrelated streaming output. Only add a clear
// barrier when the post-resize bytes look like a cursor-addressed screen
// repaint; ordinary shell/build/tail output must retain its scrollback. A TUI
// that already emitted its own clear is self-contained and needs no help.
func reconnectRepaintNeedsBarrier(frames []protocol.Frame, afterSequence uint64, rows uint16) bool {
	data := make([]byte, 0, 4096)
	for _, frame := range frames {
		sequence, output, err := protocol.ParseOutput(frame)
		if err != nil || sequence <= afterSequence {
			continue
		}
		data = append(data, output...)
	}
	if len(data) < 256 || bytes.Contains(data, []byte("\x1b[2J")) ||
		bytes.Contains(data, []byte("\x1b[3J")) || bytes.Contains(data, []byte("\x1bc")) {
		return false
	}
	addressedRows := cursorAddressedRows(data)
	requiredRows := 3
	if rows > 0 && rows < 5 {
		requiredRows = 2
	}
	return len(addressedRows) >= requiredRows
}

func cursorAddressedRows(data []byte) map[uint16]struct{} {
	addressed := make(map[uint16]struct{})
	for index := 0; index+2 < len(data); index++ {
		if data[index] != 0x1b || data[index+1] != '[' {
			continue
		}
		cursor := index + 2
		row := uint32(0)
		hasRow := false
		for cursor < len(data) && data[cursor] >= '0' && data[cursor] <= '9' {
			hasRow = true
			row = row*10 + uint32(data[cursor]-'0')
			if row > uint32(^uint16(0)) {
				break
			}
			cursor++
		}
		if !hasRow {
			row = 1
		}
		if cursor >= len(data) || (data[cursor] != ';' && data[cursor] != 'H' && data[cursor] != 'f') {
			continue
		}
		for cursor < len(data) && data[cursor] != 'H' && data[cursor] != 'f' {
			if data[cursor] != ';' && (data[cursor] < '0' || data[cursor] > '9') {
				break
			}
			cursor++
		}
		if cursor < len(data) && (data[cursor] == 'H' || data[cursor] == 'f') && row > 0 && row <= uint32(^uint16(0)) {
			addressed[uint16(row)] = struct{}{}
		}
	}
	return addressed
}

func serveAgentObserver(connection net.Conn, writer *protocol.Writer, session *Session, lastEventSequence uint64) {
	observer, snapshot, eventReset := session.observeAgents(lastEventSequence)
	defer session.detachAgentObserver(observer)
	attached, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "attached", WorkerPID: os.Getpid(), Capabilities: []string{"event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1"},
		EventReset: eventReset,
	})
	if writer.Write(attached) != nil {
		return
	}
	for _, frame := range snapshot {
		if writer.Write(frame) != nil {
			return
		}
	}
	closed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, connection)
		close(closed)
	}()
	for {
		select {
		case frame := <-observer.frames:
			if writer.Write(frame) != nil {
				return
			}
		case <-observer.lagged:
			return
		case <-closed:
			return
		}
	}
}
