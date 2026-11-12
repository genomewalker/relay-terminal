package daemon

import (
	"errors"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type WorkerConfig struct {
	SocketPath         string
	ManifestPath       string
	SessionID          string
	Token              string
	Command            string
	WorkingDirectory   string
	Cols               uint16
	Rows               uint16
	RotationControlled bool
	// Resume is set when this image was exec'd by a previous worker image of
	// the same process, which handed over its PTY, socket and state.
	Resume *WorkerResume
}

// WorkerResume names the descriptors a re-executing worker left open.
type WorkerResume struct {
	StateFD    int
	PTYFD      int
	ListenerFD int
	ShellPID   int
	Operation  string
}

var workerCapabilities = []string{"host_rotation_v1", "host_rotation_text_v1", "host_rotation_credentials_v1", "native_rotation_bridge_v1", "input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1", "viewport_attach_v1", "viewport_attach_v2", "viewport_commit_v1", "viewport_commit_v2", "attach_repaint_v1", "attach_repaint_v2", "client_count_v1", "terminal_mode_state_v1", "program_status_snapshot_v1", "program_status_reply_v1", "program_status_negotiation_v1", "automation_input_v1", freshRedrawCapability, workerReexecCapability}

// workerRuntime is one worker process's serving state. Everything here except
// the session is either rebuilt by the next image or restarted after a failed
// handoff; see worker_reexec.go.
type workerRuntime struct {
	config        WorkerConfig
	listener      *net.UnixListener
	session       *Session
	manifest      workerManifest
	newSupervisor func() *hostRotationSupervisor

	transcripts   transcriptRun
	forwarded     chan struct{}
	persistStop   chan struct{}
	persistDone   chan struct{}
	handoffMu     sync.Mutex
	handoff       atomic.Bool
	acceptResumed chan struct{}
}

func ServeWorker(config WorkerConfig) error {
	if !validSessionID.MatchString(config.SessionID) || config.Token == "" {
		return errors.New("invalid worker identity")
	}
	runtime := &workerRuntime{config: config, acceptResumed: make(chan struct{}, 1)}
	var resumed *workerReexecState
	if config.Resume != nil {
		listener, session, state, err := resumeWorker(config)
		if err != nil {
			return err
		}
		runtime.listener, runtime.session, resumed = listener, session, state
	} else {
		if err := os.MkdirAll(filepath.Dir(config.SocketPath), 0o700); err != nil {
			return err
		}
		if err := os.Remove(config.SocketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: config.SocketPath, Net: "unix"})
		if err != nil {
			return err
		}
		runtime.listener = listener
		if err := os.Chmod(config.SocketPath, 0o600); err != nil {
			_ = listener.Close()
			return err
		}
		session, err := startSession(config.SessionID, config.Command, config.WorkingDirectory, config.Cols, config.Rows)
		if err != nil {
			_ = listener.Close()
			return err
		}
		runtime.session = session
	}
	listener, session := runtime.listener, runtime.session
	// The listener is unlinked explicitly below, never by Close, so a handoff
	// that keeps it open can never remove the path under the next image.
	listener.SetUnlinkOnClose(false)
	defer listener.Close()
	defer os.Remove(config.SocketPath)
	defer removeManifest(config.ManifestPath)

	session.rotationControlled = config.RotationControlled
	session.rotationGuardDirectory = filepath.Join(filepath.Dir(config.ManifestPath), "rotation-input", config.SessionID)
	eventPath := filepath.Join(filepath.Dir(filepath.Dir(config.ManifestPath)), "events", config.SessionID+".jsonl")
	var journalErr error
	if resumed != nil {
		journalErr = session.reopenEventJournal(eventPath)
	} else {
		journalErr = session.enableEventJournal(eventPath)
	}
	if journalErr != nil {
		if resumed != nil {
			// The PTY must outlive a journal failure after a handoff: exiting
			// would hang up the shell. Record it as any later append failure is.
			session.noteJournalFailure(journalErr)
		} else {
			_ = session.signal(syscall.SIGTERM)
			return journalErr
		}
	}
	bootID, err := nodeBootID()
	if err == nil {
		var workerStartTime uint64
		workerStartTime, err = processStartTime(os.Getpid())
		runtime.manifest = workerManifest{
			Version: workerProtocolVersion, SessionID: config.SessionID,
			WorkerPID: os.Getpid(), WorkerStartTime: workerStartTime,
			ShellPID: session.processID(), NodeBootID: bootID,
			SocketPath: config.SocketPath, Token: config.Token,
			Command: config.Command, WorkingDirectory: config.WorkingDirectory,
			State: "running", Capabilities: workerCapabilities, CreatedAt: time.Now().UTC(),
		}
	}
	if config.Resume != nil {
		// Recorded even when the state was unusable: the image did change.
		runtime.manifest.ReexecOperation = config.Resume.Operation
	}
	if resumed != nil {
		runtime.manifest.CreatedAt = resumed.ManifestCreatedAt
		runtime.manifest.LastSequence, runtime.manifest.LastEventSequence = resumed.Sequence, resumed.EventSequence
	}
	if err == nil {
		err = storeManifest(config.ManifestPath, runtime.manifest)
	}
	if err != nil && config.Resume == nil {
		_ = session.signal(syscall.SIGTERM)
		return err
	}

	runtime.newSupervisor = func() *hostRotationSupervisor {
		return newHostRotationSupervisorWithDriver(
			filepath.Join(filepath.Dir(config.ManifestPath), "rotation-supervision", config.SessionID+".json"), evaluateHostRotation,
			nativeHostRotationFinalizer(filepath.Dir(config.ManifestPath)), filepath.Dir(config.ManifestPath),
			nativeHostRotationTransactionDriver(session, filepath.Dir(config.ManifestPath)),
			nativeHostRotationPreparer(filepath.Dir(config.ManifestPath)))
	}
	session.mu.Lock()
	session.hostRotation = runtime.newSupervisor()
	session.workerUpgrade = runtime.serveUpgrade
	session.mu.Unlock()
	defer func() {
		session.mu.Lock()
		supervisor := session.hostRotation
		session.mu.Unlock()
		supervisor.close()
	}()
	var seed []transcriptCursor
	if resumed != nil {
		seed = resumed.Transcripts
	}
	runtime.startTranscripts(seed)
	defer func() { runtime.transcripts.stop() }()
	runtime.startPersistence()
	defer runtime.stopPersistence()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	served := make(chan struct{})
	defer close(served)
	go func() {
		select {
		case <-signals:
			session.terminate()
			_ = listener.Close()
		case <-served:
		}
	}()

	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if runtime.handoff.Load() {
				// A handoff stopped accepting; connections wait in the backlog
				// for the next image, or for this one if exec fails.
				<-runtime.acceptResumed
				continue
			}
			if errors.Is(acceptErr, net.ErrClosed) {
				return nil
			}
			return acceptErr
		}
		go serveWorkerConnection(connection, config, session)
	}
}

func (runtime *workerRuntime) startTranscripts(seed []transcriptCursor) {
	runtime.transcripts = observeAgentTranscriptsFrom(runtime.session.agentProcessSnapshot, seed)
	runtime.forwarded = make(chan struct{})
	go func(frames <-chan protocol.Frame, done chan struct{}) {
		defer close(done)
		forwardTranscriptEvents(runtime.session, frames)
	}(runtime.transcripts.frames, runtime.forwarded)
}

func (runtime *workerRuntime) startPersistence() {
	runtime.persistStop, runtime.persistDone = make(chan struct{}), make(chan struct{})
	go func(stop, done chan struct{}, manifest workerManifest) {
		defer close(done)
		persistWorkerState(stop, runtime.config.ManifestPath, manifest, runtime.session)
	}(runtime.persistStop, runtime.persistDone, runtime.manifest)
}

func (runtime *workerRuntime) stopPersistence() {
	if runtime.persistStop == nil {
		return
	}
	close(runtime.persistStop)
	<-runtime.persistDone
	runtime.persistStop = nil
}

// Probes advertise only what an orchestrator needs before talking to a worker
// whose manifest may predate the capability list (recovered workers).
func probeCapabilities(session *Session) []string {
	if session.reexecCapable() {
		return []string{workerReexecCapability}
	}
	return nil
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
	if hello.NativeRotationBridge {
		serveNativeRotationBridge(connection, writer, session, config.SessionID)
		return
	}
	if len(hello.HostRotation) > 0 {
		serveHostRotationRequest(connection, writer, hello, session, config)
		return
	}
	if len(hello.PromptEditor) > 0 {
		servePromptEditorRequest(connection, writer, hello, session, func() (PromptOwnerBinding, error) {
			return ReadVerifiedPromptOwnerBinding(config.SessionID)
		}, validatePromptEditorCapability)
		return
	}
	if hello.Probe {
		_, _, exited, exitCode := session.snapshot()
		state := "ready"
		if exited {
			state = "exited"
		}
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
			State: state, ExitCode: exitCode, WorkerPID: os.Getpid(),
			ReexecOperation: session.reexecOperationID(), Capabilities: probeCapabilities(session),
			ExecutableSHA256: runningImageDigest(),
		})
		_ = writer.Write(status)
		return
	}
	if len(hello.WorkerUpgrade) > 0 {
		session.mu.Lock()
		upgrade := session.workerUpgrade
		session.mu.Unlock()
		if upgrade == nil {
			refused, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
				State: "refused", Message: "this worker cannot re-execute", WorkerPID: os.Getpid()})
			_ = writer.Write(refused)
			return
		}
		upgrade(writer, hello.WorkerUpgrade)
		return
	}
	if hello.GuardedInput {
		state := "refused"
		if err := session.guardedRotationInput(hello.GuardedOperationID, hello.GuardedAgentPID,
			hello.GuardedProcessStart, hello.GuardedText); err == nil {
			state = "accepted"
		}
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: state, WorkerPID: os.Getpid()})
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
	if controlGranted {
		defer func() { session.releaseControl(hello.ClientID, gracefulDetach) }()
		// A replay is cursor-addressed for the PTY grid that produced it. Apply
		// the native pane geometry and capture its SIGWINCH redraw before taking
		// the attachment snapshot.
		session.resizeForAttach(
			hello.Cols,
			hello.Rows,
			hello.LastSeq == 0 || hello.RepaintPulse || session.needsFreshAttachReplay(hello.LastSeq),
		)
	}

	viewer, replay, outputReset, eventReset, clientCount := session.attachWithProgramStatus(
		hello.LastSeq, hello.LastEventSeq, !hello.TerminalOnly, hello.ObserveProgramStatus,
	)
	defer session.detach(viewer)
	attached, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "attached", WorkerPID: os.Getpid(), Capabilities: []string{"input_ack_v1", "event_cursor_v1", "state_snapshot_v1", "native_agent_stream_v1", "transcript_events_v1", "input_lease_v1", "viewport_attach_v1", "viewport_attach_v2", "viewport_commit_v1", "viewport_commit_v2", "attach_repaint_v1", "attach_repaint_v2", "client_count_v1", "terminal_mode_state_v1", "program_status_snapshot_v1", "program_status_reply_v1", "program_status_negotiation_v1", "automation_input_v1", freshRedrawCapability},
		OutputReset: outputReset, EventReset: eventReset,
		ControlGranted: &controlGranted, ClientCount: clientCount,
	})
	if err := writer.Write(attached); err != nil {
		return
	}
	if err := writeTerminalReplay(writer, replay); err != nil {
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
		case protocol.Capabilities:
			if len(frame.Payload) > 256 {
				continue
			}
			var negotiation struct {
				ObserveProgramStatus *bool `json:"observe_program_status"`
			}
			if protocol.DecodeJSON(frame, &negotiation) == nil && negotiation.ObserveProgramStatus != nil {
				session.setProgramStatusObservation(viewer, *negotiation.ObserveProgramStatus)
			}
		case protocol.Input:
			if controlGranted {
				_ = session.input(frame.Payload)
			}
		case protocol.InputV2, protocol.AutomationInputV2:
			clientID, sequence, data, parseErr := protocol.ParseInputV2(frame)
			automation := frame.Type == protocol.AutomationInputV2
			if controlGranted && parseErr == nil && session.acknowledgedInputFrom(clientID, sequence, data, automation) == nil {
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
		case protocol.FreshRedraw:
			if controlGranted {
				go session.freshRedraw(viewer)
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

// Replay is an ordered terminal stream, not a complete screen image. Preserve
// bytes and sequence numbers, including partial CSI sequences across frames.
// Only the application may clear its screen; cursor-addressed rows do not
// establish that a repaint replaces every visible cell.
func writeTerminalReplay(writer *protocol.Writer, frames []protocol.Frame) error {
	for _, frame := range frames {
		if err := writer.Write(frame); err != nil {
			return err
		}
	}
	caughtUp, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "caught_up"})
	if err != nil {
		return err
	}
	return writer.Write(caughtUp)
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
