package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// serviceJobs is one host RPC round trip to the supervisor serving now. The
// upgrade client uses only operations every recent supervisor serves over the
// node stream: exec, status and cancel.
type serviceJobs interface {
	call(request hostRequest) (json.RawMessage, error)
}

// serviceRPCError separates a supervisor's answer from a lost round trip.
// A refusal is a definite outcome: an exec refused was not started. A lost
// round trip leaves the outcome unknown, so the same job ID must be queried
// before anything is sent again.
type serviceRPCError struct {
	refused bool
	// unavailable: no supervisor took the request. That says nothing about
	// the service, so it never records a launch as failed.
	unavailable bool
	message     string
}

func (e *serviceRPCError) Error() string { return e.message }

func serviceUnavailable(err error) bool {
	var rpc *serviceRPCError
	return errors.As(err, &rpc) && rpc.unavailable
}

func serviceRefused(err error) (string, bool) {
	var rpc *serviceRPCError
	if errors.As(err, &rpc) && rpc.refused {
		return rpc.message, true
	}
	return "", false
}

// socketServiceJobs dials the supervisor socket for each request, so it keeps
// working across the supervisor replacement.
type socketServiceJobs struct {
	socket  string
	timeout time.Duration
}

func (c socketServiceJobs) call(request hostRequest) (json.RawMessage, error) {
	connection, err := net.DialTimeout("unix", c.socket, 2*time.Second)
	if err != nil {
		// Nothing was sent, so nothing was started.
		return nil, &serviceRPCError{refused: true, unavailable: true, message: "supervisor unavailable: " + err.Error()}
	}
	defer connection.Close()
	if err := RequirePeerUID(connection, os.Getuid()); err != nil {
		return nil, &serviceRPCError{refused: true, message: err.Error()}
	}
	timeout := c.timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	_ = connection.SetDeadline(time.Now().Add(timeout))
	return serviceNodeRoundTrip(connection, request)
}

// serviceNodeRoundTrip speaks the node multiplex stream: a NodeMux hello and
// then top-level host requests, answered by host responses with the same
// request ID. Other frames the supervisor may interleave are skipped.
func serviceNodeRoundTrip(connection net.Conn, request hostRequest) (json.RawMessage, error) {
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, NodeMux: true})
	if err := writer.Write(hello); err != nil {
		return nil, &serviceRPCError{refused: true, unavailable: true, message: "supervisor handshake failed: " + err.Error()}
	}
	frame, err := protocol.JSONFrame(protocol.HostRequest, request)
	if err != nil {
		return nil, &serviceRPCError{refused: true, message: err.Error()}
	}
	if err := writer.Write(frame); err != nil {
		return nil, &serviceRPCError{message: "host request outcome unknown: " + err.Error()}
	}
	for i := 0; i < 256; i++ {
		reply, err := protocol.ReadFrame(connection)
		if err != nil {
			return nil, &serviceRPCError{message: "host response unavailable; outcome unknown: " + err.Error()}
		}
		if reply.Type != protocol.HostResponse {
			continue
		}
		var response struct {
			RequestID string          `json:"request_id"`
			Result    json.RawMessage `json:"result"`
			Error     string          `json:"error"`
		}
		if json.Unmarshal(reply.Payload, &response) != nil {
			return nil, &serviceRPCError{message: "invalid host response; outcome unknown"}
		}
		if response.RequestID != request.RequestID {
			continue
		}
		if response.Error != "" {
			return nil, &serviceRPCError{refused: true, message: response.Error}
		}
		return response.Result, nil
	}
	return nil, &serviceRPCError{message: "no matching host response; outcome unknown"}
}

func serviceRequestID() string {
	var raw [12]byte
	_, _ = rand.Read(raw[:])
	return "svc-" + hex.EncodeToString(raw[:])
}

type serviceJobStatus struct {
	known   bool
	record  hostJobRecord
	process string
}

// live is true while the job's process may still run.
func (s serviceJobStatus) live() bool {
	if !s.known {
		return false
	}
	switch s.record.State {
	case "exited", "failed":
		return false
	case "running", "starting":
		return true
	}
	return s.process != "absent" && s.process != "replaced"
}

func serviceStatus(jobs serviceJobs, jobID string) (serviceJobStatus, error) {
	raw, err := jobs.call(hostRequest{RequestID: serviceRequestID(), Operation: "status", JobID: jobID})
	if err != nil {
		if message, refused := serviceRefused(err); refused && strings.Contains(message, "unknown job") {
			return serviceJobStatus{}, nil
		}
		return serviceJobStatus{}, err
	}
	var snapshot struct {
		Job     hostJobRecord `json:"job"`
		Process string        `json:"process_state"`
	}
	if json.Unmarshal(raw, &snapshot) != nil || snapshot.Job.JobID != jobID {
		return serviceJobStatus{}, fmt.Errorf("invalid status for job %s", jobID)
	}
	return serviceJobStatus{known: true, record: snapshot.Job, process: snapshot.Process}, nil
}

// ServiceLedgerJob is a live host job found in the ledger.
type ServiceLedgerJob struct {
	JobID   string `json:"job_id"`
	PID     int    `json:"pid,omitempty"`
	Kind    string `json:"kind"`
	State   string `json:"state"`
	Process string `json:"process_state"`
}

func (j ServiceLedgerJob) describe() string {
	return fmt.Sprintf("%s (pid %d, kind %s, %s)", j.JobID, j.PID, j.Kind, j.State)
}

// scanLiveHostJobs reads the ledger as the supervisor's upgrade guard does:
// unfinished records whose recorded process may still run. It is advisory;
// the running supervisor still makes the decision.
func scanLiveHostJobs(stateDir string) ([]ServiceLedgerJob, error) {
	root := filepath.Join(stateDir, "host-jobs")
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot inspect host jobs: %w", err)
	}
	if len(entries) > hostUpgradeLedgerEntryLimit {
		return nil, errors.New("host job ledger exceeds upgrade inspection limit")
	}
	deadline := time.Now().Add(hostUpgradeScanBudget)
	var live []ServiceLedgerJob
	unfinished := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if time.Now().After(deadline) {
			return nil, errors.New("host job ledger inspection exceeded its time budget")
		}
		name := entry.Name()
		if !validSessionID.MatchString(name) {
			return nil, errors.New("invalid host job ledger entry")
		}
		path := filepath.Join(root, name, "record.json")
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			live = append(live, ServiceLedgerJob{JobID: name, Kind: "unknown", State: "unreadable", Process: "unknown"})
			continue
		}
		data, err := os.ReadFile(path)
		var record hostJobRecord
		if err != nil || json.Unmarshal(data, &record) != nil || record.JobID != name {
			live = append(live, ServiceLedgerJob{JobID: name, Kind: "unknown", State: "invalid", Process: "unknown"})
			continue
		}
		if record.State == "exited" || record.State == "failed" {
			continue
		}
		if unfinished++; unfinished > hostUpgradeUnfinishedLimit {
			return nil, errors.New("host job ledger exceeds upgrade inspection limit")
		}
		process := hostJobProcessState(record)
		if process == "absent" || process == "replaced" {
			continue
		}
		kind := record.Kind
		if kind == "" {
			kind = "exec"
		}
		live = append(live, ServiceLedgerJob{JobID: name, PID: record.PID, Kind: kind, State: record.State, Process: process})
	}
	return live, nil
}

// DescribeLiveHostJobs names the live host jobs that defer an upgrade, for a
// refusal message. Peer listeners are left out: the supervisor drains them.
func DescribeLiveHostJobs(stateDir string) (string, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	jobs, err := scanLiveHostJobs(stateDir)
	if err != nil {
		return "", err
	}
	var names []string
	for _, job := range jobs {
		if job.Kind != hostJobKindPeerListener {
			names = append(names, job.describe())
		}
	}
	return strings.Join(names, ", "), nil
}
