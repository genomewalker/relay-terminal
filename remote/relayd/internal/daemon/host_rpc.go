package daemon

// Host RPC shares the node connection with panes. Jobs belong to the daemon,
// not the SSH connection; a repeated job ID never launches another process.
import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/protocol"
)

type hostRotationRPCRequest struct {
	PaneID   string          `json:"pane_id"`
	ClientID string          `json:"client_id"`
	Request  json.RawMessage `json:"request"`
}
type hostRequest struct {
	NativeChat   json.RawMessage         `json:"native_chat,omitempty"`
	HostRotation *hostRotationRPCRequest `json:"host_rotation,omitempty"`
	AccountForce *forceAccountRPCRequest `json:"account_force,omitempty"`

	Communication       *CommunicationRequest  `json:"communication,omitempty"`
	WaitMillis          int                    `json:"wait_millis,omitempty"`
	RequestID           string                 `json:"request_id"`
	Operation           string                 `json:"operation"`
	ProcessPID          int                    `json:"process_pid,omitempty"`
	ProcessStart        string                 `json:"process_start,omitempty"`
	Signal              string                 `json:"signal,omitempty"`
	JobID               string                 `json:"job_id"`
	Kind                string                 `json:"kind,omitempty"`
	Command             string                 `json:"command,omitempty"`
	Argv                []string               `json:"argv,omitempty"`
	Cwd                 string                 `json:"cwd,omitempty"`
	Env                 map[string]string      `json:"env,omitempty"`
	Stdin               []byte                 `json:"stdin,omitempty"`
	KeepStdin           bool                   `json:"keep_stdin,omitempty"`
	InputSequence       int64                  `json:"input_sequence,omitempty"`
	CloseStdin          bool                   `json:"close_stdin,omitempty"`
	StdoutOffset        int64                  `json:"stdout_offset,omitempty"`
	StderrOffset        int64                  `json:"stderr_offset,omitempty"`
	TimeoutSeconds      int                    `json:"timeout_seconds,omitempty"`
	Path                string                 `json:"path,omitempty"`
	Offset              int64                  `json:"offset,omitempty"`
	Length              int                    `json:"length,omitempty"`
	Version             string                 `json:"version,omitempty"`
	Data                []byte                 `json:"data,omitempty"`
	UploadSize          int64                  `json:"upload_size,omitempty"`
	UploadSHA256        string                 `json:"upload_sha256,omitempty"`
	UploadName          string                 `json:"upload_name,omitempty"`
	UploadPane          string                 `json:"upload_pane,omitempty"`
	FolderManifest      []folderEntry          `json:"folder_manifest,omitempty"`
	FolderSourceVersion string                 `json:"folder_source_version,omitempty"`
	FolderChild         string                 `json:"folder_child,omitempty"`
	Plugin              *PluginRequest         `json:"plugin,omitempty"`
	AgentAccounts       *agentaccounts.Request `json:"agent_accounts,omitempty"`
	Listener            *peerListenerSpec      `json:"listener,omitempty"`
}
type hostJobRecord struct {
	JobID        string `json:"job_id"`
	Fingerprint  string `json:"fingerprint"`
	Kind         string `json:"kind,omitempty"`
	State        string `json:"state"`
	PID          int    `json:"pid,omitempty"`
	ProcessStart string `json:"process_start,omitempty"`
	ExitCode     *int   `json:"exit_code,omitempty"`
	Error        string `json:"error,omitempty"`
	Successor    string `json:"successor,omitempty"`
	// A listener's route and owner, kept in the ledger so a later supervisor
	// can follow a disconnect along the successor chain.
	Listener  *peerListenerBinding `json:"listener,omitempty"`
	CreatedAt string               `json:"created_at"`
	UpdatedAt string               `json:"updated_at"`
	// Ledger is hostJobLedgerTombstones in every record a tombstone-aware
	// daemon creates; see host_job_servers.go.
	Ledger int `json:"ledger,omitempty"`
}
type hostJob struct {
	notify      chan struct{}
	mu          sync.Mutex
	inputMu     sync.Mutex
	record      hostJobRecord
	cmd         *exec.Cmd
	input       io.WriteCloser
	sequence    int64
	inputHashes map[int64][32]byte
	inputErrors map[int64]string
	directory   string
	listener    *peerListenerSpec
}

func (s *Server) hostRPC(r hostRequest) (any, error) {
	if !validSessionID.MatchString(r.RequestID) {
		return nil, errors.New("valid request_id required")
	}
	if r.Operation == "native_chat" {
		return CallNativeChat(r.NativeChat)
	}
	if r.Operation == "host_rotation" {
		if r.HostRotation == nil {
			return nil, errors.New("host rotation request required")
		}
		// Ephemeral forwarding: no host job, fingerprint, stdin file or output
		// log can contain a credential. Sent RPCs are never replayed by the UI.
		return CallHostRotation(r.HostRotation.PaneID, r.HostRotation.ClientID, r.HostRotation.Request)
	}
	if r.Operation == "communication" {
		if r.Communication == nil {
			return nil, errors.New("communication request required")
		}
		return ExecuteCommunication(*r.Communication)
	}
	if r.Operation == "process_list" || r.Operation == "process_signal" {
		return s.hostProcessRPC(r)
	}
	if r.Operation == "capabilities" || strings.HasPrefix(r.Operation, "file_") {
		return s.hostFileRPC(r)
	}
	if r.Operation == "agent_accounts" {
		if r.AgentAccounts == nil {
			return nil, errors.New("agent account request required")
		}
		// Account directories and links only; credentials are never read.
		return agentaccounts.Handle(*r.AgentAccounts, agentaccounts.ProviderProbe)
	}
	if r.Operation == "plugin" {
		if r.Plugin == nil {
			return nil, errors.New("plugin request required")
		}
		return InspectPlugin(*r.Plugin)
	}
	if !validSessionID.MatchString(r.JobID) {
		return nil, errors.New("valid request_id and job_id required")
	}
	if r.Operation == "exec" {
		return s.startHostJob(r)
	}
	if r.Operation == "cancel" {
		if result, handled, err := s.cancelPeerListenerJob(r.JobID); handled {
			return result, err
		}
	}
	value, ok := s.hostJobs.Load(r.JobID)
	if !ok {
		raw, directory, tombstone, err := s.readHostJobRecord(r.JobID)
		if err != nil {
			return nil, errors.New("unknown job; do not replay execution")
		}
		var record hostJobRecord
		if json.Unmarshal(raw, &record) != nil {
			return nil, errors.New("invalid job record")
		}
		if record.State == "running" || record.State == "starting" {
			record.State = "unknown_after_daemon_restart"
		}
		if r.Operation != "status" {
			return nil, errors.New("job no longer controlled by this daemon; do not replay")
		}
		if tombstone != nil {
			return hostJobTombstoneSnapshot(*tombstone, r)
		}
		// The folder may move into the archive, or be cleaned, during this read.
		return s.resolveHostJobSnapshot(nil, record, directory, r)
	}
	job := value.(*hostJob)
	if r.Operation == "input" {
		return job.writeInput(r)
	}
	if r.Operation == "status" && r.WaitMillis > 0 {
		if r.WaitMillis > 15000 {
			r.WaitMillis = 15000
		}
		job.mu.Lock()
		running, directory := job.record.State == "running", job.directory
		job.mu.Unlock()
		out, _ := os.Stat(filepath.Join(directory, "stdout"))
		errout, _ := os.Stat(filepath.Join(directory, "stderr"))
		if running && out != nil && errout != nil && out.Size() <= r.StdoutOffset && errout.Size() <= r.StderrOffset {
			select {
			case <-job.notify:
			case <-time.After(time.Duration(r.WaitMillis) * time.Millisecond):
			}
		}
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	switch r.Operation {
	case "status":
		// A finished job this daemon still tracks may be archived by another
		// daemon sharing the state directory, then cleaned.
		return s.resolveHostJobSnapshot(job, job.record, job.directory, r)
	case "cancel":
		if job.cmd != nil && job.record.State == "running" {
			if err := syscall.Kill(-job.cmd.Process.Pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
				return nil, err
			}
		}
		return job.record, nil
	default:
		return nil, errors.New("unsupported host operation")
	}
}

func (job *hostJob) writeInput(r hostRequest) (any, error) {
	job.inputMu.Lock()
	defer job.inputMu.Unlock()
	job.mu.Lock()
	defer job.mu.Unlock()
	if len(r.Stdin) > 256<<10 || r.InputSequence < 1 {
		return nil, errors.New("bounded input and positive sequence required")
	}
	hashData, _ := json.Marshal(struct {
		Data  []byte
		Close bool
	}{r.Stdin, r.CloseStdin})
	hash := sha256.Sum256(hashData)
	if previous, ok := job.inputHashes[r.InputSequence]; ok {
		if previous != hash {
			return nil, errors.New("input sequence reused with different content")
		}
		if message := job.inputErrors[r.InputSequence]; message != "" {
			return nil, errors.New(message)
		}
		return map[string]any{"accepted_sequence": r.InputSequence}, nil
	}
	if r.InputSequence != job.sequence+1 || job.input == nil {
		return nil, errors.New("input sequence gap or closed stdin")
	}
	// Record before writing: an uncertain write must never be replayed.
	job.sequence = r.InputSequence
	job.inputHashes[r.InputSequence] = hash
	delete(job.inputHashes, r.InputSequence-256)
	delete(job.inputErrors, r.InputSequence-256)
	input := job.input
	if r.CloseStdin {
		job.input = nil
	}
	// A blocked child must not prevent status or cancellation.
	job.mu.Unlock()
	_, writeErr := input.Write(r.Stdin)
	if r.CloseStdin {
		input.Close()
	}
	job.mu.Lock()
	if writeErr != nil {
		if job.inputErrors == nil {
			job.inputErrors = make(map[int64]string)
		}
		job.inputErrors[r.InputSequence] = fmt.Sprintf("input outcome unknown: %v", writeErr)
		return nil, fmt.Errorf("input outcome unknown: %w", writeErr)
	}
	return map[string]any{"accepted_sequence": r.InputSequence}, nil
}
func hostJobSnapshot(record hostJobRecord, dir string, r hostRequest) (any, error) {
	if r.StdoutOffset < 0 || r.StderrOffset < 0 {
		return nil, errors.New("negative output offset")
	}
	read := func(name string, offset int64) ([]byte, int64, error) {
		f, e := os.Open(filepath.Join(dir, name))
		if e != nil {
			return nil, offset, e
		}
		defer f.Close()
		info, e := f.Stat()
		if e != nil || offset > info.Size() {
			return nil, offset, errors.New("invalid output offset")
		}
		b := make([]byte, 256<<10)
		n, e := f.ReadAt(b, offset)
		if e != nil && e != io.EOF {
			return nil, offset, e
		}
		return b[:n], offset + int64(n), nil
	}
	out, oo, e := read("stdout", r.StdoutOffset)
	if e != nil {
		return nil, e
	}
	errout, eo, e := read("stderr", r.StderrOffset)
	if e != nil {
		return nil, e
	}
	return map[string]any{"job": record, "process_state": hostJobProcessState(record), "stdout": out, "stderr": errout, "stdout_offset": oo, "stderr_offset": eo}, nil
}

// Unknown outcome is not permission to rerun a command. Liveness is separate
// evidence used by listener recovery and supervisor upgrade quiescence.
func hostJobProcessState(record hostJobRecord) string {
	return hostJobProcessStateWith(record, syscall.Kill, processStartIdentity)
}

// Probe dependencies are explicit so fail-closed errors can be checked without
// changing global process inspection or signalling a live process.
func hostJobProcessStateWith(record hostJobRecord, probe func(int, syscall.Signal) error, identity func(int) (string, error)) string {
	if record.State == "exited" || record.State == "failed" {
		return "absent"
	}
	if record.PID <= 1 {
		return "unknown"
	}
	err := probe(record.PID, 0)
	if err == syscall.ESRCH {
		return "absent"
	}
	if err != nil || record.ProcessStart == "" {
		return "unknown"
	}
	start, err := identity(record.PID)
	if err != nil || start == "" {
		return "unknown"
	}
	if start != record.ProcessStart {
		return "replaced"
	}
	return "alive"
}

func (job *hostJob) save() error {
	job.record.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	raw, e := json.Marshal(job.record)
	if e != nil {
		return e
	}
	temp := filepath.Join(job.directory, "record.tmp")
	file, e := os.OpenFile(temp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	if _, e = file.Write(raw); e == nil {
		e = file.Sync()
	}
	file.Close()
	if e != nil {
		return e
	}
	if e = os.Rename(temp, filepath.Join(job.directory, "record.json")); e != nil {
		return e
	}
	directory, e := os.Open(job.directory)
	if e != nil {
		return e
	}
	defer directory.Close()
	return directory.Sync()
}
func hostJobFingerprint(r hostRequest) string {
	identity := r
	identity.RequestID = ""
	identity.Operation = ""
	identity.StdoutOffset = 0
	identity.StderrOffset = 0
	identity.WaitMillis = 0
	raw, _ := json.Marshal(identity)
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:])
}

func (s *Server) startHostJob(r hostRequest) (any, error) {
	if r.KeepStdin && len(r.Stdin) > 0 {
		return nil, errors.New("use sequenced input after creating a keep_stdin job")
	}
	switch r.Kind {
	case "":
		if r.Listener != nil {
			return nil, errors.New("listener specification requires the peer listener kind")
		}
		if (r.Command == "") == (len(r.Argv) == 0) {
			return nil, errors.New("bounded command or argv required")
		}
	case hostJobKindPeerListener:
		// A declared listener is a restartable inbox, never a one-shot command.
		// relayd builds its argv from the typed specification, so the registry
		// can relaunch exactly this listener without parsing command text.
		if r.Listener == nil || r.Command != "" || len(r.Argv) > 0 || len(r.Env) > 0 || !r.KeepStdin || len(r.Stdin) > 0 || r.TimeoutSeconds != 0 {
			return nil, errors.New("peer listener requires a listener specification and kept stdin, without argv, env or timeout")
		}
		if err := r.Listener.validate(); err != nil {
			return nil, err
		}
		if r.Listener.legacyPython() {
			return nil, errors.New("legacy peer listener requires a native migration")
		}
	default:
		return nil, errors.New("unsupported host job kind")
	}
	if len(r.Command) > 60000 || len(r.Argv) > 128 || len(r.Env) > 128 || len(r.Stdin) > 256<<10 || r.TimeoutSeconds < 0 || r.TimeoutSeconds > 86400 {
		return nil, errors.New("bounded command or argv required")
	}
	for _, a := range r.Argv {
		if len(a) > 1<<20 || strings.ContainsRune(a, 0) {
			return nil, errors.New("invalid argument")
		}
	}
	for k, v := range r.Env {
		if k == "" || strings.ContainsAny(k, "=\x00") || strings.ContainsRune(v, 0) || len(v) > 65536 {
			return nil, errors.New("invalid environment")
		}
	}
	fingerprint := hostJobFingerprint(r)
	// Serialize reservation, including the durable ledger lookup.
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	if time.Now().Before(s.hostUpgradeUntil) {
		return nil, errors.New("supervisor upgrade handoff in progress; execution was not started")
	}
	if existing, ok := s.hostJobs.Load(r.JobID); ok {
		job := existing.(*hostJob)
		job.mu.Lock()
		defer job.mu.Unlock()
		if job.record.Fingerprint != fingerprint {
			return nil, errors.New("job ID reused with different execution")
		}
		return job.record, nil
	}
	directory := filepath.Join(s.stateDir, "host-jobs", r.JobID)
	if raw, _, _, e := s.readHostJobRecord(r.JobID); e == nil {
		var old hostJobRecord
		if json.Unmarshal(raw, &old) != nil || old.Fingerprint != fingerprint {
			return nil, errors.New("job ID already reserved")
		}
		if old.State == "running" || old.State == "starting" {
			old.State = "unknown_after_daemon_restart"
		}
		return old, nil
	} else if !os.IsNotExist(e) {
		return nil, e
	}
	if r.Listener != nil {
		// Exactly one listener per route: a second launch, e.g. a client
		// respawn racing a registry resume, is reserved as superseded and
		// names the job that serves the route. It never starts a process.
		if serving := s.activePeerListenerLocked(r.Listener.Route); serving != "" {
			return s.reserveSupersededHostJob(r, fingerprint, directory, serving)
		}
	}
	return s.launchHostJobLocked(r, fingerprint, directory)
}

// The caller holds hostJobsMu and has established that r.JobID is unreserved.
func (s *Server) launchHostJobLocked(r hostRequest, fingerprint, directory string) (any, error) {
	if r.Listener != nil && r.Listener.legacyPython() {
		return nil, errors.New("legacy peer listener requires a native migration")
	}
	active := 0
	s.hostJobs.Range(func(_, v any) bool {
		j := v.(*hostJob)
		j.mu.Lock()
		if j.record.State == "running" {
			active++
		}
		j.mu.Unlock()
		return true
	})
	if active >= 32 {
		return nil, errors.New("host execution capacity reached")
	}
	if e := os.MkdirAll(filepath.Dir(directory), 0700); e != nil {
		return nil, e
	}
	if e := os.Mkdir(directory, 0700); e != nil {
		return nil, errors.New("job ID already reserved")
	}
	job := &hostJob{notify: make(chan struct{}, 1), directory: directory, inputHashes: make(map[int64][32]byte), listener: r.Listener, record: hostJobRecord{JobID: r.JobID, Fingerprint: fingerprint, Kind: r.Kind, Listener: r.Listener.binding(), State: "starting", CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Ledger: hostJobLedgerTombstones}}
	if e := job.save(); e != nil {
		return nil, e
	}
	s.hostJobs.Store(r.JobID, job)
	job.mu.Lock()
	defer job.mu.Unlock()
	fail := func(e error) (any, error) {
		job.record.State = "failed"
		job.record.Error = e.Error()
		job.save()
		return job.record, nil
	}
	out, e := os.OpenFile(filepath.Join(directory, "stdout"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return fail(e)
	}
	errout, e := os.OpenFile(filepath.Join(directory, "stderr"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		out.Close()
		return fail(e)
	}
	var cmd *exec.Cmd
	if r.Listener != nil {
		argv := r.Listener.argv()
		argv, err := resolveNativeHostArgv(argv)
		if err != nil {
			out.Close()
			errout.Close()
			return fail(err)
		}
		cmd = exec.Command(argv[0], argv[1:]...)
	} else if r.Command != "" {
		cmd = exec.Command("/bin/sh", "-lc", r.Command)
	} else {
		argv, err := resolveNativeHostArgv(r.Argv)
		if err != nil {
			out.Close()
			errout.Close()
			return fail(err)
		}
		cmd = exec.Command(argv[0], argv[1:]...)
	}
	cmd.Dir = r.Cwd
	cmd.Env = os.Environ()
	for k, v := range r.Env {
		prefix := k + "="
		filtered := cmd.Env[:0]
		for _, entry := range cmd.Env {
			if !strings.HasPrefix(entry, prefix) {
				filtered = append(filtered, entry)
			}
		}
		cmd.Env = append(filtered, prefix+v)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Bound stored output independently for stdout and stderr. Excess is consumed
	// and reported, so a noisy child cannot block the shared transport.
	stdout := &hostOutput{file: out, notify: job.notify}
	stderr := &hostOutput{file: errout, notify: job.notify}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if r.KeepStdin {
		job.input, e = cmd.StdinPipe()
		if e != nil {
			out.Close()
			errout.Close()
			return fail(e)
		}
	} else {
		cmd.Stdin = strings.NewReader(string(r.Stdin))
	}
	if e = cmd.Start(); e != nil {
		out.Close()
		errout.Close()
		return fail(e)
	}
	job.cmd = cmd
	job.record.PID = cmd.Process.Pid
	job.record.ProcessStart, _ = processStartIdentity(cmd.Process.Pid)
	job.record.State = "running"
	if e := job.save(); e != nil {
		// The process has started: keep tracking it, but surface persistence
		// failure rather than authorizing a fresh execution or losing Wait.
		job.record.Error = "running job persistence failed: " + e.Error()
	}
	if job.listener != nil {
		// Without its registry entry the listener still serves, but it is no
		// longer resumable, so it blocks a supervisor upgrade as before.
		if e := s.recordPeerListener(job.listener, r.Cwd, r.JobID); e != nil {
			job.record.Error = "peer listener registry write failed: " + e.Error()
			job.save()
		}
	}
	go func() {
		var timer *time.Timer
		if r.TimeoutSeconds > 0 {
			timer = time.AfterFunc(time.Duration(r.TimeoutSeconds)*time.Second, func() {
				job.mu.Lock()
				defer job.mu.Unlock()
				if job.record.State == "running" {
					syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				}
			})
		}
		waitErr := cmd.Wait()
		if timer != nil {
			timer.Stop()
		}
		out.Close()
		errout.Close()
		job.mu.Lock()
		defer job.mu.Unlock()
		job.record.State = "exited"
		select {
		case job.notify <- struct{}{}:
		default:
		}
		code := cmd.ProcessState.ExitCode()
		job.record.ExitCode = &code
		if waitErr != nil {
			job.record.Error = waitErr.Error()
		}
		if stdout.discarded || stderr.discarded {
			job.record.Error += "; output exceeded 64 MiB limit"
		}
		if job.input != nil {
			job.input.Close()
			job.input = nil
		}
		job.save()
		if job.listener != nil {
			// A listener suspended for an upgrade stays registered for resume;
			// any other exit ends its registration.
			s.releasePeerListener(job.listener.Route, job.record.JobID)
		}
	}()
	return job.record, nil
}

type hostOutput struct {
	notify    chan struct{}
	file      *os.File
	written   int64
	discarded bool
}

func (w *hostOutput) Write(p []byte) (int, error) {
	n := len(p)
	remaining := int64(64<<20) - w.written
	if int64(len(p)) > remaining {
		p = p[:remaining]
		w.discarded = true
	}
	count, e := w.file.Write(p)
	w.written += int64(count)
	select {
	case w.notify <- struct{}{}:
	default:
	}
	if e != nil {
		return count, e
	}
	return n, nil
}
func (s *Server) serveHostRPC(writer *protocol.Writer, frame protocol.Frame) {
	var request hostRequest
	var result any
	var err error
	if json.Unmarshal(frame.Payload, &request) != nil {
		err = errors.New("invalid host request")
	} else {
		result, err = s.hostRPC(request)
	}
	response := map[string]any{"request_id": request.RequestID, "result": result}
	if err != nil {
		response["error"] = err.Error()
	}
	answer, e := protocol.JSONFrame(protocol.HostResponse, response)
	if e == nil {
		writer.Write(answer)
	}
}
