package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Verify the legal interleaving between relocation and its snapshot retry:
// the other daemon can clean the archive while the owner's job.mu is held.
// This is a component-level interleaving witness, not a timed hostRPC race.
func TestReviewerRelocatedArchiveCanDisappearBeforeRetry(t *testing.T) {
	stateDir := t.TempDir()
	owner, peer := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-relocation-window", now.Add(-9*24*time.Hour), 6)
	directory := writeLiveJob(t, stateDir, record)
	for name, body := range map[string]string{"stdout": "retained output", "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	job := &hostJob{record: record, directory: directory}
	owner.hostJobs.Store(record.JobID, job)
	if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Archived != 1 || result.Removed != 0 {
		t.Fatalf("archive: %+v %v", result, err)
	}
	activateCleanup(t, peer, now)
	job.mu.Lock()
	defer job.mu.Unlock()
	relocated, found := owner.relocateTrackedHostJob(job)
	if !found {
		t.Fatal("relocation did not find the archive")
	}
	if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Removed != 1 {
		t.Fatalf("peer cleanup while owner mutex held: %+v %v", result, err)
	}
	request := hostRequest{RequestID: "status", Operation: "status", JobID: record.JobID}
	if _, err := hostJobSnapshot(job.record, relocated, request); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected missing retry folder, got %v", err)
	}
	tombstone, found, err := owner.hostJobTombstones().Lookup(record.JobID)
	if err != nil || !found {
		t.Fatalf("durable tombstone was not available: found=%v err=%v", found, err)
	}
	value, err := hostJobTombstoneSnapshot(tombstone, request)
	if err != nil || value.(map[string]any)["output_expired"] != true {
		t.Fatalf("fallback snapshot: %+v %v", value, err)
	}
	t.Log("archive deletion completed while owner job.mu held; retry is ENOENT but tombstone fallback is available")
}

// The disk-backed branch can read a live record just before the peer archives
// its folder. A tombstone-only fallback cannot find this retained output.
func TestReviewerDiskStatusArchiveMoveNeedsReresolution(t *testing.T) {
	stateDir := t.TempDir()
	reader, peer := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-disk-move-window", now.Add(-time.Hour), 4)
	directory := writeLiveJob(t, stateDir, record)
	for name, body := range map[string]string{"stdout": "retained disk output", "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	_, oldDirectory, tombstone, err := reader.readHostJobRecord(record.JobID)
	if err != nil || tombstone != nil || oldDirectory != directory {
		t.Fatalf("initial disk lookup: %s %+v %v", oldDirectory, tombstone, err)
	}
	if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Archived != 1 || result.Removed != 0 {
		t.Fatalf("peer archive: %+v %v", result, err)
	}
	request := hostRequest{RequestID: "status", Operation: "status", JobID: record.JobID}
	if _, err := hostJobSnapshot(record, oldDirectory, request); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old location should be missing: %v", err)
	}
	if _, found, err := reader.hostJobTombstones().Lookup(record.JobID); err != nil || found {
		t.Fatalf("archiving creates no tombstone: found=%v err=%v", found, err)
	}
	_, newDirectory, _, err := reader.readHostJobRecord(record.JobID)
	if err != nil {
		t.Fatal(err)
	}
	value, err := hostJobSnapshot(record, newDirectory, request)
	if err != nil || string(value.(map[string]any)["stdout"].([]byte)) != "retained disk output" {
		t.Fatalf("re-resolved output: %+v %v", value, err)
	}
	t.Log("live record lookup can precede peer archive; original snapshot is ENOENT, no tombstone exists, re-resolution serves retained output")
}
