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
	mu         sync.Mutex
	executable string
	stateDir   string
	runtimeDir string
}

func NewServer() *Server {
	executable, _ := os.Executable()
	return &Server{executable: executable, stateDir: defaultWorkerStateDir()}
}

func defaultWorkerStateDir() string {
	if state := os.Getenv("XDG_STATE_HOME"); state != "" {
		return filepath.Join(state, "relay", "workers")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "relay-"+strconv.Itoa(os.Getuid()), "workers")
	}
	return filepath.Join(home, ".local", "state", "relay", "workers")
}

func (server *Server) Serve(socketPath string) error {
	if server.executable == "" {
		return errors.New("cannot locate relayd executable")
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return err
	}
	server.runtimeDir = workerRuntimeDir(socketPath)
	if err := os.MkdirAll(server.runtimeDir, 0o700); err != nil {
		return err
	}
	lockFile, err := os.OpenFile(socketPath+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("relayd is already running at %s", socketPath)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
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
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return acceptErr
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
	return filepath.Join(os.TempDir(), "relay-"+strconv.Itoa(os.Getuid()), fmt.Sprintf("%x", digest[:6]))
}

func (server *Server) serveConnection(connection net.Conn) {
	defer connection.Close()
	first, err := protocol.ReadFrame(connection)
	if err != nil || first.Type != protocol.Hello {
		return
	}
	var hello protocol.HelloPayload
	if err := protocol.DecodeJSON(first, &hello); err != nil ||
		hello.Version != workerProtocolVersion || !validSessionID.MatchString(hello.SessionID) {
		return
	}
	if hello.Probe {
		ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready"})
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
	if !manifest.supports("event_cursor_v1") {
		serveObservedConnection(
			connection, worker, manifest, server.eventJournalPath(manifest.SessionID),
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

	codexFrames, stopCodex := observeCodexTranscript(manifest.ShellPID)
	defer stopCodex()
	claudeFrames, stopClaude := observeClaudeTranscript(manifest.ShellPID)
	defer stopClaude()
	writer := protocol.NewWriter(connection)
	index, indexErr := sharedExternalEventIndex(eventPath)
	if indexErr == nil {
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
		case frame, ok := <-codexFrames:
			if !ok {
				codexFrames = nil
				continue
			}
			if indexErr == nil {
				frame = index.index(frame.Payload)
			}
			if writer.Write(frame) != nil {
				return
			}
		case frame, ok := <-claudeFrames:
			if !ok {
				claudeFrames = nil
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
