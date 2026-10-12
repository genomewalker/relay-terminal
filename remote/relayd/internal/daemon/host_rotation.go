package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// The release copy is byte-identical to Sources/Relay/Resources/Rotation/policy.py.
// Keep the digest synchronized with RelayPinnedContextRotationPolicy.
//
//go:embed host_rotation_policy.py
var hostRotationPolicy []byte

const hostRotationPolicySHA = "cb6cf0ee65b4d0110354196733f8fedc004e3c64cfb480e10e201e62cbc32d3a"

type hostRotationEnrollment struct {
	SessionID   string `json:"session_id"`
	Client      string `json:"client"`
	CWD         string `json:"cwd"`
	PaneID      string `json:"pane_id"`
	AgentPID    int    `json:"agent_pid"`
	AgentStart  uint64 `json:"agent_start"`
	WorkerPID   int    `json:"worker_pid"`
	WorkerStart uint64 `json:"worker_start"`
	NodeBootID  string `json:"node_boot_id"`
}

type hostRotationRecord struct {
	Version          int                    `json:"v"`
	OperationID      string                 `json:"operation_id"`
	Operation        string                 `json:"operation"`
	Enrollment       hostRotationEnrollment `json:"enrollment"`
	Enabled          bool                   `json:"enabled"`
	State            string                 `json:"state"`
	Generation       uint64                 `json:"generation"`
	Decision         json.RawMessage        `json:"decision,omitempty"`
	NextEvaluationMS int64                  `json:"next_evaluation_ms,omitempty"`
	Fingerprint      string                 `json:"fingerprint,omitempty"`
	UpdatedAt        time.Time              `json:"updated_at"`
	// Evaluation never grants permission to submit input. These capabilities
	// are reported separately until native clear/restore and refresh exist.
	Lifecycle             string                             `json:"lifecycle"`
	RefreshCapability     string                             `json:"refresh_capability"`
	Preparation           *hostRotationPreparation           `json:"preparation,omitempty"`
	NativeTransition      *hostRotationNativeTransition      `json:"native_transition,omitempty"`
	NativeAbortTransition *hostRotationNativeAbortTransition `json:"native_abort_transition,omitempty"`
	NativeRecoveryState   string                             `json:"native_recovery_state,omitempty"`
}

type hostRotationRequest struct {
	Version             int             `json:"v"`
	Operation           string          `json:"operation"`
	ID                  string          `json:"id"`
	SessionID           string          `json:"session_id"`
	Client              string          `json:"client"`
	CWD                 string          `json:"cwd"`
	AgentPID            int             `json:"agent_pid"`
	AgentStart          uint64          `json:"agent_start"`
	TextSettings        json.RawMessage `json:"text_settings,omitempty"`
	TextOperationID     string          `json:"text_operation_id,omitempty"`
	CredentialReference string          `json:"credential_reference,omitempty"`
	CredentialSecret    string          `json:"credential_secret,omitempty"`
	CredentialAccountID string          `json:"credential_account_id,omitempty"`
}

type hostRotationSchedule struct {
	Fingerprint      string `json:"fingerprint"`
	NextEvaluationMS *int64 `json:"next_evaluation_ms"`
}

type hostRotationDecision struct {
	Version  int                   `json:"v"`
	Decision string                `json:"decision"`
	Schedule *hostRotationSchedule `json:"schedule"`
}

type hostRotationEvaluate func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error)

type hostRotationSupervisor struct {
	mu                    sync.Mutex
	record                hostRotationRecord
	path                  string
	evaluate              hostRotationEvaluate
	prepare               hostRotationPrepare
	finalizeNative        func(context.Context, *hostRotationSupervisor) error
	nativeWorkerDirectory string
	nativeDriver          hostNativeSupervisorDriver
	wake                  chan struct{}
	done                  chan struct{}
	stopped               chan struct{}
	updated               chan struct{}
	once                  sync.Once
	cancel                context.CancelFunc
}

func newHostRotationSupervisor(path string, evaluate hostRotationEvaluate, prepare ...hostRotationPrepare) *hostRotationSupervisor {
	return newHostRotationSupervisorWithFinalizer(path, evaluate, nil, prepare...)
}
func newHostRotationSupervisorWithFinalizer(path string, evaluate hostRotationEvaluate, finalize func(context.Context, *hostRotationSupervisor) error, prepare ...hostRotationPrepare) *hostRotationSupervisor {
	return newHostRotationSupervisorWithNativeJournal(path, evaluate, finalize, "", prepare...)
}
func newHostRotationSupervisorWithNativeJournal(path string, evaluate hostRotationEvaluate, finalize func(context.Context, *hostRotationSupervisor) error, workerDirectory string, prepare ...hostRotationPrepare) *hostRotationSupervisor {
	return newHostRotationSupervisorWithDriver(path, evaluate, finalize, workerDirectory, nil, prepare...)
}
func newHostRotationSupervisorWithDriver(path string, evaluate hostRotationEvaluate, finalize func(context.Context, *hostRotationSupervisor) error, workerDirectory string, driver hostNativeSupervisorDriver, prepare ...hostRotationPrepare) *hostRotationSupervisor {
	s := &hostRotationSupervisor{path: path, evaluate: evaluate, finalizeNative: finalize, nativeWorkerDirectory: workerDirectory, nativeDriver: driver, wake: make(chan struct{}, 1),
		done: make(chan struct{}), stopped: make(chan struct{}), updated: make(chan struct{}, 1)}
	if s.finalizeNative == nil && driver != nil {
		s.finalizeNative = func(ctx context.Context, supervisor *hostRotationSupervisor) error {
			outcome, err := driver.recover(ctx, supervisor)
			if err == nil && outcome.Pending {
				return errors.New("native finalization remains pending")
			}
			return err
		}
	}
	if len(prepare) == 1 {
		s.prepare = prepare[0]
	}
	s.record = hostRotationRecord{Version: 1, State: "not_enrolled", Lifecycle: "unavailable", RefreshCapability: "unverified"}
	// A restarted process never executes a persisted deadline blindly.
	// It first re-observes the complete physical and ledger identity.
	if data, err := privatePromptEditorBytes(path, 262144); err == nil {
		var saved hostRotationRecord
		if json.Unmarshal(data, &saved) == nil && saved.Version == 1 && validPromptEditorID(saved.OperationID) &&
			(saved.NativeTransition == nil || saved.NativeTransition.valid()) &&
			(saved.NativeAbortTransition == nil || saved.NativeAbortTransition.valid()) &&
			!(saved.NativeTransition != nil && !saved.NativeTransition.Finalized && saved.NativeAbortTransition != nil && !saved.NativeAbortTransition.Finalized) {
			s.record = saved
			s.record.Generation++
			s.record.NextEvaluationMS = 0
			s.record.Fingerprint = ""
			s.record.Decision = nil
			s.record.Preparation = nil
			s.record.Lifecycle = "unavailable"
			s.record.RefreshCapability = "unverified"
			if saved.Enabled {
				s.record.State = "revalidating"
				if saved.NativeAbortTransition != nil && saved.NativeAbortTransition.Finalized &&
					(saved.State == "native_refused" || saved.State == "awaiting_completed_turn") {
					s.record.State = saved.State
				}
				if saved.NativeTransition != nil && !saved.NativeTransition.Finalized || saved.NativeAbortTransition != nil && !saved.NativeAbortTransition.Finalized {
					s.record.State = "native_finalization_pending"
				}
			}
		} else {
			s.record.State = "invalid_saved_state"
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		s.record.State = "saved_state_unavailable"
	}
	if s.record.Enabled || s.record.NativeTransition != nil && !s.record.NativeTransition.Finalized ||
		s.record.NativeAbortTransition != nil && !s.record.NativeAbortTransition.Finalized ||
		workerDirectory != "" && s.record.Enrollment.Client == "codex" {
		s.notify()
	}
	go s.run()
	return s
}

func (s *hostRotationSupervisor) notify() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *hostRotationSupervisor) close() {
	s.once.Do(func() {
		s.mu.Lock()
		if s.cancel != nil {
			s.cancel()
		}
		close(s.done)
		s.mu.Unlock()
	})
	<-s.stopped
}

func (s *hostRotationSupervisor) snapshot() hostRotationRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.record
	r.Decision = bytes.Clone(r.Decision)
	r.Preparation = cloneHostRotationPreparation(r.Preparation)
	if r.NativeTransition != nil {
		copied := *r.NativeTransition
		r.NativeTransition = &copied
	}
	if r.NativeAbortTransition != nil {
		copied := *r.NativeAbortTransition
		r.NativeAbortTransition = &copied
	}
	return r
}

// Called before a human input write, under Session.inputMu. Invalidation is
// immediate in memory and durable before a later scheduling attempt can run.
func (s *hostRotationSupervisor) humanInput() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.record.Enabled {
		return
	}
	s.record.Generation++
	s.record.Enabled = false
	s.record.State = "human_takeover"
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.record.Decision = nil
	s.record.Preparation = nil
	if s.cancel != nil {
		s.cancel()
	}
	if err := s.saveLocked(); err != nil {
		s.record.State = "persistence_failed"
	}
	s.notify()
}

// All authenticated agent activity invalidates an outstanding evaluation.
// Only a matching root Stop/completed event asks for a new evaluation.
// This callback runs after journal append, never from viewport/replay text.
func (s *hostRotationSupervisor) event(payload []byte, journalOK bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.record.Enabled {
		return
	}
	completed := journalOK && hostRotationCompletedEvent(payload, s.record.Enrollment)
	// The first activity durably invalidates the decision. Further activity
	// cannot invalidate it again or start evaluation until a root completion.
	// Never coalesce journal failure or human takeover.
	if journalOK && !completed && s.record.State == "awaiting_completed_turn" &&
		s.record.NextEvaluationMS == 0 && s.record.Fingerprint == "" && len(s.record.Decision) == 0 {
		return
	}
	s.record.Generation++
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.record.Decision = nil
	s.record.Preparation = nil
	s.record.State = "awaiting_completed_turn"
	if s.cancel != nil {
		s.cancel()
	}
	if !journalOK {
		s.record.Enabled = false
		s.record.State = "event_journal_failed"
	} else if completed {
		s.record.State = "pending_evaluation"
	}
	if err := s.saveLocked(); err != nil {
		s.record.Enabled = false
		s.record.State = "persistence_failed"
	}
	s.notify()
}

func hostRotationCompletedEvent(payload []byte, e hostRotationEnrollment) bool {
	var v struct {
		Agent string `json:"agent"`
		Event struct {
			HookEventName   string `json:"hook_event_name"`
			SessionID       string `json:"session_id"`
			ThreadID        string `json:"thread_id"`
			ParentSessionID string `json:"parent_session_id"`
			Method          string `json:"method"`
			Params          struct {
				ThreadID      string `json:"threadId"`
				ThreadIDSnake string `json:"thread_id"`
			} `json:"params"`
		} `json:"event"`
	}
	if len(payload) > 262144 || json.Unmarshal(payload, &v) != nil || v.Agent != e.Client || v.Event.ParentSessionID != "" {
		return false
	}
	if v.Event.HookEventName == "Stop" {
		return v.Event.SessionID == e.SessionID
	}
	if v.Event.HookEventName == "turn/completed" && e.Client == "codex" {
		return v.Event.ThreadID == e.SessionID
	}
	return e.Client == "codex" && v.Event.Method == "turn/completed" &&
		(v.Event.Params.ThreadID == e.SessionID || v.Event.Params.ThreadIDSnake == e.SessionID)
}

func (s *hostRotationSupervisor) saveLocked() error {
	s.record.UpdatedAt = time.Now().UTC()
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := privateBindingObject(dir, true); err != nil {
		return err
	}
	data, err := json.Marshal(s.record)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".rotation-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if err := tmp.Chmod(0600); err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), s.path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return err
	}
	select {
	case s.updated <- struct{}{}:
	default:
	}
	return nil
}

func (s *hostRotationSupervisor) configure(req hostRotationRequest, enrollment hostRotationEnrollment) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if req.Operation != "enroll" && req.Operation != "disable" {
		return errors.New("unknown host rotation operation")
	}
	if !validPromptEditorID(req.ID) {
		return errors.New("invalid operation identity")
	}
	if s.record.OperationID == req.ID {
		if s.record.Operation != req.Operation {
			return errors.New("operation identity conflict")
		}
		if (req.Operation == "enroll" && s.record.Enrollment != enrollment) ||
			(req.Operation == "disable" && s.record.Enabled) {
			return errors.New("operation identity conflict")
		}
		return nil
	}
	if req.Operation == "enroll" && (s.record.NativeTransition != nil && !s.record.NativeTransition.Finalized ||
		s.record.NativeAbortTransition != nil && !s.record.NativeAbortTransition.Finalized) {
		return errors.New("native finalization is pending")
	}
	if req.Operation == "enroll" && s.nativeWorkerDirectory != "" {
		for _, candidate := range []hostRotationEnrollment{s.record.Enrollment, enrollment} {
			if state := inspectHostNativeSupervisorJournal(s.nativeWorkerDirectory, candidate); state != "" {
				return errors.New("native transaction requires recovery: " + state)
			}
		}
	}
	// Replacement identity must be explicitly disabled first.
	if req.Operation == "enroll" && s.record.Enabled && s.record.Enrollment != enrollment {
		return errors.New("disable existing enrollment before replacing it")
	}
	if s.cancel != nil {
		s.cancel()
	}
	s.record.Generation++
	s.record.OperationID = req.ID
	s.record.Operation = req.Operation
	s.record.Enabled = req.Operation == "enroll"
	if s.record.Enabled {
		s.record.Enrollment = enrollment
		// A new explicit enrollment may retry with fresh admission. Historical
		// abort and finalization receipts remain in the immutable host journal.
		if s.record.NativeAbortTransition != nil && s.record.NativeAbortTransition.Finalized {
			s.record.NativeAbortTransition = nil
		}
		s.record.State = "pending_evaluation"
	} else {
		s.record.State = "disabled"
	}
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.record.Decision = nil
	s.record.Preparation = nil
	if err := s.saveLocked(); err != nil {
		s.record.Enabled = false
		s.record.State = "persistence_failed"
		return err
	}
	s.notify()
	return nil
}

func (s *hostRotationSupervisor) run() {
	defer close(s.stopped)
	timer := time.NewTimer(time.Hour)
	if !timer.Stop() {
		<-timer.C
	}
	defer timer.Stop()
	var timerC <-chan time.Time
	var scheduledGeneration uint64
	var scheduledFingerprint string
	for {
		fromTimer := false
		select {
		case <-s.done:
			return
		case <-s.wake:
		case <-timerC:
			fromTimer = true
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timerC = nil
		if s.recoverNativeTransition() {
			pending := s.snapshot()
			if (pending.NativeTransition != nil && !pending.NativeTransition.Finalized ||
				pending.NativeAbortTransition != nil && !pending.NativeAbortTransition.Finalized) && s.finalizeNative != nil {
				timer.Reset(5 * time.Second)
				timerC = timer.C
			}
			continue
		}
		if s.recoverNativeJournal() {
			timer.Reset(5 * time.Second)
			timerC = timer.C
			continue
		}
		r := s.snapshot()
		if !r.Enabled {
			continue
		}
		if fromTimer {
			if r.Generation != scheduledGeneration || r.Fingerprint != scheduledFingerprint {
				continue
			}
		} else if r.State != "pending_evaluation" && r.State != "revalidating" {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		s.mu.Lock()
		if s.record.Generation != r.Generation || !s.record.Enabled {
			s.mu.Unlock()
			cancel()
			continue
		}
		s.cancel = cancel
		s.mu.Unlock()
		result, err := s.evaluate(ctx, r.Enrollment, time.Now())
		cancel()
		var decision hostRotationDecision
		if err == nil && (len(result) > 65536 || json.Unmarshal(result, &decision) != nil ||
			decision.Version != 1 || (decision.Decision != "rotate" && decision.Decision != "hold" && decision.Decision != "abstain")) {
			err = errors.New("invalid host policy result")
		}
		s.mu.Lock()
		s.cancel = nil
		if s.record.Generation != r.Generation || !s.record.Enabled {
			s.mu.Unlock()
			continue
		}
		s.record.NextEvaluationMS = 0
		s.record.Fingerprint = ""
		if err != nil {
			s.record.State = "evaluation_unavailable"
			s.record.Decision = nil
			s.record.Preparation = nil
		} else if fromTimer && (decision.Schedule == nil || decision.Schedule.Fingerprint != scheduledFingerprint) {
			s.record.State = "stale_deadline_cancelled"
			s.record.Decision = nil
			s.record.Preparation = nil
		} else {
			s.record.State = "evaluated"
			s.record.Decision = bytes.Clone(result)
			if schedule := decision.Schedule; schedule != nil && len(schedule.Fingerprint) == 64 && schedule.NextEvaluationMS != nil {
				next := *schedule.NextEvaluationMS
				// The reviewed policy returns future-only, bounded deadlines.
				// Reject malformed results instead of creating a busy loop.
				now := time.Now().UnixMilli()
				if next > now && next-now <= int64(24*time.Hour/time.Millisecond) {
					s.record.NextEvaluationMS = next
					s.record.Fingerprint = schedule.Fingerprint
				}
			}
		}
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			s.record.NextEvaluationMS = 0
			s.record.Fingerprint = ""
		}
		if s.record.Enabled && s.record.NextEvaluationMS > 0 {
			scheduledGeneration = s.record.Generation
			scheduledFingerprint = s.record.Fingerprint
			delay := time.Until(time.UnixMilli(s.record.NextEvaluationMS))
			if delay < 0 {
				delay = 0
			}
			timer.Reset(delay)
			timerC = timer.C
		}
		shouldPrepare := s.record.Enabled && s.record.State == "evaluated" && decision.Decision == "rotate" && s.prepare != nil
		s.mu.Unlock()
		if shouldPrepare {
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timerC = nil
			s.prepareCurrent(r.Generation, r.Enrollment)
		}
	}
}

type rotationBoundedOutput struct{ bytes.Buffer }

func (b *rotationBoundedOutput) Write(p []byte) (int, error) {
	if len(p) > 262144-b.Len() {
		return 0, errors.New("host rotation output exceeds limit")
	}
	return b.Buffer.Write(p)
}

func hostRotationCommand(ctx context.Context, binary string, args []string, input []byte) ([]byte, error) {
	command := exec.CommandContext(ctx, binary, args...)
	command.Stdin = bytes.NewReader(input)
	var output rotationBoundedOutput
	command.Stdout = &output
	command.Stderr = io.Discard
	command.WaitDelay = time.Second
	if err := command.Run(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func readHostRotationLedgerStatus(ctx context.Context, e hostRotationEnrollment) (json.RawMessage, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	request, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": map[string]any{"name": "ledger_op", "arguments": map[string]any{"op": "rotation_status",
			"args": map[string]any{"v": 1, "session_id": e.SessionID}}}})
	raw, err := hostRotationCommand(ctx, filepath.Join(home, ".claude", "bin", "chitta"), nil, append(request, '\n'))
	if err != nil {
		return nil, err
	}
	var response struct {
		Error  json.RawMessage `json:"error"`
		Result struct {
			IsError    bool `json:"isError"`
			Structured struct {
				Value json.RawMessage `json:"value"`
			} `json:"structured"`
		} `json:"result"`
	}
	if json.Unmarshal(raw, &response) != nil || (len(response.Error) > 0 && string(response.Error) != "null") || response.Result.IsError {
		return nil, errors.New("host rotation ledger unavailable")
	}
	status := response.Result.Structured.Value
	var identity struct {
		Version   int    `json:"v"`
		SessionID string `json:"session_id"`
		Client    string `json:"client"`
		Owner     string `json:"owner"`
		CWD       string `json:"cwd"`
	}
	if len(status) == 0 || json.Unmarshal(status, &identity) != nil || identity.Version != 1 ||
		identity.SessionID != e.SessionID || identity.Client != e.Client || identity.CWD != e.CWD || identity.Owner != "relay" {
		return nil, errors.New("host rotation ledger identity changed")
	}
	return status, nil
}

func evaluateHostRotationStatus(ctx context.Context, status json.RawMessage, now time.Time) (json.RawMessage, error) {
	digest := sha256.Sum256(hostRotationPolicy)
	if hex.EncodeToString(digest[:]) != hostRotationPolicySHA {
		return nil, errors.New("host rotation policy changed")
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		return nil, err
	}
	decision, err := hostRotationCommand(ctx, python, []string{"-I", "-S", "-c", string(hostRotationPolicy),
		"--now-ms", strconv.FormatInt(now.UnixMilli(), 10)}, status)
	if err != nil {
		return nil, err
	}
	return decision, nil
}

func evaluateHostRotation(ctx context.Context, e hostRotationEnrollment, now time.Time) (json.RawMessage, error) {
	if err := verifyHostRotationEnrollment(e); err != nil {
		return nil, err
	}
	status, err := readHostRotationLedgerStatus(ctx, e)
	if err != nil {
		return nil, err
	}
	decision, err := evaluateHostRotationStatus(ctx, status, now)
	if err != nil {
		return nil, err
	}
	if err := verifyHostRotationEnrollment(e); err != nil {
		return nil, err
	}
	return decision, nil
}

func verifyHostRotationEnrollment(e hostRotationEnrollment) error {
	_, err := readHostRotationEnrollmentBinding(e)
	return err
}

// Return the association from the same worker/provider observation. Source
// collection uses this observation before and after its bounded file read.
func readHostRotationEnrollmentBinding(e hostRotationEnrollment) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	if !validSessionID.MatchString(e.PaneID) || !validSessionID.MatchString(e.SessionID) ||
		(e.Client != "claude" && e.Client != "codex") || !filepath.IsAbs(e.CWD) || len(e.CWD) > 4096 ||
		e.AgentPID <= 1 || e.AgentStart == 0 || e.WorkerPID <= 1 || e.WorkerStart == 0 || e.NodeBootID == "" {
		return empty, errors.New("invalid host rotation enrollment")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(e.PaneID))
	if err != nil || manifest.SessionID != e.PaneID || manifest.WorkerPID != e.WorkerPID ||
		manifest.WorkerStartTime != e.WorkerStart || manifest.NodeBootID != e.NodeBootID || validateWorkerIdentity(manifest) != nil {
		return empty, errors.New("host rotation worker identity changed")
	}
	binding, err := ReadNativeAgentBinding(e.PaneID)
	if err != nil || binding.SessionID != e.SessionID || binding.Producer.Provider != e.Client ||
		binding.Producer.ProcessID != e.AgentPID || binding.Producer.ProcessStart != e.AgentStart {
		return empty, errors.New("host rotation provider identity changed")
	}
	return binding, nil
}

// Reject ambiguous envelopes and fields outside this RPC's supported surface.
func decodeHostRotationRequest(data []byte) (hostRotationRequest, error) {
	var request hostRotationRequest
	if len(data) > 65536 || !rotationSourceJSONUnambiguous(data) {
		return request, errors.New("invalid host rotation request")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || request.Version != 1 {
		return request, errors.New("invalid host rotation request")
	}
	emptyNative := request.SessionID == "" && request.Client == "" && request.CWD == "" &&
		request.AgentPID == 0 && request.AgentStart == 0
	emptyCredential := request.CredentialReference == "" && request.CredentialSecret == "" && request.CredentialAccountID == ""
	emptyText := len(request.TextSettings) == 0 && request.TextOperationID == "" && emptyCredential
	valid := false
	switch request.Operation {
	case "status", "native_candidate":
		valid = request.ID == "" && emptyNative && emptyText
	case "enroll":
		valid = validPromptEditorID(request.ID) && validSessionID.MatchString(request.SessionID) &&
			(request.Client == "claude" || request.Client == "codex") &&
			filepath.IsAbs(request.CWD) && len(request.CWD) <= 4096 && !bytes.ContainsRune([]byte(request.CWD), 0) &&
			request.AgentPID > 1 && request.AgentStart > 0 && emptyText
	case "disable":
		valid = validPromptEditorID(request.ID) && emptyNative && emptyText
	case "text_status":
		valid = request.ID == "" && emptyNative && len(request.TextSettings) == 0 &&
			(request.TextOperationID == "" || validPromptEditorID(request.TextOperationID))
	case "text_configure":
		valid = validPromptEditorID(request.ID) && emptyNative && len(request.TextSettings) > 0 && request.TextOperationID == ""
	case "text_abandon":
		valid = request.ID == "" && emptyNative && len(request.TextSettings) == 0 && validPromptEditorID(request.TextOperationID)
	case "text_credential_list":
		valid = request.ID == "" && emptyNative && emptyText
	case "text_credential_save", "text_credential_status", "text_credential_delete":
		valid = request.ID == "" && emptyNative && len(request.TextSettings) == 0 &&
			request.TextOperationID == "" && validPromptEditorID(request.CredentialReference) &&
			((request.Operation == "text_credential_save") == (request.CredentialSecret != "")) &&
			((request.Operation == "text_credential_save" && validPromptEditorID(request.CredentialAccountID)) ||
				(request.Operation != "text_credential_save" && request.CredentialAccountID == ""))
	}
	if request.Operation != "text_credential_save" && request.Operation != "text_credential_status" &&
		request.Operation != "text_credential_delete" && request.Operation != "text_credential_list" && !emptyCredential {
		valid = false
	}
	if !valid {
		return request, errors.New("invalid host rotation request")
	}
	return request, nil
}

type hostRotationRPCServices struct {
	readCandidate func(context.Context, string) (hostRotationNativeCandidate, error)
	textService   func(context.Context, string, string, any) (json.RawMessage, error)
}

func serveHostRotationRequest(connection net.Conn, writer *protocol.Writer, hello protocol.HelloPayload, session *Session, config WorkerConfig) {
	serveHostRotationRequestWithServices(connection, writer, hello, session, config,
		hostRotationRPCServices{readHostRotationNativeCandidate, hostRotationTextService})
}

func serveHostRotationRequestWithServices(connection net.Conn, writer *protocol.Writer, hello protocol.HelloPayload,
	session *Session, config WorkerConfig, services hostRotationRPCServices) {
	reply := func(v any) {
		f, err := protocol.JSONFrame(protocol.Status, v)
		if err == nil {
			_ = writer.Write(f)
		}
	}
	uid, _, err := PeerCredentials(connection)
	req, decodeErr := decodeHostRotationRequest(hello.HostRotation)
	if err != nil || uid != os.Getuid() || decodeErr != nil {
		reply(map[string]any{"state": "refused"})
		return
	}
	session.mu.Lock()
	supervisor := session.hostRotation
	session.mu.Unlock()
	if supervisor == nil {
		reply(map[string]any{"state": "unsupported"})
		return
	}
	if req.Operation == "status" {
		reply(supervisor.snapshot())
		return
	}
	textReply := func(operation string, args any) {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		value, err := services.textService(ctx, filepath.Dir(config.ManifestPath), operation, args)
		if err != nil {
			reply(map[string]any{"state": "refused", "message": err.Error()})
			return
		}
		if operation == "status" || operation == "configure" {
			var status map[string]any
			if json.Unmarshal(value, &status) == nil && status != nil {
				status["credential_support"] = "v1"
				value, _ = json.Marshal(status)
			}
		}
		reply(value)
	}
	if req.Operation == "text_credential_status" || req.Operation == "text_credential_list" {
		ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		defer cancel()
		operation := "status"
		if req.Operation == "text_credential_list" {
			operation = "list"
		}
		value, err := hostRotationCredentialIndexService(ctx, filepath.Dir(config.ManifestPath),
			operation, req.CredentialReference, "", "")
		if err != nil {
			reply(map[string]any{"state": "refused", "message": err.Error()})
		} else {
			reply(value)
		}
		return
	}
	if req.Operation == "text_status" {
		textReply("status", map[string]any{"operation_id": req.TextOperationID})
		return
	}

	// Native directory discovery is read-only and runs outside the input mutex.
	// Enroll derives its directory independently of the UI's shell working directory.
	var candidate hostRotationNativeCandidate
	var inputRevision uint64
	if req.Operation == "enroll" {
		if !validPromptEditorID(req.ID) || !session.promptEditorControlIsCurrent(hello.ClientID) {
			reply(map[string]any{"state": "refused", "message": "current terminal input lease and operation identity required"})
			return
		}
		session.inputMu.Lock()
		inputRevision = session.humanInputRevision
		session.inputMu.Unlock()
	}
	if req.Operation == "native_candidate" || req.Operation == "enroll" {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		candidate, err = services.readCandidate(ctx, config.SessionID)
		cancel()
		if err != nil {
			reply(map[string]any{"state": "refused", "message": err.Error()})
			return
		}
		if req.Operation == "native_candidate" {
			reply(candidate)
			return
		}
		if !candidate.matches(req, config.SessionID) {
			reply(map[string]any{"state": "refused", "message": "enrollment differs from the verified native session"})
			return
		}
	}

	if !session.promptEditorControlIsCurrent(hello.ClientID) {
		reply(map[string]any{"state": "refused", "message": "current terminal input lease required"})
		return
	}
	if req.Operation == "text_credential_save" || req.Operation == "text_credential_delete" {
		session.inputMu.Lock()
		current := session.promptEditorControlIsCurrent(hello.ClientID)
		session.inputMu.Unlock()
		if !current {
			reply(map[string]any{"state": "refused", "message": "terminal input lease changed"})
			return
		}
		operation := "save"
		if req.Operation == "text_credential_delete" {
			operation = "delete"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		defer cancel()
		value, err := hostRotationCredentialIndexService(ctx, filepath.Dir(config.ManifestPath),
			operation, req.CredentialReference, req.CredentialAccountID, req.CredentialSecret)
		if err != nil {
			reply(map[string]any{"state": "refused", "message": err.Error()})
		} else {
			reply(value)
		}
		return
	}
	// These host-wide settings require the current pane lease at acceptance.
	// The text service performs no terminal input. Release the input lock before
	// its subprocess/journal work so saving settings never holds up human typing.
	if req.Operation == "text_configure" || req.Operation == "text_abandon" {
		session.inputMu.Lock()
		current := session.promptEditorControlIsCurrent(hello.ClientID)
		session.inputMu.Unlock()
		if !current {
			reply(map[string]any{"state": "refused", "message": "terminal input lease changed"})
			return
		}
		if req.Operation == "text_configure" {
			textReply("configure", map[string]any{"operation_id": req.ID, "settings": req.TextSettings})
		} else {
			textReply("abandon", map[string]any{"operation_id": req.TextOperationID})
		}
		return
	}

	// Serialize enrollment against human input; normal input immediately
	// disables the monitor rather than being blocked by the monitor.
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	if !session.promptEditorControlIsCurrent(hello.ClientID) {
		reply(map[string]any{"state": "refused", "message": "terminal input lease changed"})
		return
	}

	if req.Operation == "enroll" && session.humanInputRevision != inputRevision {
		reply(map[string]any{"state": "refused", "message": "human input arrived during enrollment; read status before enabling again"})
		return
	}

	e := hostRotationEnrollment{}
	if req.Operation == "enroll" {
		manifest, readErr := loadManifest(config.ManifestPath)
		if readErr != nil || req.CWD == "" || !filepath.IsAbs(req.CWD) || len(req.CWD) > 4096 ||
			!validSessionID.MatchString(req.SessionID) || (req.Client != "claude" && req.Client != "codex") ||
			req.AgentPID <= 1 || req.AgentStart == 0 {
			reply(map[string]any{"state": "refused", "message": "invalid enrollment"})
			return
		}
		e = hostRotationEnrollment{SessionID: req.SessionID, Client: req.Client, CWD: req.CWD,
			PaneID: config.SessionID, AgentPID: req.AgentPID, AgentStart: req.AgentStart,
			WorkerPID: manifest.WorkerPID, WorkerStart: manifest.WorkerStartTime, NodeBootID: manifest.NodeBootID}
		if err := candidate.verifyEnrollment(e); err != nil {
			reply(map[string]any{"state": "refused", "message": err.Error()})
			return
		}
	}
	if err := supervisor.configure(req, e); err != nil {
		reply(map[string]any{"state": "refused", "message": err.Error()})
		return
	}
	reply(supervisor.snapshot())
}

// CallHostRotation contacts only an existing worker. Probe makes older workers
// return readiness without attaching an input controller or starting anything.
func CallHostRotation(pane, clientID string, request json.RawMessage) (json.RawMessage, error) {
	if !validSessionID.MatchString(pane) || len(request) > 65536 {
		return nil, errors.New("invalid host rotation request")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return nil, errors.New("host rotation worker unavailable")
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	uid, pid, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || pid != manifest.WorkerPID {
		return nil, errors.New("host rotation socket changed")
	}
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion,
		SessionID: pane, WorkerToken: manifest.Token, ClientID: clientID, Probe: true, HostRotation: request})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return nil, err
	}
	response, err := protocol.ReadFrame(connection)
	if err != nil || response.Type != protocol.Status {
		return nil, errors.New("host rotation response unavailable")
	}
	return json.RawMessage(response.Payload), nil
}
