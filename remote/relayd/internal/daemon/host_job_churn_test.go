package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func waitHostJob(t *testing.T, s *Server, id string) {
	t.Helper()
	value, ok := s.hostJobs.Load(id)
	if !ok {
		t.Fatal("job not tracked")
	}
	job := value.(*hostJob)
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for {
		job.mu.Lock()
		done := job.record.State == "exited" || job.record.State == "failed"
		job.mu.Unlock()
		if done {
			return
		}
		select {
		case <-job.notify:
		case <-deadline.C:
			t.Fatal("fixture execution did not finish")
		}
	}
}

// drain reads a job the way RelayHostExecution.capture does: status with
// advancing offsets until a finished job returns no further output.
func drain(t *testing.T, s *Server, id string) string {
	t.Helper()
	var out []byte
	var stdoutOffset, stderrOffset int64
	for i := 0; i < 16; i++ {
		value, err := s.hostRPC(hostRequest{RequestID: "status", Operation: "status", JobID: id,
			StdoutOffset: stdoutOffset, StderrOffset: stderrOffset})
		if err != nil {
			t.Fatal(err)
		}
		snapshot := value.(map[string]any)
		chunk := snapshot["stdout"].([]byte)
		out = append(out, chunk...)
		stdoutOffset, stderrOffset = snapshot["stdout_offset"].(int64), snapshot["stderr_offset"].(int64)
		if state := snapshot["job"].(hostJobRecord).State; (state == "exited" || state == "failed") && len(chunk) == 0 && len(snapshot["stderr"].([]byte)) == 0 {
			return string(out)
		}
	}
	t.Fatal("job never drained")
	return ""
}

// Reads are ordinary jobs: the final status read, in memory or from disk
// after a restart, keeps the record, and the ID stays reserved.
func TestFinishedJobKeepsItsRecordAfterTheFinalRead(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	read := hostRequest{RequestID: "read", Operation: "exec", JobID: "list-job",
		Argv: []string{"/bin/sh", "-c", "printf caller-list"}, Cwd: s.stateDir}
	if _, err := s.startHostJob(read); err != nil {
		t.Fatal(err)
	}
	waitHostJob(t, s, read.JobID)
	if got := drain(t, s, read.JobID); got != "caller-list" {
		t.Fatalf("output %q", got)
	}
	drain(t, s, read.JobID)
	record := filepath.Join(s.stateDir, "host-jobs", read.JobID, "record.json")
	if _, err := os.Stat(record); err != nil {
		t.Fatal("the final read removed the record:", err)
	}
	restarted := &Server{stateDir: s.stateDir}
	if got := drain(t, restarted, read.JobID); got != "caller-list" {
		t.Fatalf("output after restart %q", got)
	}
	if _, err := os.Stat(record); err != nil {
		t.Fatal("a status read from disk removed the record:", err)
	}
	read.Argv = []string{"/must-not-run"}
	if _, err := restarted.startHostJob(read); err == nil {
		t.Fatal("a read job's ID was reusable")
	}
}

func writeArchiveFixture(t *testing.T, root string, record hostJobRecord) string {
	t.Helper()
	directory := filepath.Join(root, "host-jobs", record.JobID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(record)
	if err := os.WriteFile(filepath.Join(directory, "record.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	return directory
}

// The upgrade step moves finished jobs after two minutes. It never touches
// running, unresolved or listener records, and it deletes nothing.
func TestUpgradeArchiveMovesOnlyFinishedNonListenerJobsAfterTheShortCutoff(t *testing.T) {
	if hostJobArchiveAge != 2*time.Minute {
		t.Fatalf("archive age %v", hostJobArchiveAge)
	}
	root := t.TempDir()
	old := time.Now().Add(-3 * time.Minute).UTC().Format(time.RFC3339Nano)
	fresh := time.Now().UTC().Format(time.RFC3339Nano)
	moved := []string{writeArchiveFixture(t, root, hostJobRecord{JobID: "old-exited", State: "exited", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "old-failed", State: "failed", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "old-read", State: "exited", UpdatedAt: old})}
	kept := []string{
		writeArchiveFixture(t, root, hostJobRecord{JobID: "recent", State: "exited", UpdatedAt: fresh}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "running", State: "running", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "starting", State: "starting", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "unknown", State: "unknown_after_daemon_restart", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "listener-kind", Kind: hostJobKindPeerListener, State: "exited", UpdatedAt: old}),
		writeArchiveFixture(t, root, hostJobRecord{JobID: "listener-binding", Listener: &peerListenerBinding{}, State: "exited", UpdatedAt: old}),
	}
	result, err := archiveCompletedHostJobs(root, 0, time.Now().Add(-hostJobArchiveAge))
	if result.Archived != len(moved) || result.Retained != len(kept) || err == nil {
		t.Fatalf("archive: %+v %v", result, err)
	}
	for _, directory := range moved {
		if _, err := os.Stat(filepath.Join(root, "host-jobs-completed", filepath.Base(directory), "record.json")); err != nil {
			t.Fatal("finished job not archived", directory)
		}
	}
	for _, directory := range kept {
		if _, err := os.Stat(filepath.Join(directory, "record.json")); err != nil {
			t.Fatal("protected record moved", directory)
		}
	}
}
