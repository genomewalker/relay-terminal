package daemon

import (
	"errors"
	"os"
)

// This is a local admission gate, not a reconstructed native capability. Every
// active transaction, including one with unreadable evidence, blocks preparation.
// A missing root is clean only when its worker directory is still verified.
func inspectHostNativeSupervisorJournal(workerDirectory string, e hostRotationEnrollment) string {
	if workerDirectory == "" || e.Client != "codex" {
		return ""
	}
	if !validHostNativeUUID(e.SessionID) {
		return "invalid_source"
	}
	if err := privateBindingObject(workerDirectory, true); err != nil {
		return "journal_unavailable"
	}
	root, err := openHostRotationPrivateRoot(workerDirectory, hostNativeClaimDirectory, false)
	if errors.Is(err, os.ErrNotExist) {
		if privateBindingObject(workerDirectory, true) != nil {
			return "journal_unavailable"
		}
		return ""
	}
	if err != nil {
		return "journal_unavailable"
	}
	root.Close()
	snapshot, err := readHostNativeClaimSnapshot(workerDirectory, e.SessionID)
	if err != nil {
		return "journal_unavailable"
	}
	if snapshot == nil {
		return ""
	}
	if snapshot.request.Source.Enrollment != e {
		return "source_mismatch"
	}
	if snapshot.commitPending {
		return "commit_pending"
	}
	return "claim_pending"
}

// Called before enabled/deadline checks. Save status only on change, preserving
// disable/human-takeover state. Clearing a fence triggers a fresh evaluation.
func (s *hostRotationSupervisor) gateNativeJournal() bool {
	if s.nativeWorkerDirectory == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state := inspectHostNativeSupervisorJournal(s.nativeWorkerDirectory, s.record.Enrollment)
	changed := s.record.NativeRecoveryState != state
	s.record.NativeRecoveryState = state
	if state != "" {
		if s.record.Enabled && s.record.State != "native_recovery_pending" {
			s.record.State = "native_recovery_pending"
			changed = true
		}
		if s.record.NextEvaluationMS != 0 || s.record.Fingerprint != "" ||
			len(s.record.Decision) != 0 || s.record.Preparation != nil {
			s.record.NextEvaluationMS = 0
			s.record.Fingerprint = ""
			s.record.Decision = nil
			s.record.Preparation = nil
			changed = true
		}
	} else if s.record.Enabled && s.record.State == "native_attempt_pending" {
		// Admission may fail before creating a journal. Wait for fresh activity
		// instead of repeatedly drafting against an unavailable foreground.
		s.record.State = "native_attempt_unavailable"
		changed = true
	} else if s.record.Enabled && s.record.State == "native_recovery_pending" {
		s.record.State = "pending_evaluation"
		changed = true
		s.notify()
	}
	if changed {
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			return true
		}
	}
	return state != ""
}
