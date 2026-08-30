package daemon

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

var validSessionID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,96}$`)

type Server struct {
	mu              sync.Mutex
	executable      string
	buildVersion    string
	protocolVersion int
	stateDir        string
	runtimeDir      string
	workspaceLeases map[string]workspaceLease
}

func NewServer() *Server {
	executable, _ := os.Executable()
	return &Server{executable: executable, stateDir: defaultWorkerStateDir(), workspaceLeases: make(map[string]workspaceLease)}
}

func NewServerWithBuildInfo(version string, protocolVersion int) *Server {
	server := NewServer()
	server.buildVersion = version
	server.protocolVersion = protocolVersion
	return server
}

func defaultWorkerStateDir() string {
	if state := os.Getenv("XDG_STATE_HOME"); state != "" {
		return filepath.Join(state, "relay", "workers")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join("/tmp", "relay-"+strconv.Itoa(os.Getuid()), "workers")
	}
	return filepath.Join(home, ".local", "state", "relay", "workers")
}

func (server *Server) Serve(socketPath string) error {
	if server.executable == "" {
		return errors.New("cannot locate relayd executable")
	}
	if err := EnsurePrivateRuntimeDir(filepath.Dir(socketPath)); err != nil {
		return err
	}
	server.runtimeDir = workerRuntimeDir(socketPath)
	if err := EnsurePrivateRuntimeDir(filepath.Dir(server.runtimeDir)); err != nil {
		return err
	}
	if err := EnsurePrivateRuntimeDir(server.runtimeDir); err != nil {
		return err
	}
	lockFile, err := OpenPrivateFile(socketPath+".lock", syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("relayd is already running at %s", socketPath)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	pidPath := socketPath + ".pid"
	pidFile, err := OpenPrivateFile(pidPath, syscall.O_CREAT|syscall.O_TRUNC|syscall.O_WRONLY)
	if err != nil {
		return err
	}
	if _, err := pidFile.WriteString(strconv.Itoa(os.Getpid()) + "\n"); err != nil {
		_ = pidFile.Close()
		return err
	}
	if err := pidFile.Close(); err != nil {
		return err
	}
	defer os.Remove(pidPath)
	if removeErr := os.Remove(socketPath); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
		return removeErr
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(socketPath)
	if err := os.Chmod(socketPath, 0o600); err != nil {
		return err
	}
	// Startup-only retention avoids a polling goroutine and bounds cleanup
	// work. Running panes are never eligible.
	_, _ = server.CollectGarbage(30*24*time.Hour, false)
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return acceptErr
		}
		if peerErr := RequirePeerUID(connection, os.Getuid()); peerErr != nil {
			_ = connection.Close()
			continue
		}
		go server.serveConnection(connection)
	}
}

func workerRuntimeDir(supervisorSocket string) string {
	candidate := filepath.Join(filepath.Dir(supervisorSocket), "relay-workers")
	// Darwin limits Unix socket paths to roughly 104 bytes and Linux to 108.
	// Leave room for the hashed worker socket name on long development paths.
	if len(filepath.Join(candidate, "01234567890123456789.sock")) < 100 {
		return candidate
	}
	digest := sha256.Sum256([]byte(supervisorSocket))
	return filepath.Join("/tmp", "relay-"+strconv.Itoa(os.Getuid()), fmt.Sprintf("%x", digest[:6]))
}

func (server *Server) serveConnection(connection net.Conn) {
	defer connection.Close()
	first, err := protocol.ReadFrame(connection)
	if err != nil || first.Type != protocol.Hello {
		return
	}
	var hello protocol.HelloPayload
	if err := protocol.DecodeJSON(first, &hello); err != nil || hello.Version != workerProtocolVersion {
		return
	}
	if hello.NodeMux {
		server.serveNodeMultiplex(connection)
		return
	}
	if !validSessionID.MatchString(hello.SessionID) {
		return
	}
	if hello.Probe {
		ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
			State: "ready", Version: server.buildVersion,
			ProtocolVersion: server.protocolVersion, SupervisorPID: os.Getpid(),
		})
		_ = protocol.NewWriter(connection).Write(ready)
		return
	}

	manifest, err := server.ensureWorker(hello)
	if err != nil {
		if !hello.EventOnly {
			status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
				State: "error", Message: err.Error(),
			})
			_ = protocol.NewWriter(connection).Write(status)
		}
		return
	}
	_ = server.recordCatalogEntry(hello, manifest)
	worker, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return
	}
	defer worker.Close()
	hello.WorkerToken = manifest.Token
	// Workers from before observe_events existed treat an observer as a normal
	// attachment. Start them at the persisted tail so the compatibility path
	// carries only the event snapshot, not terminal scrollback.
	if hello.ObserveEvents && manifest.LastSequence > hello.LastSeq {
		hello.LastSeq = manifest.LastSequence
	}
	workerHello, _ := protocol.JSONFrame(protocol.Hello, hello)
	if err := protocol.NewWriter(worker).Write(workerHello); err != nil {
		return
	}
	// Current workers capture transcript events themselves. Only compatibility
	// workers pass through the supervisor enrichment path; otherwise every
	// observer would duplicate process-tree and transcript polling.
	workerOwnsTranscripts := manifest.supports("transcript_events_v1")
	if (hello.ObserveEvents && !workerOwnsTranscripts) || !manifest.supports("event_cursor_v1") {
		eventPath := server.eventJournalPath(manifest.SessionID)
		if hello.ObserveEvents && manifest.supports("event_cursor_v1") {
			eventPath = filepath.Join(filepath.Dir(server.stateDir), "observed-events", manifest.SessionID+".jsonl")
		}
		serveObservedConnection(
			connection, worker, manifest, eventPath,
			hello.LastEventSeq, hello.ObserveEvents,
		)
		return
	}

	completed := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(worker, connection)
		if unix, ok := worker.(*net.UnixConn); ok {
			_ = unix.CloseWrite()
		}
		completed <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(connection, worker)
		completed <- struct{}{}
	}()
	<-completed
}

type multiplexedSession struct {
	connection       net.Conn
	terminalOnly     bool
	durableSessionID string
	capabilitiesMu   sync.RWMutex
	capabilitiesSeen bool
	viewportCommitV2 bool
	manifestCached   bool
	manifest         workerManifest
}

func (session *multiplexedSession) observeWorkerFrame(frame protocol.Frame) {
	if frame.Type != protocol.Status {
		return
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(frame, &status) != nil || status.State != "attached" {
		return
	}
	session.capabilitiesMu.Lock()
	session.capabilitiesSeen = true
	session.viewportCommitV2 = statusSupportsCapability(status.Capabilities, "viewport_commit_v2")
	session.capabilitiesMu.Unlock()
}

func statusSupportsCapability(capabilities []string, wanted string) bool {
	for _, capability := range capabilities {
		if capability == wanted {
			return true
		}
	}
	return false
}

func (session *multiplexedSession) supportsExactViewportCommit() (known bool, supported bool) {
	session.capabilitiesMu.RLock()
	known = session.capabilitiesSeen
	supported = session.viewportCommitV2
	session.capabilitiesMu.RUnlock()
	return known, supported
}

func (session *multiplexedSession) compatibilityManifest(path string) (workerManifest, error) {
	session.capabilitiesMu.RLock()
	if session.manifestCached {
		manifest := session.manifest
		session.capabilitiesMu.RUnlock()
		return manifest, nil
	}
	session.capabilitiesMu.RUnlock()

	manifest, err := loadManifest(path)
	if err != nil {
		return workerManifest{}, err
	}
	session.capabilitiesMu.Lock()
	if !session.manifestCached {
		session.manifest = manifest
		session.manifestCached = true
	} else {
		manifest = session.manifest
	}
	session.capabilitiesMu.Unlock()
	return manifest, nil
}

// serveNodeMultiplex turns one SSH channel into independent virtual protocol
// connections. Each virtual connection is fed back through serveConnection,
// so authentication, replay, compatibility, and worker isolation retain one
// implementation instead of growing a parallel code path.
func (server *Server) serveNodeMultiplex(connection net.Conn) {
	writer := protocol.NewWriter(connection)
	ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "ready", Version: server.buildVersion,
		ProtocolVersion: server.protocolVersion, SupervisorPID: os.Getpid(),
		Capabilities: []string{"node_mux_v1", "node_mux_v2", "viewport_commit_compat_v1", "viewport_commit_compat_v2"},
	})
	if writer.Write(ready) != nil {
		return
	}

	var sessionsMu sync.Mutex
	sessions := make(map[string]*multiplexedSession)
	closeSession := func(id string, expected *multiplexedSession) bool {
		sessionsMu.Lock()
		closedCurrentRoute := false
		if sessions[id] == expected {
			delete(sessions, id)
			closedCurrentRoute = true
		}
		sessionsMu.Unlock()
		_ = expected.connection.Close()
		return closedCurrentRoute
	}
	defer func() {
		sessionsMu.Lock()
		remaining := make([]*multiplexedSession, 0, len(sessions))
		for _, session := range sessions {
			remaining = append(remaining, session)
		}
		sessions = make(map[string]*multiplexedSession)
		sessionsMu.Unlock()
		for _, session := range remaining {
			_ = session.connection.Close()
		}
	}()

	for {
		envelope, err := protocol.ReadFrame(connection)
		if err != nil {
			return
		}
		// Node-level heartbeat frames stay outside virtual pane envelopes. This
		// lets one low-rate probe measure the shared SSH/multiplex path instead of
		// waking every remote worker.
		if envelope.Type == protocol.Ping {
			if writer.Write(protocol.Frame{Type: protocol.Pong, Payload: envelope.Payload}) != nil {
				return
			}
			continue
		}
		sessionID, inner, err := protocol.ParseHostEvent(envelope)
		if err != nil || !validSessionID.MatchString(sessionID) {
			return
		}
		if inner.Type == protocol.WorkspaceState {
			response := server.handleWorkspaceState(sessionID, inner.Payload)
			if writer.Write(protocol.HostEventFrame(sessionID, response)) != nil {
				return
			}
			continue
		}
		if inner.Type == protocol.Hello {
			var hello protocol.HelloPayload
			// node_mux_v2 separates the virtual route from the durable pane
			// identity. This lets an interactive terminal and an event-only
			// observer for the same pane coexist on one SSH stream.
			if protocol.DecodeJSON(inner, &hello) != nil ||
				!validSessionID.MatchString(hello.SessionID) || hello.NodeMux {
				return
			}
			clientSide, serverSide := net.Pipe()
			virtual := &multiplexedSession{
				connection: clientSide, terminalOnly: hello.TerminalOnly,
				durableSessionID: hello.SessionID,
			}
			sessionsMu.Lock()
			previous := sessions[sessionID]
			sessions[sessionID] = virtual
			sessionsMu.Unlock()
			if previous != nil {
				_ = previous.connection.Close()
			}
			go server.serveConnection(serverSide)
			go func(id string, session *multiplexedSession) {
				defer func() {
					// A pane worker deliberately disconnects a viewer whose bounded
					// output queue fell behind. On a dedicated SSH connection that EOF
					// naturally makes the macOS client reconnect. Under node_mux the
					// outer SSH stream remains healthy, so silently removing this
					// virtual route leaves input working while output and the next
					// shell prompt disappear forever. Tell only the current route to
					// reopen from its last acknowledged sequence. A route superseded by
					// a newer Hello must not close that replacement.
					if closeSession(id, session) {
						status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
							State:   "route_closed",
							Message: "Pane output route closed; replay is required.",
						})
						_ = writer.Write(protocol.HostEventFrame(id, status))
					}
				}()
				for {
					frame, readErr := protocol.ReadFrame(session.connection)
					if readErr != nil {
						return
					}
					session.observeWorkerFrame(frame)
					// Existing pane workers may predate terminal_only. Filter their
					// agent frames here so terminal restoration never waits for a
					// historical transcript replay.
					if session.terminalOnly && frame.Type == protocol.AgentEvent {
						continue
					}
					if writer.Write(protocol.HostEventFrame(id, frame)) != nil {
						return
					}
				}
			}(sessionID, virtual)
			if protocol.NewWriter(clientSide).Write(inner) != nil {
				closeSession(sessionID, virtual)
			}
			continue
		}

		sessionsMu.Lock()
		virtual := sessions[sessionID]
		sessionsMu.Unlock()
		if virtual == nil {
			continue
		}
		if inner.Type == protocol.ViewportCommit {
			known, exact := virtual.supportsExactViewportCommit()
			if !known || !exact {
				manifest, loadErr := virtual.compatibilityManifest(
					server.manifestPath(virtual.durableSessionID),
				)
				if loadErr == nil && manifest.supports("viewport_commit_v2") {
					// The status and manifest normally agree. Prefer the durable
					// capability if a commit raced the routed attached status.
					if protocol.NewWriter(virtual.connection).Write(inner) != nil {
						closeSession(sessionID, virtual)
					}
					continue
				}
				if loadErr != nil {
					if protocol.NewWriter(virtual.connection).Write(inner) != nil {
						closeSession(sessionID, virtual)
					}
					continue
				}
				generation, cols, rows, parseErr := protocol.ParseViewportCommit(inner)
				if parseErr == nil {
					// A freshly installed supervisor can repair presentation for
					// durable workers created by an older relayd. Run this outside
					// the node read loop so one slow TUI repaint never stalls the
					// other multiplexed panes or their heartbeat.
					go func(routeID string, worker workerManifest) {
						if commitLegacyWorkerViewport(worker, cols, rows) != nil {
							return
						}
						// Give the old worker's ordinary output route time to publish
						// the SIGWINCH repaint before the client uncovers its surface.
						time.Sleep(150 * time.Millisecond)
						_ = writer.Write(protocol.HostEventFrame(
							routeID, protocol.ViewportAckFrame(generation, 0),
						))
					}(sessionID, manifest)
					continue
				}
			}
		}
		if protocol.NewWriter(virtual.connection).Write(inner) != nil {
			closeSession(sessionID, virtual)
		}
	}
}

type observedWorkerFrame struct {
	frame protocol.Frame
	err   error
}

// The supervisor owns observer multiplexing so a newly installed relayd can
// recover structured agent threads from durable pane workers created by an
// older binary. Terminal output from their compatibility attachment is dropped
// before it reaches the macOS app.
func serveObservedConnection(
	connection, worker net.Conn,
	manifest workerManifest,
	eventPath string,
	lastEventSequence uint64,
	dropTerminalOutput bool,
) {
	workerFrames := make(chan observedWorkerFrame, 32)
	go func() {
		for {
			frame, err := protocol.ReadFrame(worker)
			workerFrames <- observedWorkerFrame{frame: frame, err: err}
			if err != nil {
				return
			}
		}
	}()
	clientDone := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(worker, connection)
		if unix, ok := worker.(*net.UnixConn); ok {
			_ = unix.CloseWrite()
		}
		clientDone <- struct{}{}
	}()

	transcriptFrames, stopTranscripts := observeAgentTranscripts(func() (map[int]string, <-chan struct{}) {
		return descendantAgentProcesses(manifest.ShellPID), nil
	})
	defer stopTranscripts()
	writer := protocol.NewWriter(connection)
	index, indexErr := sharedExternalEventIndex(eventPath)
	if indexErr == nil {
		defer releaseExternalEventIndex(eventPath, index)
		for _, frame := range index.framesAfter(lastEventSequence) {
			if writer.Write(frame) != nil {
				return
			}
		}
	}
	for {
		select {
		case result := <-workerFrames:
			if result.err != nil {
				return
			}
			if result.frame.Type == protocol.Output && dropTerminalOutput {
				continue
			}
			if result.frame.Type == protocol.AgentEvent && indexErr == nil {
				result.frame = index.index(result.frame.Payload)
			}
			if writer.Write(result.frame) != nil {
				return
			}
		case frame, ok := <-transcriptFrames:
			if !ok {
				transcriptFrames = nil
				continue
			}
			if indexErr == nil {
				frame = index.index(frame.Payload)
			}
			if writer.Write(frame) != nil {
				return
			}
		case <-clientDone:
			return
		}
	}
}

func (server *Server) eventJournalPath(sessionID string) string {
	return filepath.Join(filepath.Dir(server.stateDir), "events", sessionID+".jsonl")
}

func (server *Server) ensureWorker(hello protocol.HelloPayload) (workerManifest, error) {
	server.mu.Lock()
	defer server.mu.Unlock()
	manifestPath := server.manifestPath(hello.SessionID)
	if manifest, err := loadManifest(manifestPath); err == nil {
		if state, liveErr := server.workerState(manifest); liveErr == nil && state == "ready" {
			return manifest, nil
		} else if liveErr == nil && state == "exited" {
			server.stopValidatedWorker(manifest)
		}
		server.cleanStaleWorker(manifestPath, manifest)
	} else if !errors.Is(err, os.ErrNotExist) {
		removeManifest(manifestPath)
	}
	if hello.EventOnly || hello.ObserveEvents {
		return workerManifest{}, errors.New("Relay pane worker is not running")
	}
	return server.startWorker(hello, manifestPath)
}

func (server *Server) workerState(manifest workerManifest) (string, error) {
	if err := validateWorkerIdentity(manifest); err != nil {
		return "", err
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, 300*time.Millisecond)
	if err != nil {
		return "", err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(500 * time.Millisecond))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID,
		Probe: true, WorkerToken: manifest.Token,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return "", err
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return "", errors.New("worker probe failed")
	}
	var status protocol.StatusPayload
	if err := protocol.DecodeJSON(frame, &status); err != nil || status.WorkerPID != manifest.WorkerPID {
		return "", errors.New("worker identity handshake failed")
	}
	return status.State, nil
}

func (server *Server) startWorker(hello protocol.HelloPayload, manifestPath string) (workerManifest, error) {
	token, err := newWorkerToken()
	if err != nil {
		return workerManifest{}, err
	}
	workingDirectory := server.parentWorkingDirectory(hello.ParentSessionID)
	socketPath := server.workerSocketPath(hello.SessionID, token)
	logDir := filepath.Join(server.stateDir, "logs")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return workerManifest{}, err
	}
	logFile, err := os.OpenFile(filepath.Join(logDir, hello.SessionID+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return workerManifest{}, err
	}
	defer logFile.Close()
	arguments := []string{
		"worker",
		"--socket", socketPath,
		"--manifest", manifestPath,
		"--session", hello.SessionID,
		"--cols", strconv.Itoa(int(hello.Cols)),
		"--rows", strconv.Itoa(int(hello.Rows)),
	}
	workerEnvironment := append(os.Environ(), "RELAY_WORKER_TOKEN="+token)
	if hello.Command != "" {
		workerEnvironment = append(workerEnvironment, "RELAY_WORKER_COMMAND_B64="+base64.StdEncoding.EncodeToString([]byte(hello.Command)))
	}
	if workingDirectory != "" {
		workerEnvironment = append(workerEnvironment, "RELAY_WORKER_CWD_B64="+base64.StdEncoding.EncodeToString([]byte(workingDirectory)))
	}
	child := exec.Command(server.executable, arguments...)
	child.Env = workerEnvironment
	child.Stdin = nil
	child.Stdout = logFile
	child.Stderr = logFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return workerManifest{}, err
	}
	_ = child.Process.Release()
	for attempt := 0; attempt < 120; attempt++ {
		time.Sleep(25 * time.Millisecond)
		manifest, loadErr := loadManifest(manifestPath)
		if loadErr != nil || manifest.Token != token {
			continue
		}
		if state, liveErr := server.workerState(manifest); liveErr == nil && state == "ready" {
			return manifest, nil
		}
	}
	return workerManifest{}, fmt.Errorf("pane worker did not start (pid %d)", child.Process.Pid)
}

func (server *Server) parentWorkingDirectory(parentSessionID string) string {
	if !validSessionID.MatchString(parentSessionID) {
		return ""
	}
	parent, err := loadManifest(server.manifestPath(parentSessionID))
	if err != nil || validateWorkerIdentity(parent) != nil {
		return ""
	}
	if directory, err := processWorkingDirectory(parent.ShellPID); err == nil {
		return directory
	}
	return parent.WorkingDirectory
}

func (server *Server) stopValidatedWorker(manifest workerManifest) {
	if validateWorkerIdentity(manifest) != nil {
		return
	}
	if process, err := os.FindProcess(manifest.WorkerPID); err == nil {
		_ = process.Signal(syscall.SIGTERM)
	}
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(manifest.SocketPath); errors.Is(err, os.ErrNotExist) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (server *Server) TerminatePane(sessionID string) error {
	if !validSessionID.MatchString(sessionID) {
		return errors.New("invalid pane session ID")
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	manifest, err := loadManifest(server.manifestPath(sessionID))
	if err != nil {
		return errors.New("pane is not present on this node")
	}
	if err := validateWorkerIdentity(manifest); err != nil {
		return errors.New("refusing to signal an unvalidated pane worker")
	}
	process, err := os.FindProcess(manifest.WorkerPID)
	if err != nil {
		return err
	}
	if err := process.Signal(syscall.SIGTERM); err != nil {
		return err
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, statErr := os.Stat(manifest.SocketPath); errors.Is(statErr, os.ErrNotExist) {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("pane worker did not terminate")
}

func (server *Server) ForgetPane(sessionID string) error {
	if !validSessionID.MatchString(sessionID) {
		return errors.New("invalid pane session ID")
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil {
		return errors.New("pane is not in this node's catalog")
	}
	entry, exists := catalog.Panes[sessionID]
	nodeID, _ := currentNodeIdentity()
	if !exists || entry.NodeID != nodeID {
		return errors.New("pane is not in this node's catalog")
	}
	manifestPath := server.manifestPath(sessionID)
	if manifest, loadErr := loadManifest(manifestPath); loadErr == nil {
		if validateWorkerIdentity(manifest) == nil {
			return errors.New("pane is still running; terminate it first")
		}
		removeManifest(manifestPath)
	}
	delete(catalog.Panes, sessionID)
	catalog.Revision++
	return storeCatalog(server.catalogPath(), catalog)
}

func (server *Server) cleanStaleWorker(manifestPath string, manifest workerManifest) {
	removeManifest(manifestPath)
	if filepath.Dir(filepath.Clean(manifest.SocketPath)) == filepath.Clean(server.runtimeDir) {
		_ = os.Remove(manifest.SocketPath)
	}
}

func (server *Server) manifestPath(sessionID string) string {
	return filepath.Join(server.stateDir, sessionID+".json")
}

func (server *Server) workerSocketPath(sessionID, token string) string {
	digest := sha256.Sum256([]byte(sessionID + "\x00" + token))
	return filepath.Join(server.runtimeDir, fmt.Sprintf("%x.sock", digest[:10]))
}
