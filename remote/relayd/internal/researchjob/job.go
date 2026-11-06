// Package researchjob is the research-turn lifecycle (P3): it admits a
// request once, runs one dedicated worker for it in the background, and keeps
// a durable record that maps request_id -> job_id -> turn_id and ends in
// exactly one terminal state.
//
// States: admitted -> running -> completed | failed | cancelled | timeout.
// "unknown" is reported when a non-terminal job has no live runner and no
// worker receipt (for example after a restart): its outcome is unknown and it
// is never started again.
//
// Admission is idempotent on request_id: the same request (same contract,
// provider, model, effort, prompt, budget and launch) returns the existing job
// and starts nothing; a different request under the same request_id is
// refused. Query and cancel take only an exact job_id (or request_id for
// query). One Manager owns a jobs root at a time.
package researchjob

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/researchworker"
)

const (
	StateAdmitted  = "admitted"
	StateRunning   = "running"
	StateCompleted = "completed"
	StateFailed    = "failed"
	StateCancelled = "cancelled"
	StateTimeout   = "timeout"
	StateUnknown   = "unknown"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

var (
	ErrNotFound    = errors.New("no job with that exact ID")
	ErrInvalidID   = errors.New("IDs are lowercase UUIDs")
	ErrBoundToMore = errors.New("request_id is already admitted for a different request; refused")
)

func Terminal(state string) bool {
	switch state {
	case StateCompleted, StateFailed, StateCancelled, StateTimeout:
		return true
	}
	return false
}

type Cost struct {
	USD    *float64 `json:"usd"`
	Status string   `json:"status"`
	Detail string   `json:"detail,omitempty"`
}

type Job struct {
	Version           int                      `json:"version"`
	JobID             string                   `json:"job_id"`
	RequestID         string                   `json:"request_id"`
	TurnID            string                   `json:"turn_id,omitempty"` // provider session (Claude) or thread (Codex) ID
	State             string                   `json:"state"`
	Binding           researchworker.Binding   `json:"binding"`
	ContractSHA256    string                   `json:"contract_sha256"`
	AdmittedAt        time.Time                `json:"admitted_at"`
	StartedAt         *time.Time               `json:"started_at,omitempty"`
	EndedAt           *time.Time               `json:"ended_at,omitempty"`
	DurationMS        *int64                   `json:"duration_ms,omitempty"`
	CancelRequestedAt *time.Time               `json:"cancel_requested_at,omitempty"`
	Result            *string                  `json:"result"`
	Failure           string                   `json:"failure,omitempty"`
	EffectiveSettings map[string]any           `json:"effective_settings"`
	Usage             any                      `json:"usage"`
	Cost              Cost                     `json:"cost"`
	Budget            researchworker.BudgetUse `json:"budget"`
	Verified          bool                     `json:"verified"`
	ScopeEnforcement  string                   `json:"scope_enforcement,omitempty"`
	Checks            []researchworker.Check   `json:"checks,omitempty"`
	WorkerDir         string                   `json:"worker_dir,omitempty"`
}

type Manager struct {
	jobsRoot    string
	workersRoot string
	run         func(context.Context, researchworker.Request) (researchworker.Receipt, error)

	mu      sync.Mutex
	running map[string]context.CancelFunc
	done    map[string]chan struct{}
}

func private(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return fmt.Errorf("%s must be a clean absolute path", path)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("%s is not an existing directory", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("%s must be owned by this user and private (0700)", path)
	}
	return nil
}

// NewManager uses jobsRoot for job records and workersRoot for worker folders.
// Both must be private directories owned by this user.
func NewManager(jobsRoot, workersRoot string) (*Manager, error) {
	for _, path := range []string{jobsRoot, workersRoot} {
		if err := private(path); err != nil {
			return nil, err
		}
	}
	for _, sub := range []string{"requests", "jobs"} {
		if err := os.Mkdir(filepath.Join(jobsRoot, sub), 0o700); err != nil && !os.IsExist(err) {
			return nil, err
		}
		if err := private(filepath.Join(jobsRoot, sub)); err != nil {
			return nil, err
		}
	}
	return &Manager{jobsRoot: jobsRoot, workersRoot: workersRoot, run: researchworker.Run, running: map[string]context.CancelFunc{}, done: map[string]chan struct{}{}}, nil
}

func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func (m *Manager) requestPath(requestID string) string {
	return filepath.Join(m.jobsRoot, "requests", requestID+".json")
}

func (m *Manager) indexPath(jobID string) string { return filepath.Join(m.jobsRoot, "jobs", jobID) }

// writeNew creates path exclusively with content, atomically.
func writeNew(path string, content []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".new-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(content); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Link(temp.Name(), path) // fails if path exists
}

// replace atomically replaces path with content.
func replace(path string, content []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := temp.Write(content); err != nil {
		temp.Close()
		os.Remove(temp.Name())
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		os.Remove(temp.Name())
		return err
	}
	if err := temp.Close(); err != nil {
		os.Remove(temp.Name())
		return err
	}
	return os.Rename(temp.Name(), path)
}

func (m *Manager) save(job Job) error {
	encoded, _ := json.MarshalIndent(job, "", "  ")
	return replace(m.requestPath(job.RequestID), encoded)
}

func (m *Manager) load(requestID string) (Job, error) {
	raw, err := os.ReadFile(m.requestPath(requestID))
	if os.IsNotExist(err) {
		return Job{}, ErrNotFound
	}
	if err != nil {
		return Job{}, err
	}
	var job Job
	if err := json.Unmarshal(raw, &job); err != nil || job.RequestID != requestID || !uuidPattern.MatchString(job.JobID) {
		return Job{}, errors.New("job record is damaged")
	}
	return job, nil
}

// Admit admits request once and starts its worker. It returns the job and
// whether this call admitted it. request.WorkersRoot is replaced by the
// manager's workers root.
func (m *Manager) Admit(request researchworker.Request) (Job, bool, error) {
	request.WorkersRoot = m.workersRoot
	binding, err := researchworker.BindingFor(request)
	if err != nil {
		return Job{}, false, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing, err := m.load(request.RequestID); err == nil {
		if existing.Binding != binding {
			return Job{}, false, ErrBoundToMore
		}
		return m.reconcile(existing), false, nil
	} else if !errors.Is(err, ErrNotFound) {
		return Job{}, false, err
	}
	jobID, err := newUUID()
	if err != nil {
		return Job{}, false, err
	}
	job := Job{Version: 1, JobID: jobID, RequestID: request.RequestID, State: StateAdmitted, Binding: binding, ContractSHA256: binding.ContractSHA256,
		AdmittedAt: time.Now().UTC(), Usage: researchworker.USDUnknown, Cost: Cost{Status: researchworker.USDUnknown}}
	encoded, _ := json.MarshalIndent(job, "", "  ")
	if err := writeNew(m.requestPath(job.RequestID), encoded); err != nil {
		if os.IsExist(err) {
			return Job{}, false, errors.New("request_id was admitted concurrently; query it instead")
		}
		return Job{}, false, err
	}
	if err := writeNew(m.indexPath(jobID), []byte(request.RequestID)); err != nil {
		job.State, job.Failure = StateFailed, "could not index the job; nothing was started"
		_ = m.save(job)
		return job, true, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.running[jobID] = cancel
	m.done[jobID] = make(chan struct{})
	go m.execute(ctx, job, request)
	return job, true, nil
}

func (m *Manager) execute(ctx context.Context, job Job, request researchworker.Request) {
	m.mu.Lock()
	started := time.Now().UTC()
	job.State, job.StartedAt = StateRunning, &started
	if current, err := m.load(job.RequestID); err == nil && current.CancelRequestedAt != nil {
		job.CancelRequestedAt = current.CancelRequestedAt
	}
	_ = m.save(job)
	m.mu.Unlock()

	receipt, err := m.run(ctx, request)

	m.mu.Lock()
	defer m.mu.Unlock()
	if current, loadErr := m.load(job.RequestID); loadErr == nil {
		job.CancelRequestedAt = current.CancelRequestedAt
	}
	if err != nil {
		ended := time.Now().UTC()
		job.EndedAt = &ended
		job.State, job.Failure = StateFailed, "worker not started: "+err.Error()
		if errors.Is(err, researchworker.ErrAlreadyAdmitted) {
			job.State, job.Failure = StateUnknown, err.Error()
		}
	} else {
		job = terminal(job, receipt)
	}
	_ = m.save(job)
	cancel := m.running[job.JobID]
	delete(m.running, job.JobID)
	if cancel != nil {
		cancel()
	}
	close(m.done[job.JobID])
}

// terminal maps a worker receipt to the job's terminal record.
func terminal(job Job, receipt researchworker.Receipt) Job {
	job.TurnID = receipt.SessionID
	job.WorkerDir = receipt.WorkerDir
	if !receipt.StartedAt.IsZero() {
		started := receipt.StartedAt
		job.StartedAt = &started
	}
	ended := receipt.EndedAt
	if ended.IsZero() {
		ended = time.Now().UTC()
	}
	job.EndedAt = &ended
	if job.StartedAt != nil {
		duration := ended.Sub(*job.StartedAt).Milliseconds()
		job.DurationMS = &duration
	}
	result := receipt.Result
	job.Result = &result
	job.EffectiveSettings = receipt.Effective
	if receipt.Usage != nil {
		job.Usage = receipt.Usage
	} else {
		job.Usage = researchworker.USDUnknown
	}
	job.Budget = receipt.Budget
	job.Cost = Cost{Status: receipt.Budget.USD.Status, Detail: receipt.Budget.USD.Detail}
	if receipt.CostUSD != nil {
		cost := *receipt.CostUSD
		job.Cost.USD = &cost
	} else {
		job.Cost.Status = researchworker.USDUnknown
	}
	job.Verified, job.ScopeEnforcement, job.Checks = receipt.Verified, receipt.ScopeEnforcement, receipt.Checks
	resultOK := false
	for _, check := range receipt.Checks {
		if check.Name == "result" {
			resultOK = check.Status == researchworker.CheckVerified
		}
	}
	switch {
	case receipt.Cancelled:
		job.State, job.Failure = StateCancelled, "cancelled by request"
	case receipt.TimedOut:
		job.State, job.Failure = StateTimeout, "wall-clock limit reached; the worker was killed"
	case receipt.ExitCode == 0 && resultOK:
		job.State = StateCompleted
	default:
		job.State = StateFailed
		for _, check := range receipt.Checks {
			if check.Status == researchworker.CheckViolated {
				job.Failure = check.Name + ": " + check.Detail
				break
			}
		}
		if job.Failure == "" {
			job.Failure = fmt.Sprintf("worker exit code %d", receipt.ExitCode)
		}
	}
	if job.State != StateCompleted {
		if result == "" {
			job.Result = nil
		}
	}
	return job
}

// reconcile settles a non-terminal record that this manager is not running:
// from the worker's receipt if one exists, otherwise as unknown. Callers hold mu.
func (m *Manager) reconcile(job Job) Job {
	if Terminal(job.State) || job.State == StateUnknown {
		return job
	}
	if _, live := m.running[job.JobID]; live {
		return job
	}
	raw, err := os.ReadFile(filepath.Join(m.workersRoot, job.RequestID, "receipt.json"))
	var receipt researchworker.Receipt
	if err == nil && json.Unmarshal(raw, &receipt) == nil && receipt.Binding == job.Binding {
		job = terminal(job, receipt)
	} else {
		job.State, job.Failure = StateUnknown, "the job's runner stopped before a terminal record; outcome unknown and it is not started again"
	}
	_ = m.save(job)
	return job
}

// Get returns the job with this exact job_id.
func (m *Manager) Get(jobID string) (Job, error) {
	if !uuidPattern.MatchString(jobID) {
		return Job{}, ErrInvalidID
	}
	raw, err := os.ReadFile(m.indexPath(jobID))
	if os.IsNotExist(err) {
		return Job{}, ErrNotFound
	}
	if err != nil || !uuidPattern.Match(raw) {
		return Job{}, errors.New("job index is damaged")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	job, err := m.load(string(raw))
	if err != nil {
		return Job{}, err
	}
	if job.JobID != jobID {
		return Job{}, errors.New("job index does not match its record")
	}
	return m.reconcile(job), nil
}

// GetByRequest returns the job admitted for this exact request_id.
func (m *Manager) GetByRequest(requestID string) (Job, error) {
	if !uuidPattern.MatchString(requestID) {
		return Job{}, ErrInvalidID
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	job, err := m.load(requestID)
	if err != nil {
		return Job{}, err
	}
	return m.reconcile(job), nil
}

// Cancel asks the job with this exact job_id to stop. A running worker is
// killed and the job ends cancelled; a terminal or unknown job is returned
// unchanged. Cancel never starts anything.
func (m *Manager) Cancel(jobID string) (Job, error) {
	job, err := m.Get(jobID)
	if err != nil {
		return Job{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	cancel, live := m.running[jobID]
	if !live {
		return job, nil
	}
	if current, err := m.load(job.RequestID); err == nil {
		job = current
	}
	if job.CancelRequestedAt == nil {
		now := time.Now().UTC()
		job.CancelRequestedAt = &now
		_ = m.save(job)
	}
	cancel()
	return job, nil
}

// Wait blocks until the job is terminal or ctx ends, then returns it.
func (m *Manager) Wait(ctx context.Context, jobID string) (Job, error) {
	if _, err := m.Get(jobID); err != nil {
		return Job{}, err
	}
	m.mu.Lock()
	done, ok := m.done[jobID]
	m.mu.Unlock()
	if ok {
		select {
		case <-done:
		case <-ctx.Done():
			return Job{}, ctx.Err()
		}
	}
	return m.Get(jobID)
}
