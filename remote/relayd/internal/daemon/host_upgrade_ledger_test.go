package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeUpgradeLedgerRecord(t *testing.T, stateDir string, record hostJobRecord) {
	t.Helper()
	directory := filepath.Join(stateDir, "host-jobs", record.JobID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(record)
	if err := os.WriteFile(filepath.Join(directory, "record.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

// Finished history alone never defers an upgrade: 5000 exited/failed records
// (over the former 4096-entry ledger refusal) plus one unresolved job report
// exactly that one blocker. Unfinished records stay capped, the scan stays
// inside its time budget, and an invalid entry still blocks.
func TestHostUpgradeIgnoresFinishedLedgerHistory(t *testing.T) {
	stateDir := t.TempDir()
	for i := 0; i < 5000; i++ {
		state := "exited"
		if i%2 == 1 {
			state = "failed"
		}
		writeUpgradeLedgerRecord(t, stateDir, hostJobRecord{JobID: fmt.Sprintf("done-%05d", i), State: state})
	}
	// PID 0 has no verifiable incarnation, so the job is unresolved.
	writeUpgradeLedgerRecord(t, stateDir, hostJobRecord{JobID: "still-running", State: "running"})
	s := &Server{stateDir: stateDir}
	err := s.prepareHostUpgrade()
	if err == nil || !strings.Contains(err.Error(), "upgrade deferred: 1 active or unresolved host jobs") {
		t.Fatalf("want exactly one blocker, got %v", err)
	}
	if err := os.RemoveAll(filepath.Join(stateDir, "host-jobs", "still-running")); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("finished history alone deferred the upgrade: %v", err)
	}
	t.Logf("scanned 5000 finished records in %v (budget %v)", time.Since(started), hostUpgradeScanBudget)

	t.Run("unfinished cap", func(t *testing.T) {
		previous := hostUpgradeUnfinishedLimit
		hostUpgradeUnfinishedLimit = 2
		t.Cleanup(func() { hostUpgradeUnfinishedLimit = previous })
		dir := t.TempDir()
		for i := 0; i < 3; i++ {
			writeUpgradeLedgerRecord(t, dir, hostJobRecord{JobID: fmt.Sprintf("open-%d", i), State: "starting"})
		}
		if err := (&Server{stateDir: dir}).prepareHostUpgrade(); err == nil || err.Error() != "host job ledger exceeds upgrade inspection limit" {
			t.Fatalf("unfinished cap: %v", err)
		}
	})
	t.Run("time budget", func(t *testing.T) {
		previous := hostUpgradeScanBudget
		hostUpgradeScanBudget = -time.Second
		t.Cleanup(func() { hostUpgradeScanBudget = previous })
		if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "time budget") {
			t.Fatalf("time budget: %v", err)
		}
	})
	t.Run("invalid entry", func(t *testing.T) {
		dir := t.TempDir()
		writeUpgradeLedgerRecord(t, dir, hostJobRecord{JobID: "done", State: "exited"})
		if err := os.WriteFile(filepath.Join(dir, "host-jobs", "done", "record.json"), []byte("{"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := (&Server{stateDir: dir}).prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "invalid host job reservation") {
			t.Fatalf("invalid entry: %v", err)
		}
	})
}
