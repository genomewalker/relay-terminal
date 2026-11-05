package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

// A peer listener is a restartable inbox: the next supervisor relaunches it
// from the peer-listener registry. It is exempt from the upgrade guard only while this daemon
// controls it and it has published a ready frame declaring drain support.
const hostJobKindPeerListener = "peer_listener_v1"

// Bounded so the whole preparation stays within the 30-second upgrade probe.
var hostUpgradeListenerDrain = 10 * time.Second

// The handoff barrier. A supervisor still serving when it lapses was not
// replaced, so it resumes the listeners it drained.
var hostUpgradeHandoff = 30 * time.Second

// Reservations and the upgrade barrier share one lock. A snapshot alone would
// permit a new job to start between the check and supervisor SIGTERM.
func (s *Server) prepareHostUpgrade() error {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	blockers := 0
	known := map[string]bool{}
	listeners := []*hostJob{}
	s.hostJobs.Range(func(key, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		known[key.(string)] = true
		if job.record.State == "starting" || job.record.State == "running" {
			if s.verifiedHostListener(job) {
				listeners = append(listeners, job)
			} else {
				blockers++
			}
		}
		job.mu.Unlock()
		return true
	})
	entries, err := os.ReadDir(filepath.Join(s.stateDir, "host-jobs"))
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("cannot inspect host jobs: %w", err)
	}
	if len(entries) > 4096 {
		return errors.New("host job ledger exceeds upgrade inspection limit")
	}
	for _, entry := range entries {
		if !entry.IsDir() || known[entry.Name()] {
			continue
		}
		if !validSessionID.MatchString(entry.Name()) {
			return errors.New("invalid host job ledger entry")
		}
		path := filepath.Join(s.stateDir, "host-jobs", entry.Name(), "record.json")
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			return errors.New("unreadable host job reservation; upgrade blocked")
		}
		data, err := os.ReadFile(path)
		var record hostJobRecord
		if err != nil || json.Unmarshal(data, &record) != nil || record.JobID != entry.Name() {
			return errors.New("invalid host job reservation; upgrade blocked")
		}
		if record.State == "exited" || record.State == "failed" {
			continue
		}
		// Quiescence concerns the recorded process incarnation, not a reused
		// PID. A proven replacement cannot be the old job. Unknown identity
		// still blocks; this does not establish the old execution's outcome
		// or grant permission to rerun it. The ledger remains unchanged.
		switch hostJobProcessState(record) {
		case "absent", "replaced":
		default:
			blockers++
		}
	}
	if blockers > 0 {
		return fmt.Errorf("upgrade deferred: %d active or unresolved host jobs; terminal workers are unaffected", blockers)
	}
	// Only now stop listeners, so a deferred upgrade never disturbs them. They
	// drain one at a time in a fixed order: the first that does not drain
	// cleanly defers the upgrade, and the listeners after it are never touched.
	sort.Slice(listeners, func(i, j int) bool { return listeners[i].record.JobID < listeners[j].record.JobID })
	deadline := time.Now().Add(hostUpgradeListenerDrain)
	drained := 0
	for _, job := range listeners {
		clean, err := s.drainHostListener(job, deadline)
		if err != nil {
			// This supervisor keeps serving: listeners drained so far, and one
			// that failed while draining, resume here from the registry rather
			// than waiting for a successor that is not coming.
			s.resumePeerListenersLocked()
			return fmt.Errorf("upgrade deferred: %v; %d listeners drained before it were resumed here", err, drained)
		}
		if clean {
			drained++
		}
	}
	until := time.Now().Add(hostUpgradeHandoff)
	s.hostUpgradeUntil = until
	// Armed even when nothing drained now: a repeated preparation finds the
	// listeners an earlier one drained still suspended, and owns them.
	time.AfterFunc(hostUpgradeHandoff, func() { s.resumeAfterAbandonedUpgrade(until) })
	return nil
}

// The supervisor has no SIGTERM handler, so a replaced one never gets here.
// A later preparation re-arms the barrier and owns its own resumption.
func (s *Server) resumeAfterAbandonedUpgrade(until time.Time) {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	if s.hostUpgradeUntil.Equal(until) {
		s.resumePeerListenersLocked()
	}
}

// The caller holds job.mu. Every check must hold, otherwise the job blocks.
func (s *Server) verifiedHostListener(job *hostJob) bool {
	record := job.record
	if record.Kind != hostJobKindPeerListener || record.State != "running" || record.Error != "" || job.cmd == nil || job.cmd.Process == nil ||
		record.PID <= 1 || job.cmd.Process.Pid != record.PID || record.ProcessStart == "" {
		return false
	}
	if start, err := processStartIdentity(record.PID); err != nil || start != record.ProcessStart {
		return false
	}
	// The ready frame is the listener's own registration, written to the job's
	// stdout by this daemon. It must name this exact process incarnation.
	file, err := os.Open(filepath.Join(job.directory, "stdout"))
	if err != nil {
		return false
	}
	defer file.Close()
	line, err := bufio.NewReader(io.LimitReader(file, 131073)).ReadBytes('\n')
	if err != nil || len(line) > 131072 {
		return false
	}
	var ready struct {
		Type  string `json:"type"`
		PID   int    `json:"pid"`
		Start string `json:"start"`
		Drain int    `json:"drain"`
	}
	if json.Unmarshal(line, &ready) != nil || ready.Type != "ready" || ready.PID != record.PID ||
		ready.Start != record.ProcessStart || ready.Drain != 1 {
		return false
	}
	// Exempt only a listener the registry can resume.
	return job.listener != nil && s.peerListenerRegistered(job.listener.Route, record.JobID)
}

// Each listener is durably marked suspended before its drain signal, so the
// next supervisor resumes it from the registry. A listener that exited on its
// own since verification has already released its entry: there is nothing to
// drain. The caller holds hostJobsMu.
func (s *Server) drainHostListener(job *hostJob, deadline time.Time) (bool, error) {
	job.mu.Lock()
	if job.record.State != "running" {
		job.mu.Unlock()
		return false, nil
	}
	id, route, pid := job.record.JobID, job.listener.Route, job.cmd.Process.Pid
	if err := s.suspendPeerListener(route, id); err != nil {
		job.mu.Unlock()
		return false, fmt.Errorf("peer listener %s is not resumable: %v", id, err)
	}
	// Signal only the listener itself: it implements the drain, and its
	// short-lived helpers (ps identity probes) must not die mid-check.
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		s.reactivatePeerListenerLocked(job)
		job.mu.Unlock()
		return false, fmt.Errorf("peer listener %s could not be drained: %v", id, err)
	}
	job.mu.Unlock()
	if !waitHostJobExited(job, deadline) {
		// Still running: it keeps its active registration. If it exits later it
		// deregisters, and its client relaunches it.
		job.mu.Lock()
		s.reactivatePeerListenerLocked(job)
		job.mu.Unlock()
		return false, fmt.Errorf("peer listener %s did not drain in time", id)
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	if !cleanHostListenerDrain(job.record) {
		return false, fmt.Errorf("peer listener %s did not drain cleanly: %s", id, hostJobOutcome(job.record))
	}
	return true, nil
}

// Exiting is not draining. Only a zero exit status with no wait, output-copy
// or persistence error shows that every accepted message reached the ledger.
func cleanHostListenerDrain(record hostJobRecord) bool {
	return record.State == "exited" && record.ExitCode != nil && *record.ExitCode == 0 && record.Error == ""
}

func hostJobOutcome(record hostJobRecord) string {
	outcome := record.State
	if record.ExitCode != nil {
		outcome += fmt.Sprintf(" with status %d", *record.ExitCode)
	}
	if record.Error != "" {
		outcome += " (" + record.Error + ")"
	}
	return outcome
}

// A listener still running keeps an active registration. The caller holds
// job.mu.
func (s *Server) reactivatePeerListenerLocked(job *hostJob) {
	if job.record.State != "running" {
		return
	}
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	if entry, err := s.readPeerListenerFile(s.peerListenerPath(job.listener.Route)); err == nil &&
		entry.JobID == job.record.JobID && entry.State == "suspended" {
		entry.State = "active"
		_ = s.writePeerListenerEntry(entry)
	}
}

// Poll rather than consume job.notify, which belongs to status long-polls.
func waitHostJobExited(job *hostJob, deadline time.Time) bool {
	for {
		job.mu.Lock()
		state := job.record.State
		job.mu.Unlock()
		if state == "exited" || state == "failed" {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(25 * time.Millisecond)
	}
}
