package daemon

import (
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
	codexFrames, stopCodex := observeCodexTranscript(session.processID())
	claudeFrames, stopClaude := observeClaudeTranscript(session.processID())
	defer stopCodex()
	defer stopClaude()
	go forwardTranscriptEvents(session, codexFrames)
	go forwardTranscriptEvents(session, claudeFrames)
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
		State: "running", Capabilities: []string{"input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1"}, CreatedAt: time.Now().UTC(),
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
				continue
			}
			manifest.LastSequence = sequence
			manifest.LastEventSequence = eventSequence
			manifest.State = state
			manifest.ExitCode = exitCode
			_ = storeManifest(path, manifest)
			lastSequence = sequence
			lastState = state
		}
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
	if controlGranted {
		defer session.releaseControl(hello.ClientID)
	}

	viewer, replay, outputReset, eventReset := session.attach(hello.LastSeq, hello.LastEventSeq)
	defer session.detach(viewer)
	attached, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "attached", WorkerPID: os.Getpid(), Capabilities: []string{"input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1"},
		OutputReset: outputReset, EventReset: eventReset,
		ControlGranted: &controlGranted,
	})
	if err := writer.Write(attached); err != nil {
		return
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
				_ = session.resize(cols, rows)
			}
		case protocol.Ping:
			_ = writer.Write(protocol.Frame{Type: protocol.Pong})
		case protocol.Detach:
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
