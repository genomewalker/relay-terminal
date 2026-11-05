package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCompletedHostJobArchivePreservesOutputAndReservation(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	request := hostRequest{RequestID: "archive-request", Operation: "exec", JobID: "archive-job",
		Argv: []string{"/bin/sh", "-c", "printf archive-proof"}, Cwd: s.stateDir}
	if _, err := s.startHostJob(request); err != nil {
		t.Fatal(err)
	}
	value, _ := s.hostJobs.Load(request.JobID)
	job := value.(*hostJob)
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for {
		job.mu.Lock()
		done := job.record.State == "exited"
		job.mu.Unlock()
		if done {
			break
		}
		select {
		case <-job.notify:
		case <-deadline.C:
			t.Fatal("fixture execution did not finish")
		}
	}
	archived, err := archiveCompletedHostJobs(s.stateDir, 0, time.Now().Add(time.Minute))
	if err != nil || archived.Archived != 1 || archived.Retained != 0 {
		t.Fatalf("archive: %+v %v", archived, err)
	}
	fresh := &Server{stateDir: s.stateDir}
	status, err := fresh.hostRPC(hostRequest{RequestID: "archive-status", Operation: "status", JobID: request.JobID})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(status.(map[string]any)["stdout"].([]byte)); got != "archive-proof" {
		t.Fatalf("archived output changed: %q", got)
	}
	if _, err := fresh.startHostJob(request); err != nil {
		t.Fatalf("same completed request lost its receipt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs", request.JobID)); !os.IsNotExist(err) {
		t.Fatal("archived command was reserved for execution again")
	}
	request.Argv = []string{"/must-not-run"}
	if _, err := fresh.startHostJob(request); err == nil {
		t.Fatal("changed execution reused an archived job ID")
	}
}

func TestHostJobArchiveRetainsRecentAndUnresolvedJobs(t *testing.T) {
	for _, state := range []string{"starting", "running", "unknown_after_daemon_restart", "recent"} {
		t.Run(state, func(t *testing.T) {
			root := t.TempDir()
			directory := filepath.Join(root, "host-jobs", "keep-job")
			if err := os.MkdirAll(directory, 0700); err != nil {
				t.Fatal(err)
			}
			record := hostJobRecord{JobID: "keep-job", State: state, UpdatedAt: time.Now().Add(-2 * time.Hour).Format(time.RFC3339Nano)}
			if state == "recent" {
				record.State = "exited"
				record.UpdatedAt = time.Now().Format(time.RFC3339Nano)
			}
			raw, _ := json.Marshal(record)
			if err := os.WriteFile(filepath.Join(directory, "record.json"), raw, 0600); err != nil {
				t.Fatal(err)
			}
			archived, err := archiveCompletedHostJobs(root, 0, time.Now().Add(-time.Hour))
			if err == nil || archived.Archived != 0 {
				t.Fatalf("unresolved/recent record archived: %+v %v", archived, err)
			}
			if _, err := os.Stat(filepath.Join(directory, "record.json")); err != nil {
				t.Fatal("retained record disappeared")
			}
		})
	}
}

func TestHostJobArchiveMissingRecordStillReservesID(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	directory := filepath.Join(s.stateDir, "host-jobs-completed", "reserved-job")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	_, err := s.startHostJob(hostRequest{JobID: "reserved-job", Argv: []string{"/must-not-run"}})
	if err == nil || !strings.Contains(err.Error(), "do not replay") {
		t.Fatalf("unreadable reservation did not block: %v", err)
	}
}
