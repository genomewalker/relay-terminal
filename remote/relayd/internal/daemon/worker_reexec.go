package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A pane worker owns the PTY master and is the parent of the pane's shell.
// Replacing the process would hang up the shell or orphan it, so a worker
// upgrades by exec'ing the new relayd in place: the PID, kernel start time,
// child relationship, PTY master and listening socket all survive, and the
// session state that lives only in memory crosses exec in a sealed file.
//
//  1. The request names the executable and its SHA-256, checked here.
//  2. The worker refuses while the shell has exited, a prompt editor or
//     native rotation bridge is open, rotation owns input, or context
//     management is evaluating or completing a rotation.
//  3. It stops accepting connections (they queue for the next image), drains
//     transcript readers and takes the input, resize and event locks, then
//     stops the PTY reader between reads. Unread output stays in the kernel.
//  4. It writes the state to an unlinked file and runs the new executable's
//     probe on it. Exec happens only if the new image can restore it.
//  5. It clears close-on-exec on the PTY, listener and state descriptors and
//     execs. If exec fails, every step is undone and the old image serves on.
//
// Attachments close at exec. Clients reconnect with their cursors, which the
// carried replay ring and sequence space still satisfy.
const workerReexecCapability = "worker_reexec_v1"

// The connections a handoff stops accepting may include one-shot hook events
// already accepted; give them time to reach the event lock first.
const workerReexecAcceptGrace = 200 * time.Millisecond

var validReexecOperation = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// Refusals while the pane is busy. The worker accepts once the pane settles,
// so upgrade-workers reports these as "busy" and can try again. Workers of
// earlier builds send the same messages.
var (
	errWorkerUpgradeInProgress = errors.New("another worker upgrade is in progress")
	errWorkerPromptEditOpen    = errors.New("a prompt edit is open")
	errWorkerRotationBridged   = errors.New("a native rotation bridge is attached")
	errWorkerRotationInput     = errors.New("context rotation owns terminal input")
	errWorkerTurnPending       = errors.New("context management has a turn to evaluate")
	errWorkerEvaluating        = errors.New("context management is evaluating a turn")
	errWorkerCompleting        = errors.New("context management is completing a rotation")
)

var workerBusyRefusals = map[string]bool{}

func init() {
	for _, err := range []error{errWorkerUpgradeInProgress, errWorkerPromptEditOpen, errWorkerRotationBridged,
		errWorkerRotationInput, errWorkerTurnPending, errWorkerEvaluating, errWorkerCompleting} {
		workerBusyRefusals[err.Error()] = true
	}
}

type workerUpgradeRequest struct {
	Executable  string `json:"executable"`
	SHA256      string `json:"sha256"`
	OperationID string `json:"operation_id"`
}

func (runtime *workerRuntime) serveUpgrade(writer *protocol.Writer, raw json.RawMessage) {
	reply := func(state, message string) {
		frame, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
			State: state, Message: message, WorkerPID: os.Getpid()})
		_ = writer.Write(frame)
	}
	var request workerUpgradeRequest
	if len(raw) > 4096 || json.Unmarshal(raw, &request) != nil || !validReexecOperation.MatchString(request.OperationID) ||
		!filepath.IsAbs(request.Executable) || len(request.SHA256) != sha256.Size*2 {
		reply("refused", "invalid worker upgrade request")
		return
	}
	if !runtime.handoffMu.TryLock() {
		reply("refused", errWorkerUpgradeInProgress.Error())
		return
	}
	defer runtime.handoffMu.Unlock()
	if err := runtime.reexec(request, func() { reply("upgrading", "") }); err != nil {
		reply("refused", err.Error())
	}
}

// reexec returns only on failure, after undoing every step it took.
func (runtime *workerRuntime) reexec(request workerUpgradeRequest, announce func()) (err error) {
	session := runtime.session
	var undo []func()
	defer func() {
		if err != nil {
			for index := len(undo) - 1; index >= 0; index-- {
				undo[index]()
			}
		}
	}()

	if err := verifyExecutableDigest(request.Executable, request.SHA256); err != nil {
		return err
	}
	editing := session.promptEditOpen(time.Now())
	session.nativeRotationMu.Lock()
	bridged := session.nativeRotation != nil
	session.nativeRotationMu.Unlock()
	session.mu.Lock()
	exited, reader, supervisor := session.exited, session.reader, session.hostRotation
	session.mu.Unlock()
	switch {
	case exited:
		return errors.New("pane shell has exited")
	case reader == nil || !reader.gated:
		return errors.New("this worker's terminal reader cannot be paused")
	case editing:
		return errWorkerPromptEditOpen
	case bridged:
		return errWorkerRotationBridged
	}
	if supervisor != nil {
		if err := supervisor.closeIfQuiescent(); err != nil {
			return err
		}
		undo = append(undo, func() {
			session.mu.Lock()
			session.hostRotation = runtime.newSupervisor()
			session.mu.Unlock()
		})
	}

	runtime.handoff.Store(true)
	_ = runtime.listener.SetDeadline(time.Now())
	undo = append(undo, func() {
		_ = runtime.listener.SetDeadline(time.Time{})
		select {
		case runtime.acceptResumed <- struct{}{}:
		default:
		}
		runtime.handoff.Store(false)
	})
	time.Sleep(workerReexecAcceptGrace)

	cursors := runtime.transcripts.drain()
	<-runtime.forwarded
	runtime.stopPersistence()
	undo = append(undo, func() {
		runtime.startPersistence()
		runtime.startTranscripts(cursors)
	})

	session.inputMu.Lock()
	session.resizeMu.Lock()
	session.eventMu.Lock()
	undo = append(undo, func() {
		session.eventMu.Unlock()
		session.resizeMu.Unlock()
		session.inputMu.Unlock()
	})
	if session.rotationGuardInstalled {
		return errWorkerRotationInput
	}
	// An event accepted before the locks may have completed a turn after the
	// supervisor closed. Do not hand over mid-turn; the rollback's fresh
	// supervisor revalidates it.
	if supervisor != nil {
		if state := supervisor.snapshot().State; state == "pending_evaluation" || state == "revalidating" {
			return errWorkerTurnPending
		}
	}
	if !session.stopOutputReader() {
		// The reader ended on its own: the PTY closed with the shell.
		return errors.New("pane terminal closed")
	}
	undo = append(undo, session.startOutputReader)

	state, err := session.exportReexecState(request.OperationID, cursors, runtime.manifest.CreatedAt)
	if err != nil {
		return err
	}
	stateFile, err := os.CreateTemp("", "relay-worker-state-*")
	if err != nil {
		return err
	}
	_ = os.Remove(stateFile.Name())
	undo = append(undo, func() { _ = stateFile.Close() })
	if err := writeWorkerReexecState(stateFile, state); err != nil {
		return err
	}
	if err := probeWorkerExecutable(request.Executable, stateFile, state.SessionID); err != nil {
		return err
	}

	listenerFile, err := runtime.listener.File()
	if err != nil {
		return err
	}
	undo = append(undo, func() { _ = listenerFile.Close() })
	ptyFD, stateFD, listenerFD := int(session.pty.Fd()), int(stateFile.Fd()), int(listenerFile.Fd())
	inherited := []int{ptyFD, stateFD, listenerFD}
	undo = append(undo, func() {
		for _, fd := range inherited {
			unix.CloseOnExec(fd)
		}
	})
	for _, fd := range inherited {
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_SETFD, 0); err != nil {
			return fmt.Errorf("cannot pass descriptor %d: %w", fd, err)
		}
	}
	config := runtime.config
	arguments := []string{request.Executable, "worker",
		"--socket", config.SocketPath, "--manifest", config.ManifestPath, "--session", config.SessionID,
		"--resume-state-fd", strconv.Itoa(stateFD), "--resume-pty-fd", strconv.Itoa(ptyFD),
		"--resume-listener-fd", strconv.Itoa(listenerFD), "--resume-shell-pid", strconv.Itoa(state.ShellPID),
		"--resume-operation", request.OperationID,
	}
	announce()
	err = syscall.Exec(request.Executable, arguments, os.Environ())
	fmt.Fprintf(os.Stderr, "relay: worker re-exec failed, continuing on this image: %v\n", err)
	return fmt.Errorf("exec %s: %w", request.Executable, err)
}

func verifyExecutableDigest(path, expected string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return errors.New("upgrade target is not an executable file")
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return err
	}
	if hex.EncodeToString(digest.Sum(nil)) != strings.ToLower(expected) {
		return errors.New("upgrade target does not match the requested digest")
	}
	return nil
}

// probeWorkerExecutable runs the new image's own decoder on the exact state
// file. An image that cannot restore it never receives the PTY.
func probeWorkerExecutable(executable string, stateFile *os.File, sessionID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "worker-reexec-probe", "--state-fd", "3")
	command.ExtraFiles = []*os.File{stateFile}
	command.Env = os.Environ()
	output, err := command.Output()
	if err != nil {
		return fmt.Errorf("new relayd cannot restore this worker: %w", err)
	}
	var probe struct {
		Format    int    `json:"format"`
		SessionID string `json:"session_id"`
	}
	if json.Unmarshal(output, &probe) != nil || probe.Format != workerReexecStateFormat || probe.SessionID != sessionID {
		return errors.New("new relayd does not support this worker state format")
	}
	return nil
}

// resumeWorker rebuilds the session in a freshly exec'd image. Once it holds
// the PTY it never fails: exiting would hang up the shell. A state it cannot
// restore costs the attached clients an output reset, not the pane.
func resumeWorker(config WorkerConfig) (*net.UnixListener, *Session, *workerReexecState, error) {
	resume := config.Resume
	if resume.PTYFD < 3 || resume.ShellPID <= 1 {
		return nil, nil, nil, errors.New("invalid worker resume descriptors")
	}
	ptyFile := os.NewFile(uintptr(resume.PTYFD), "/dev/ptmx")
	unix.CloseOnExec(resume.PTYFD)

	var state *workerReexecState
	if resume.StateFD >= 3 {
		unix.CloseOnExec(resume.StateFD)
		stateFile := os.NewFile(uintptr(resume.StateFD), "relay-worker-state")
		if decoded, err := readWorkerReexecState(stateFile); err != nil {
			fmt.Fprintf(os.Stderr, "relay: worker state unreadable after re-exec, resetting output: %v\n", err)
		} else if decoded.ShellPID != resume.ShellPID || decoded.SessionID != config.SessionID {
			fmt.Fprintln(os.Stderr, "relay: worker state names another pane, resetting output")
		} else {
			state = &decoded
		}
		_ = stateFile.Close()
	}
	// The shell is still this process's child, so Wait reports its exit.
	process, _ := os.FindProcess(resume.ShellPID)
	session := newSession(config.SessionID, config.Command, ptyFile, &exec.Cmd{Process: process})
	if state != nil {
		if err := session.restoreReexecState(*state); err != nil {
			fmt.Fprintf(os.Stderr, "relay: worker state not restored, resetting output: %v\n", err)
			session = newSession(config.SessionID, config.Command, ptyFile, &exec.Cmd{Process: process})
			state = nil
		}
	}
	if state == nil {
		session.reexecOperation = resume.Operation
	}
	session.start()

	listener := resumedListener(config, resume.ListenerFD)
	if listener == nil {
		// Without a socket nobody can reach the pane, but the shell and its
		// agent keep running; hold the PTY until the shell exits rather than
		// hang them up.
		fmt.Fprintln(os.Stderr, "relay: worker socket unavailable after re-exec; holding the terminal until the shell exits")
		<-session.done
		return nil, nil, nil, errors.New("worker socket unavailable after re-exec")
	}
	return listener, session, state, nil
}

func resumedListener(config WorkerConfig, fd int) *net.UnixListener {
	if fd >= 3 {
		file := os.NewFile(uintptr(fd), "relay-worker-socket")
		listener, err := net.FileListener(file)
		_ = file.Close()
		if unixListener, ok := listener.(*net.UnixListener); err == nil && ok {
			return unixListener
		}
		if listener != nil {
			_ = listener.Close()
		}
	}
	_ = os.Remove(config.SocketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: config.SocketPath, Net: "unix"})
	if err != nil {
		return nil
	}
	_ = os.Chmod(config.SocketPath, 0o600)
	return listener
}

func (session *Session) reopenEventJournal(path string) error {
	session.eventMu.Lock()
	defer session.eventMu.Unlock()
	// The carried state already holds the history; only reopen for append.
	journal, _, err := openAgentEventJournal(path)
	if err != nil {
		return err
	}
	session.mu.Lock()
	session.eventJournal = journal
	session.mu.Unlock()
	return nil
}

func (session *Session) noteJournalFailure(err error) {
	session.mu.Lock()
	session.eventJournalError = err.Error()
	session.mu.Unlock()
	fmt.Fprintf(os.Stderr, "relay: agent journal unavailable after re-exec: %v\n", err)
}

func (session *Session) reexecOperationID() string {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.reexecOperation
}

func (session *Session) reexecCapable() bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.workerUpgrade != nil
}

// WorkerUpgradeResult is one pane worker's outcome in `relayd upgrade-workers`.
type WorkerUpgradeResult struct {
	SessionID string `json:"session_id"`
	WorkerPID int    `json:"worker_pid,omitempty"`
	Result    string `json:"result"`
	Message   string `json:"message,omitempty"`
	Attempts  int    `json:"attempts,omitempty"`
}

type WorkerUpgradeOptions struct {
	StateDir   string
	Executable string
	Sessions   []string
	DryRun     bool
	Timeout    time.Duration
	// Workers refusing because their pane is busy are tried again up to
	// BusyRetries more times, BusyRetryInterval apart. Zero: no retries.
	BusyRetries       int
	BusyRetryInterval time.Duration
}

// UpgradeWorkers re-executes every live pane worker on this node that
// supports it into Executable, one at a time. Older workers are reported as
// legacy and left untouched: they keep their build until their pane restarts.
// Busy workers are retried as BusyRetries allows; any still busy afterwards
// stay on their build until the next upgrade.
func UpgradeWorkers(options WorkerUpgradeOptions) ([]WorkerUpgradeResult, error) {
	if options.StateDir == "" {
		options.StateDir = defaultWorkerStateDir()
	}
	if options.Timeout <= 0 {
		options.Timeout = 30 * time.Second
	}
	if options.Executable == "" {
		executable, err := os.Executable()
		if err != nil {
			return nil, err
		}
		options.Executable = executable
	}
	executable, err := filepath.Abs(options.Executable)
	if err != nil {
		return nil, err
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	digest, err := fileDigest(executable)
	if err != nil {
		return nil, err
	}
	sessions := options.Sessions
	if len(sessions) == 0 {
		if sessions, err = workerManifestSessions(options.StateDir); err != nil {
			return nil, err
		}
	}
	server := &Server{stateDir: options.StateDir}
	results := make([]WorkerUpgradeResult, len(sessions))
	for index, sessionID := range sessions {
		results[index].SessionID = sessionID
	}
	retryBusyWorkers(results, options, func(result *WorkerUpgradeResult) {
		result.Result, result.Message = upgradeWorker(server.manifestPath(result.SessionID), executable, digest, options, &result.WorkerPID)
	})
	return results, nil
}

// retryBusyWorkers attempts every worker once, then only the busy ones again,
// for at most options.BusyRetries more rounds. A dry run never retries.
func retryBusyWorkers(results []WorkerUpgradeResult, options WorkerUpgradeOptions, attempt func(*WorkerUpgradeResult)) {
	pending := make([]int, 0, len(results))
	for index := range results {
		pending = append(pending, index)
	}
	for round := 0; len(pending) > 0; round++ {
		if round > 0 {
			if options.DryRun || round > options.BusyRetries {
				return
			}
			time.Sleep(options.BusyRetryInterval)
		}
		busy := pending[:0]
		for _, index := range pending {
			attempt(&results[index])
			results[index].Attempts++
			if results[index].Result == "busy" {
				busy = append(busy, index)
			}
		}
		pending = busy
	}
}

func upgradeWorker(manifestPath, executable, digest string, options WorkerUpgradeOptions, workerPID *int) (string, string) {
	manifest, err := loadManifest(manifestPath)
	if err != nil {
		return "unreadable", err.Error()
	}
	*workerPID = manifest.WorkerPID
	if err := validateWorkerIdentity(manifest); err != nil {
		return "not_running", err.Error()
	}
	status, err := probeWorkerStatus(manifest)
	if err != nil {
		return "unavailable", err.Error()
	}
	if status.State != "ready" {
		return "skipped", "pane shell has exited"
	}
	if !containsString(status.Capabilities, workerReexecCapability) {
		return "legacy", "worker predates in-place upgrade; it keeps its build until the pane restarts"
	}
	if status.ExecutableSHA256 == digest {
		return "current", ""
	}
	if options.DryRun {
		return "would_upgrade", ""
	}
	operation, err := newWorkerToken()
	if err != nil {
		return "failed", err.Error()
	}
	operation = "reexec-" + operation[:24]
	request, _ := json.Marshal(workerUpgradeRequest{Executable: executable, SHA256: digest, OperationID: operation})
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return "unavailable", err.Error()
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(options.Timeout))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID, WorkerToken: manifest.Token, WorkerUpgrade: request})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return "unavailable", err.Error()
	}
	frame, err := protocol.ReadFrame(connection)
	var reply protocol.StatusPayload
	if err != nil || frame.Type != protocol.Status || protocol.DecodeJSON(frame, &reply) != nil {
		return "failed", "no reply to the upgrade request"
	}
	if reply.State != "upgrading" {
		if workerBusyRefusals[reply.Message] {
			return "busy", reply.Message
		}
		return "refused", reply.Message
	}
	deadline := time.Now().Add(options.Timeout)
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		status, err := probeWorkerStatus(manifest)
		if err != nil || status.ReexecOperation != operation {
			continue
		}
		start, err := processStartTime(manifest.WorkerPID)
		if err != nil || start != manifest.WorkerStartTime {
			return "failed", "worker identity changed during upgrade"
		}
		return "upgraded", ""
	}
	return "unconfirmed", "worker did not report the new image before the deadline"
}

var (
	imageDigestOnce sync.Once
	imageDigest     string
)

// runningImageDigest is the SHA-256 of the relayd image this process runs,
// read once from /proc/self/exe, which stays the mapped image after the file
// is replaced. Elsewhere only the executable's pathname is available, and an
// install may already have replaced that file, so the digest is unknown
// (empty). upgrade-workers skips a worker only when its digest matches the
// target; an unknown one costs a re-exec, never a false "current".
func runningImageDigest() string {
	imageDigestOnce.Do(func() {
		if goruntime.GOOS == "linux" {
			imageDigest, _ = fileDigest("/proc/self/exe")
		}
	})
	return imageDigest
}

func probeWorkerStatus(manifest workerManifest) (protocol.StatusPayload, error) {
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return protocol.StatusPayload{}, err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID, Probe: true, WorkerToken: manifest.Token})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return protocol.StatusPayload{}, err
	}
	frame, err := protocol.ReadFrame(connection)
	var status protocol.StatusPayload
	if err != nil || frame.Type != protocol.Status || protocol.DecodeJSON(frame, &status) != nil {
		return protocol.StatusPayload{}, errors.New("worker probe failed")
	}
	if status.WorkerPID != manifest.WorkerPID {
		return protocol.StatusPayload{}, errors.New("worker identity handshake failed")
	}
	return status, nil
}

// workerManifestSessions lists panes with a shared or recovered manifest.
func workerManifestSessions(stateDir string) ([]string, error) {
	seen := map[string]bool{}
	for _, pattern := range []string{filepath.Join(stateDir, "*.json"), filepath.Join(stateDir, "recovered-*", "*.json")} {
		paths, err := filepath.Glob(pattern)
		if err != nil {
			return nil, err
		}
		for _, path := range paths {
			id := strings.TrimSuffix(filepath.Base(path), ".json")
			if validSessionID.MatchString(id) {
				seen[id] = true
			}
		}
	}
	sessions := make([]string, 0, len(seen))
	for id := range seen {
		sessions = append(sessions, id)
	}
	sort.Strings(sessions)
	return sessions, nil
}

func fileDigest(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
