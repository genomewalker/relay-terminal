package daemon

import (
	"context"
	"time"
)

type hostNativeSupervisorDriver interface {
	start(context.Context, *hostRotationSupervisor, hostRotationEnrollment, hostRotationPreparation, func() error) (hostNativeDriverResult, error)
	recover(context.Context, *hostRotationSupervisor) (hostNativeDriverResult, error)
}

// No supervisor mutex is held over native/ledger work. The same cancellation
// slot used by preparation/evaluation lets shutdown and takeover stop a call.
func (s *hostRotationSupervisor) recoverNativeJournal() bool {
	if !s.gateNativeJournal() {
		return false
	}
	if s.nativeDriver == nil {
		return true
	}
	snapshot := s.snapshot()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s.mu.Lock()
	select {
	case <-s.done:
		s.mu.Unlock()
		return true
	default:
	}
	if s.record.Enrollment != snapshot.Enrollment || s.record.Generation != snapshot.Generation ||
		s.record.State == "persistence_failed" {
		s.mu.Unlock()
		return true
	}
	s.cancel = cancel
	s.mu.Unlock()
	outcome, err := s.nativeDriver.recover(ctx, s)
	s.mu.Lock()
	s.cancel = nil
	// Finalization owns source-to-target updates. Never overwrite its receipt,
	// enrollment, or evaluation state with the old source's recovery status.
	if s.record.Enrollment == snapshot.Enrollment {
		state := outcome.State
		if (outcome.Pending || err != nil) && state == "" {
			state = "native_recovery_unavailable"
		}
		changed := s.record.NativeRecoveryState != state
		s.record.NativeRecoveryState = state
		if !outcome.Pending && err == nil && s.record.Enabled && s.record.State == "native_recovery_pending" {
			s.record.State = "pending_evaluation"
			changed = true
			s.notify()
		}
		if changed {
			if err := s.saveLocked(); err != nil {
				s.record.Enabled = false
				s.record.State = "persistence_failed"
			}
		}
	}
	s.mu.Unlock()
	return true
}
