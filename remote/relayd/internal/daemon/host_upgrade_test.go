package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHostUpgradeBarrierRejectsNewExecution(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatal(err)
	}
	if !time.Now().Before(s.hostUpgradeUntil) {
		t.Fatal("missing upgrade barrier")
	}
	_, err := s.startHostJob(hostRequest{JobID: "job-test", Argv: []string{"/must-not-execute"}})
	if err == nil || !strings.Contains(err.Error(), "handoff in progress") {
		t.Fatalf("execution not blocked: %v", err)
	}
}

func TestHostUpgradeBlocksRunningAndUnknownReservations(t *testing.T) {
	for _, state := range []string{"starting", "running"} {
		t.Run(state, func(t *testing.T) {
			s := &Server{stateDir: t.TempDir()}
			s.hostJobs.Store("job-test", &hostJob{record: hostJobRecord{State: state}})
			if err := s.prepareHostUpgrade(); err == nil {
				t.Fatal("active job did not block")
			}
			if !s.hostUpgradeUntil.IsZero() {
				t.Fatal("failed upgrade armed barrier")
			}
		})
	}
	for _, state := range []string{"running", "unknown_after_daemon_restart"} {
		t.Run("ledger-"+state, func(t *testing.T) {
			s := &Server{stateDir: t.TempDir()}
			dir := filepath.Join(s.stateDir, "host-jobs", "job-test")
			if err := os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(hostJobRecord{JobID: "job-test", State: state, PID: os.Getpid()})
			if err := os.WriteFile(filepath.Join(dir, "record.json"), data, 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.prepareHostUpgrade(); err == nil {
				t.Fatal("live reservation did not block")
			}
		})
	}
}
