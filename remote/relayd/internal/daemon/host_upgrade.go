package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Reservations and the upgrade barrier share one lock. A snapshot alone would
// permit a new job to start between the check and supervisor SIGTERM.
func (s *Server) prepareHostUpgrade() error {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	blockers := 0
	known := map[string]bool{}
	s.hostJobs.Range(func(key, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		known[key.(string)] = true
		if job.record.State == "starting" || job.record.State == "running" {
			blockers++
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
		// An old PID may have been reused. Any extant PID blocks the upgrade;
		// only a definitive ESRCH establishes that this old process is gone.
		if record.PID <= 1 || syscall.Kill(record.PID, 0) != syscall.ESRCH {
			blockers++
		}
	}
	if blockers > 0 {
		return fmt.Errorf("upgrade deferred: %d active or unresolved host jobs; terminal workers are unaffected", blockers)
	}
	s.hostUpgradeUntil = time.Now().Add(30 * time.Second)
	return nil
}
