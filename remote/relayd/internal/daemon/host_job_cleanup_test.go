package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// All fixtures are synthetic records under a temporary state directory.

func cleanupRequest(id string) hostRequest {
	return hostRequest{RequestID: "exec", Operation: "exec", JobID: id, Argv: []string{"/bin/echo", id}, Cwd: "/"}
}

func writeArchivedJob(t *testing.T, stateDir string, record hostJobRecord) string {
	t.Helper()
	directory := filepath.Join(stateDir, "host-jobs-completed", record.JobID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "record.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"stdout": "output of " + record.JobID, "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return directory
}

func finishedJob(id string, finished time.Time, code int) hostJobRecord {
	return hostJobRecord{JobID: id, Fingerprint: hostJobFingerprint(cleanupRequest(id)), State: "exited", ExitCode: &code,
		CreatedAt: finished.Add(-time.Minute).UTC().Format(time.RFC3339Nano), UpdatedAt: finished.UTC().Format(time.RFC3339Nano),
		Ledger: hostJobLedgerTombstones}
}

// activateCleanup registers this test process as the state directory's
// tombstone-aware relayd and activates deletion, as the deployment owner
// would once every node runs one.
func activateCleanup(t *testing.T, s *Server, at time.Time) {
	t.Helper()
	if err := s.registerHostJobServer(at); err != nil {
		t.Fatal(err)
	}
	if _, err := readHostJobActivation(s.stateDir); err == nil {
		return
	}
	if _, err := ActivateHostJobCleanup(s.stateDir, "test", []int{os.Getpid()}, at); err != nil {
		t.Fatal(err)
	}
}

// liveOptions are a run's options with this process as the only live relayd.
func liveOptions() HostJobCleanupOptions {
	return HostJobCleanupOptions{OlderThan: hostJobRetentionDefault, Wait: 5 * time.Second, LiveServerPIDs: []int{os.Getpid()}}
}

// runCleanup runs as an activated, registered tombstone-aware daemon would.
func runCleanup(t *testing.T, s *Server, now time.Time, hooks *hostJobCleanupHooks) (HostJobCleanupResult, error) {
	t.Helper()
	activateCleanup(t, s, now)
	return cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), liveOptions(), now, hooks)
}

func statusOf(t *testing.T, s *Server, id string) map[string]any {
	t.Helper()
	value, err := s.hostRPC(hostRequest{RequestID: "status", Operation: "status", JobID: id, StdoutOffset: 0, StderrOffset: 0})
	if err != nil {
		t.Fatalf("status %s: %v", id, err)
	}
	return value.(map[string]any)
}

// assertReserved checks the contract a deleted folder must keep: the ID is
// found, a different command is refused, and the same one is not rerun.
func assertReserved(t *testing.T, s *Server, id string) {
	t.Helper()
	if _, _, _, err := s.readHostJobRecord(id); err != nil {
		t.Fatalf("%s is not reserved: %v", id, err)
	}
	other := cleanupRequest(id)
	other.Argv = []string{"/must-not-run"}
	if _, err := s.startHostJob(other); err == nil {
		t.Fatalf("%s was admitted for a different command", id)
	}
	if _, ok := s.hostJobs.Load(id); ok {
		t.Fatalf("%s started a job", id)
	}
	if _, err := os.Lstat(filepath.Join(s.stateDir, "host-jobs", id)); !os.IsNotExist(err) {
		t.Fatalf("%s created a live job directory", id)
	}
}

func TestHostJobCleanupTombstonesAndReportsExpiredOutput(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	old := finishedJob("job-old-exit-3", now.Add(-8*24*time.Hour), 3)
	writeArchivedJob(t, s.stateDir, old)
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 1 || result.TombstonesWritten != 1 || result.BytesFreed == 0 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	if _, err := os.Lstat(filepath.Join(s.stateDir, "host-jobs-completed", old.JobID)); !os.IsNotExist(err) {
		t.Fatal("folder not removed")
	}
	if entries, _ := os.ReadDir(filepath.Join(s.stateDir, hostJobCleanupStagingDir)); len(entries) != 0 {
		t.Fatalf("staging left %d entries", len(entries))
	}
	snapshot := statusOf(t, s, old.JobID)
	record := snapshot["job"].(hostJobRecord)
	if snapshot["output_expired"] != true || record.State != "exited" || record.ExitCode == nil || *record.ExitCode != 3 ||
		len(snapshot["stdout"].([]byte)) != 0 || len(snapshot["stderr"].([]byte)) != 0 || record.CreatedAt != old.CreatedAt {
		t.Fatalf("expired status %+v", snapshot)
	}
	assertReserved(t, s, old.JobID)
	// The same command is answered with its final record, never rerun.
	value, err := s.startHostJob(cleanupRequest(old.JobID))
	if err != nil || value.(hostJobRecord).State != "exited" || *value.(hostJobRecord).ExitCode != 3 {
		t.Fatalf("idempotent exec %+v %v", value, err)
	}
	if _, ok := s.hostJobs.Load(old.JobID); ok {
		t.Fatal("tombstoned exec started a job")
	}
	// The file is private.
	entries, _ := os.ReadDir(hostJobTombstoneDir(s.stateDir))
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".jsonl") {
			if info, _ := entry.Info(); info.Mode().Perm() != 0600 {
				t.Fatalf("tombstone file mode %v", info.Mode())
			}
		}
	}
}

func TestHostJobCleanupRetentionBoundary(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	cutoff := now.Add(-hostJobRetentionDefault)
	writeArchivedJob(t, s.stateDir, finishedJob("job-past", cutoff.Add(-time.Second), 0))
	writeArchivedJob(t, s.stateDir, finishedJob("job-at", cutoff, 0))
	writeArchivedJob(t, s.stateDir, finishedJob("job-inside", cutoff.Add(time.Second), 0))
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 1 || result.KeptRecent != 2 {
		t.Fatalf("boundary %+v %v", result, err)
	}
	for _, id := range []string{"job-at", "job-inside"} {
		if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", id, "record.json")); err != nil {
			t.Fatalf("%s removed inside the retention", id)
		}
	}
	if _, err := ParseHostJobRetention("30m"); err == nil {
		t.Fatal("retention below one hour accepted")
	}
	if retention, err := ParseHostJobRetention("7d"); err != nil || retention != 7*24*time.Hour {
		t.Fatalf("7d parsed as %v %v", retention, err)
	}
}

func TestHostJobCleanupKeepsListenersUnresolvedUnreadableAndLiveJobs(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	old := now.Add(-30 * 24 * time.Hour)
	kept := map[string]hostJobRecord{}
	listenerKind := finishedJob("job-listener-kind", old, 0)
	listenerKind.Kind = hostJobKindPeerListener
	listenerBinding := finishedJob("job-listener-binding", old, 0)
	listenerBinding.Listener = &peerListenerBinding{}
	kept[listenerKind.JobID], kept[listenerBinding.JobID] = listenerKind, listenerBinding
	for _, state := range []string{"running", "starting", "unknown_after_daemon_restart"} {
		record := finishedJob("job-"+strings.ReplaceAll(state, "_", "-"), old, 0)
		record.State = state
		kept[record.JobID] = record
	}
	for _, record := range kept {
		writeArchivedJob(t, s.stateDir, record)
	}
	torn := writeArchivedJob(t, s.stateDir, finishedJob("job-torn-record", old, 0))
	if err := os.WriteFile(filepath.Join(torn, "record.json"), []byte(`{"job_id":"job-torn`), 0600); err != nil {
		t.Fatal(err)
	}
	foreign := writeArchivedJob(t, s.stateDir, finishedJob("job-foreign", old, 0))
	if err := os.WriteFile(filepath.Join(foreign, "record.json"), []byte(`{"job_id":"job-other","state":"exited"}`), 0600); err != nil {
		t.Fatal(err)
	}
	missing := writeArchivedJob(t, s.stateDir, finishedJob("job-missing-record", old, 0))
	if err := os.Remove(filepath.Join(missing, "record.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.stateDir, "host-jobs-completed", "stray-file"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	// The live ledger is never touched, however old.
	live := filepath.Join(s.stateDir, "host-jobs", "job-live-old")
	if err := os.MkdirAll(live, 0700); err != nil {
		t.Fatal(err)
	}
	liveJob := &hostJob{directory: live, record: finishedJob("job-live-old", old, 0)}
	if err := liveJob.save(); err != nil {
		t.Fatal(err)
	}
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 0 || result.KeptListener != 2 || result.KeptUnresolved != 3 ||
		result.KeptUnreadable != 3 || result.KeptOther != 1 || len(result.Unreadable) != 3 {
		t.Fatalf("kept %+v %v", result, err)
	}
	sort.Strings(result.Unreadable)
	if strings.Join(result.Unreadable, ",") != "job-foreign,job-missing-record,job-torn-record" {
		t.Fatalf("unreadable report %v", result.Unreadable)
	}
	for id := range kept {
		if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", id, "record.json")); err != nil {
			t.Fatalf("%s removed", id)
		}
	}
	for _, directory := range []string{torn, foreign, missing, live} {
		if _, err := os.Stat(directory); err != nil {
			t.Fatalf("%s removed", directory)
		}
	}
}

func treeState(t *testing.T, root string) string {
	t.Helper()
	var lines []string
	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, _ := entry.Info()
		lines = append(lines, fmt.Sprintf("%s %v %d %d", path, info.Mode(), info.Size(), info.ModTime().UnixNano()))
		return nil
	})
	return strings.Join(lines, "\n")
}

func TestHostJobCleanupDryRunChangesNothing(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	for i := 0; i < 5; i++ {
		writeArchivedJob(t, s.stateDir, finishedJob(fmt.Sprintf("job-dry-%d", i), now.Add(-10*24*time.Hour), 0))
	}
	writeArchivedJob(t, s.stateDir, finishedJob("job-dry-recent", now, 0))
	before := treeState(t, s.stateDir)
	result, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(),
		HostJobCleanupOptions{OlderThan: hostJobRetentionDefault, DryRun: true}, now, nil)
	if err != nil || result.Eligible != 5 || result.BytesEligible == 0 || result.Removed != 0 || result.KeptRecent != 1 || !result.DryRun {
		t.Fatalf("dry run %+v %v", result, err)
	}
	if after := treeState(t, s.stateDir); after != before {
		t.Fatalf("dry run changed the state directory:\n%s\n---\n%s", before, after)
	}
}

// A crash is modeled by a hook that stops the run at a step. At every step
// the ID stays reserved, and the next run completes the removal.
func TestHostJobCleanupCrashAtEachStepKeepsTheIDReserved(t *testing.T) {
	stop := errors.New("modeled crash")
	steps := map[string]func(*testing.T) *hostJobCleanupHooks{
		"after tombstone": func(*testing.T) *hostJobCleanupHooks {
			return &hostJobCleanupHooks{afterTombstones: func() error { return stop }}
		},
		"after staging rename": func(*testing.T) *hostJobCleanupHooks {
			return &hostJobCleanupHooks{afterStage: func(string, string) error { return stop }}
		},
		"during delete": func(t *testing.T) *hostJobCleanupHooks {
			return &hostJobCleanupHooks{afterStage: func(_, staged string) error {
				// RemoveAll got as far as the record and one output file.
				for _, name := range []string{"record.json", "stdout"} {
					if err := os.Remove(filepath.Join(staged, name)); err != nil {
						t.Fatal(err)
					}
				}
				return stop
			}}
		},
	}
	for name, hooks := range steps {
		t.Run(name, func(t *testing.T) {
			s := &Server{stateDir: t.TempDir()}
			now := time.Now()
			record := finishedJob("job-crash", now.Add(-9*24*time.Hour), 7)
			writeArchivedJob(t, s.stateDir, record)
			if _, err := runCleanup(t, s, now, hooks(t)); !errors.Is(err, stop) {
				t.Fatalf("run did not stop: %v", err)
			}
			// Both before and after a daemon restart.
			assertReserved(t, s, record.JobID)
			restarted := &Server{stateDir: s.stateDir}
			assertReserved(t, restarted, record.JobID)
			if snapshot := statusOf(t, restarted, record.JobID); snapshot["job"].(hostJobRecord).State != "exited" {
				t.Fatalf("status after crash %+v", snapshot)
			}
			result, err := runCleanup(t, restarted, now, nil)
			if err != nil || result.TombstonesWritten != 0 {
				t.Fatalf("recovery %+v %v", result, err)
			}
			if result.Removed+result.StagedRemoved != 1 {
				t.Fatalf("recovery did not finish the removal: %+v", result)
			}
			if entries, _ := os.ReadDir(filepath.Join(s.stateDir, hostJobCleanupStagingDir)); len(entries) != 0 {
				t.Fatalf("staging left %d entries", len(entries))
			}
			snapshot := statusOf(t, restarted, record.JobID)
			if snapshot["output_expired"] != true || *snapshot["job"].(hostJobRecord).ExitCode != 7 {
				t.Fatalf("status after recovery %+v", snapshot)
			}
			assertReserved(t, restarted, record.JobID)
		})
	}
}

// A crash during an append leaves a torn line; it can never swallow the
// next tombstone.
func TestHostJobTombstoneTornTailIsEndedBeforeTheNextAppend(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	directory := hostJobTombstoneDir(s.stateDir)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	month := filepath.Join(directory, now.UTC().Format("2006-01")+".jsonl")
	if err := os.WriteFile(month, []byte(`{"job_id":"job-torn","finger`), 0600); err != nil {
		t.Fatal(err)
	}
	writeArchivedJob(t, s.stateDir, finishedJob("job-after-torn", now.Add(-9*24*time.Hour), 0))
	if result, err := runCleanup(t, s, now, nil); err != nil || result.Removed != 1 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	restarted := &Server{stateDir: s.stateDir}
	assertReserved(t, restarted, "job-after-torn")
	if _, found, _ := restarted.hostJobTombstones().Lookup("job-torn"); found {
		t.Fatal("a torn line was indexed")
	}
}

// gc-host-jobs runs in another process with its own index. The daemon's
// index, loaded earlier, still sees those tombstones before admitting an ID.
func TestDaemonSeesTombstonesWrittenByAnotherProcess(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	if err := s.hostJobTombstones().Load(); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	writeArchivedJob(t, s.stateDir, finishedJob("job-cli-removed", now.Add(-9*24*time.Hour), 0))
	activateCleanup(t, s, now)
	result, err := cleanupArchivedHostJobs(s.stateDir, newHostJobTombstoneIndex(s.stateDir), liveOptions(), now, nil)
	if err != nil || result.Removed != 1 {
		t.Fatalf("cli cleanup %+v %v", result, err)
	}
	assertReserved(t, s, "job-cli-removed")
}

func TestDaemonRestartReloadsTombstones(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	for i := 0; i < 50; i++ {
		writeArchivedJob(t, s.stateDir, finishedJob(fmt.Sprintf("job-reload-%02d", i), now.Add(-9*24*time.Hour), i))
	}
	if result, err := runCleanup(t, s, now, nil); err != nil || result.Removed != 50 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	restarted := &Server{stateDir: s.stateDir}
	if err := restarted.hostJobTombstones().Load(); err != nil || restarted.hostJobTombstones().Len() != 50 {
		t.Fatalf("reloaded %d tombstones: %v", restarted.hostJobTombstones().Len(), err)
	}
	for i := 0; i < 50; i++ {
		id := fmt.Sprintf("job-reload-%02d", i)
		if code := *statusOf(t, restarted, id)["job"].(hostJobRecord).ExitCode; code != i {
			t.Fatalf("%s exit code %d", id, code)
		}
	}
	assertReserved(t, restarted, "job-reload-07")
}

// The supervisor's archive step and the cleanup share the ledger lock. Run
// together, every ID ends reserved by its live folder, its archive folder or
// its tombstone.
func TestConcurrentArchiveAndCleanupKeepEveryIDReserved(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	var ids []string
	for i := 0; i < 200; i++ {
		record := finishedJob(fmt.Sprintf("job-live-%03d", i), now.Add(-9*24*time.Hour), 0)
		directory := filepath.Join(s.stateDir, "host-jobs", record.JobID)
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		job := &hostJob{directory: directory, record: record}
		if err := job.save(); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, record.JobID)
	}
	for i := 0; i < 200; i++ {
		record := finishedJob(fmt.Sprintf("job-archived-%03d", i), now.Add(-9*24*time.Hour), 0)
		writeArchivedJob(t, s.stateDir, record)
		ids = append(ids, record.JobID)
	}
	var group sync.WaitGroup
	errs := make(chan error, 8)
	for round := 0; round < 4; round++ {
		group.Add(2)
		go func() {
			defer group.Done()
			if _, err := archiveCompletedHostJobs(s.stateDir, 0, now.Add(time.Hour)); err != nil {
				errs <- err
			}
		}()
		go func() {
			defer group.Done()
			if _, err := runCleanup(t, s, now, nil); err != nil {
				errs <- err
			}
		}()
	}
	group.Wait()
	close(errs)
	for err := range errs {
		// Only the archive's own deferral (records it left) is acceptable.
		if !strings.Contains(err.Error(), "upgrade deferred") {
			t.Fatal(err)
		}
	}
	for _, id := range ids {
		if _, _, _, err := s.readHostJobRecord(id); err != nil {
			t.Fatalf("%s lost its reservation: %v", id, err)
		}
	}
	assertReserved(t, s, "job-live-000")
	assertReserved(t, s, "job-archived-199")
}

// 500k tombstones: load time and the resident index cost.
func BenchmarkHostJobTombstoneIndex500k(b *testing.B) {
	stateDir := b.TempDir()
	const count = 500000
	tombstones := make([]hostJobTombstone, 0, count)
	code := 0
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("job-%08x-0000-4000-8000-%012x", i, i)
		tombstones = append(tombstones, hostJobTombstone{JobID: id, Fingerprint: strings.Repeat("ab", 32),
			CreatedAt: "2026-10-01T00:00:00.123456789Z", UpdatedAt: "2026-10-01T00:00:01.123456789Z", State: "exited", ExitCode: &code})
	}
	for start := 0; start < count; start += 50000 {
		if err := appendHostJobTombstones(stateDir, tombstones[start:start+50000], time.Now()); err != nil {
			b.Fatal(err)
		}
	}
	b.ResetTimer()
	for n := 0; n < b.N; n++ {
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		index := newHostJobTombstoneIndex(stateDir)
		started := time.Now()
		if err := index.Load(); err != nil {
			b.Fatal(err)
		}
		loaded := time.Since(started)
		runtime.GC()
		runtime.ReadMemStats(&after)
		if index.Len() != count {
			b.Fatalf("indexed %d", index.Len())
		}
		started = time.Now()
		for i := 0; i < 10000; i++ {
			if _, found, err := index.Lookup(fmt.Sprintf("job-%08x-0000-4000-8000-%012x", i*37, i*37)); err != nil || !found {
				b.Fatal("lookup missed", err)
			}
		}
		hits := time.Since(started) / 10000
		started = time.Now()
		for i := 0; i < 1000; i++ {
			if _, found, _ := index.Lookup(fmt.Sprintf("job-absent-%d", i)); found {
				b.Fatal("absent ID found")
			}
		}
		misses := time.Since(started) / 1000
		info, _ := os.ReadDir(hostJobTombstoneDir(stateDir))
		var bytes int64
		for _, entry := range info {
			if fileInfo, err := entry.Info(); err == nil && strings.HasSuffix(entry.Name(), ".jsonl") {
				bytes += fileInfo.Size()
			}
		}
		b.ReportMetric(float64(after.HeapInuse)-float64(before.HeapInuse), "heap-bytes")
		b.ReportMetric(float64(loaded.Milliseconds()), "load-ms")
		b.ReportMetric(float64(hits.Microseconds()), "hit-us")
		b.ReportMetric(float64(misses.Microseconds()), "miss-us")
		b.ReportMetric(float64(bytes), "file-bytes")
		runtime.KeepAlive(index)
	}
}

// A tombstone that is indexed but cannot be read back still reserves its ID.
func TestUnreadableTombstoneFailsClosed(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	writeArchivedJob(t, s.stateDir, finishedJob("job-corrupted", now.Add(-9*24*time.Hour), 0))
	if result, err := runCleanup(t, s, now, nil); err != nil || result.Removed != 1 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	month := filepath.Join(hostJobTombstoneDir(s.stateDir), now.UTC().Format("2006-01")+".jsonl")
	raw, err := os.ReadFile(month)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(month, append([]byte(strings.Repeat("#", len(raw)-1)), '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.readHostJobRecord("job-corrupted"); !errors.Is(err, errHostJobTombstoneUnreadable) {
		t.Fatalf("corrupted tombstone lookup: %v", err)
	}
	other := cleanupRequest("job-corrupted")
	other.Argv = []string{"/must-not-run"}
	if _, err := s.startHostJob(other); err == nil {
		t.Fatal("an ID with an unreadable tombstone was admitted")
	}
	if _, err := s.hostRPC(hostRequest{RequestID: "status", Operation: "status", JobID: "job-corrupted"}); err == nil {
		t.Fatal("status answered from an unreadable tombstone")
	}
}

func writeLiveJob(t *testing.T, stateDir string, record hostJobRecord) string {
	t.Helper()
	directory := filepath.Join(stateDir, "host-jobs", record.JobID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(record)
	if err := os.WriteFile(filepath.Join(directory, "record.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	return directory
}

// The daemon's pass archives finished live jobs older than two minutes,
// with the upgrade step's rules, then cleans the archive, in one locked pass.
func TestDaemonPassArchivesFinishedLiveJobsThenCleansUp(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	writeLiveJob(t, s.stateDir, finishedJob("job-five-minutes", now.Add(-5*time.Minute), 0))
	writeLiveJob(t, s.stateDir, finishedJob("job-ancient", now.Add(-10*24*time.Hour), 4))
	recent := writeLiveJob(t, s.stateDir, finishedJob("job-one-minute", now.Add(2*time.Minute), 0)) // one minute before the pass
	running := finishedJob("job-running", now.Add(-time.Hour), 0)
	running.State = "running"
	runningDirectory := writeLiveJob(t, s.stateDir, running)
	// A finished listener the registry no longer names moves like any job; the
	// one the registry names stays, since resume links its successor into it.
	listener := finishedJob("job-listener", now.Add(-time.Hour), 0)
	listener.Kind = hostJobKindPeerListener
	listener.Listener = &peerListenerBinding{Route: "relay-old-route"}
	writeLiveJob(t, s.stateDir, listener)
	registered := finishedJob("job-registered-listener", now.Add(-time.Hour), 0)
	registered.Kind = hostJobKindPeerListener
	registeredDirectory := writeLiveJob(t, s.stateDir, registered)
	if err := os.MkdirAll(s.peerListenerDir(), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.peerListenerPath("relay-route"), []byte(`{"job_id":"job-registered-listener"}`), 0600); err != nil {
		t.Fatal(err)
	}
	// A job this daemon ran and still tracks.
	tracked := hostRequest{RequestID: "exec", Operation: "exec", JobID: "job-tracked",
		Argv: []string{"/bin/sh", "-c", "printf tracked-output"}, Cwd: s.stateDir}
	if _, err := s.startHostJob(tracked); err != nil {
		t.Fatal(err)
	}
	waitHostJob(t, s, tracked.JobID)
	activateCleanup(t, s, now)
	result, err := s.archiveAndCleanupHostJobs(now.Add(3 * time.Minute))
	if err != nil || result.Archived != 4 || result.Removed != 1 || result.TombstonesWritten != 1 {
		t.Fatalf("pass %+v %v", result, err)
	}
	for _, id := range []string{"job-five-minutes", "job-tracked", "job-listener"} {
		if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", id, "record.json")); err != nil {
			t.Fatalf("%s not archived", id)
		}
	}
	for _, directory := range []string{recent, runningDirectory, registeredDirectory} {
		if _, err := os.Stat(filepath.Join(directory, "record.json")); err != nil {
			t.Fatalf("%s moved", directory)
		}
	}
	if snapshot := statusOf(t, s, "job-ancient"); snapshot["output_expired"] != true || *snapshot["job"].(hostJobRecord).ExitCode != 4 {
		t.Fatalf("ancient %+v", snapshot)
	}
	if got := drain(t, s, tracked.JobID); got != "tracked-output" {
		t.Fatalf("tracked output after archive %q", got)
	}
	assertReserved(t, s, "job-five-minutes")
	assertReserved(t, &Server{stateDir: s.stateDir}, "job-tracked")
	// The moved listener is still found by the disconnect path.
	s.hostJobsMu.Lock()
	moved, ok := s.peerListenerChainRecord("job-listener")
	s.hostJobsMu.Unlock()
	if !ok || moved.Kind != hostJobKindPeerListener {
		t.Fatalf("archived listener not found by its chain lookup: %+v %v", moved, ok)
	}
}

// Status reads of a tracked job race the archive move without a data race
// or a failed read.
func TestTrackedJobStatusDuringArchivePass(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	tracked := hostRequest{RequestID: "exec", Operation: "exec", JobID: "job-raced",
		Argv: []string{"/bin/sh", "-c", "printf raced"}, Cwd: s.stateDir}
	if _, err := s.startHostJob(tracked); err != nil {
		t.Fatal(err)
	}
	waitHostJob(t, s, tracked.JobID)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 200; i++ {
			if _, err := s.hostRPC(hostRequest{RequestID: "status", Operation: "status", JobID: tracked.JobID, WaitMillis: 1}); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	if _, err := s.archiveAndCleanupHostJobs(time.Now().Add(3 * time.Minute)); err != nil {
		t.Fatal(err)
	}
	<-done
	if got := drain(t, s, tracked.JobID); got != "raced" {
		t.Fatalf("output %q", got)
	}
}

// A tombstone that is readable but was never synced is not a reservation:
// a retry must sync it again before deleting the archive.
func TestTombstoneSyncFailureIsRepairedBeforeAnyDelete(t *testing.T) {
	restore := hostJobTombstoneSync
	defer func() { hostJobTombstoneSync = restore }()
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	record := finishedJob("job-unsynced", now.Add(-9*24*time.Hour), 5)
	folder := writeArchivedJob(t, s.stateDir, record)
	month := filepath.Join(hostJobTombstoneDir(s.stateDir), now.UTC().Format("2006-01")+".jsonl")
	failing := errors.New("injected fsync failure")
	hostJobTombstoneSync = func(*os.File) error { return failing }
	for run := 1; run <= 2; run++ {
		if _, err := runCleanup(t, s, now, nil); !errors.Is(err, failing) {
			t.Fatalf("run %d: %v", run, err)
		}
		if _, err := os.Stat(filepath.Join(folder, "record.json")); err != nil {
			t.Fatalf("run %d deleted the archive behind an unsynced tombstone", run)
		}
	}
	if raw, err := os.ReadFile(month); err != nil || !strings.Contains(string(raw), record.JobID) {
		t.Fatalf("the unsynced line should be readable: %v", err)
	}
	syncedBeforeDelete := false
	hostJobTombstoneSync = func(file *os.File) error {
		if file.Name() == month {
			_, err := os.Stat(folder)
			syncedBeforeDelete = syncedBeforeDelete || err == nil
		}
		return file.Sync()
	}
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 1 || result.TombstonesWritten != 0 || !syncedBeforeDelete {
		t.Fatalf("repair run %+v %v synced=%v", result, err, syncedBeforeDelete)
	}
	assertReserved(t, &Server{stateDir: s.stateDir}, record.JobID)
}

// The same for the directory entry of a newly created tombstone file.
func TestTombstoneDirectorySyncFailureIsRepairedBeforeAnyDelete(t *testing.T) {
	restore := questionJournalSync
	defer func() { questionJournalSync = restore }()
	// Real path: directories are synced by their resolved names.
	stateDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-unsynced-entry", now.Add(-9*24*time.Hour), 0)
	folder := writeArchivedJob(t, s.stateDir, record)
	directory := hostJobTombstoneDir(s.stateDir)
	month := filepath.Join(directory, now.UTC().Format("2006-01")+".jsonl")
	failing := errors.New("injected directory fsync failure")
	activateCleanup(t, s, now)
	options := liveOptions()
	// Fail only the tombstone directory, and only once the month file exists.
	questionJournalSync = func(file *os.File) error {
		if _, err := os.Stat(month); err == nil && file.Name() == directory {
			return failing
		}
		return file.Sync()
	}
	for run := 1; run <= 2; run++ {
		if _, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil); !errors.Is(err, failing) {
			t.Fatalf("run %d: %v", run, err)
		}
		if _, err := os.Stat(filepath.Join(folder, "record.json")); err != nil {
			t.Fatalf("run %d deleted the archive behind an unsynced directory entry", run)
		}
	}
	syncedBeforeDelete := false
	questionJournalSync = func(file *os.File) error {
		if file.Name() == directory {
			_, err := os.Stat(folder)
			syncedBeforeDelete = syncedBeforeDelete || err == nil
		}
		return file.Sync()
	}
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 1 || !syncedBeforeDelete {
		t.Fatalf("repair run %+v %v synced=%v", result, err, syncedBeforeDelete)
	}
}

// Deleting needs activation, a registered tombstone-aware relayd for each
// live one on this node, and no legacy evidence; nothing is deleted otherwise.
func TestCleanupRefusesWithoutTombstoneAwareServers(t *testing.T) {
	now := time.Now()
	options := liveOptions()
	setup := func(t *testing.T) (*Server, string) {
		s := &Server{stateDir: t.TempDir()}
		return s, writeArchivedJob(t, s.stateDir, finishedJob("job-old", now.Add(-9*24*time.Hour), 0))
	}
	kept := func(t *testing.T, folder string, err error, want string) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("expected refusal %q, got %v", want, err)
		}
		if _, statErr := os.Stat(filepath.Join(folder, "record.json")); statErr != nil {
			t.Fatal("refused cleanup deleted a folder")
		}
	}
	t.Run("not activated", func(t *testing.T) {
		s, folder := setup(t)
		_ = s.registerHostJobServer(now)
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "cleanup inactive")
	})
	t.Run("an activation others can read", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		if err := os.Chmod(filepath.Join(hostJobTombstoneDir(s.stateDir), hostJobActivationFile), 0644); err != nil {
			t.Fatal(err)
		}
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "readable or writable by others")
	})
	t.Run("no registration", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		if err := os.RemoveAll(hostJobServerDir(s.stateDir)); err != nil {
			t.Fatal(err)
		}
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "no tombstone-aware relayd has registered")
	})
	unaware := func(t *testing.T, root string) {
		s, folder := setup(t)
		activateCleanup(t, s, now.Add(-time.Hour))
		old := finishedJob("job-from-old-daemon", now.Add(-time.Minute), 0)
		old.Ledger = 0
		var evidence string
		if root == "host-jobs" {
			evidence = writeLiveJob(t, s.stateDir, old)
		} else {
			evidence = writeArchivedJob(t, s.stateDir, old)
		}
		result, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "without tombstone support")
		if result.UnawareRecord != old.JobID {
			t.Fatalf("unaware record %q", result.UnawareRecord)
		}
		// Sticky: the block holds once the record itself is gone, and a
		// fresh activation is refused until deactivation clears it.
		if err := os.RemoveAll(evidence); err != nil {
			t.Fatal(err)
		}
		_, err = cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now.Add(30*24*time.Hour), nil)
		kept(t, folder, err, old.JobID)
		if _, err := ActivateHostJobCleanup(s.stateDir, "test", []int{os.Getpid()}, now); err == nil {
			t.Fatal("activation succeeded over legacy evidence")
		}
		if err := DeactivateHostJobCleanup(s.stateDir); err != nil {
			t.Fatal(err)
		}
		_, err = cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "cleanup inactive")
		activateCleanup(t, s, now)
		if result, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil); err != nil || result.Removed != 1 {
			t.Fatalf("after a fresh activation %+v %v", result, err)
		}
	}
	t.Run("unaware live record", func(t *testing.T) { unaware(t, "host-jobs") })
	t.Run("unaware archived record", func(t *testing.T) { unaware(t, "host-jobs-completed") })
	t.Run("an unaware record is evidence however old", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now.Add(-20*24*time.Hour))
		old := finishedJob("job-aged-legacy", now.Add(-9*24*time.Hour), 0)
		old.Ledger = 0
		writeLiveJob(t, s.stateDir, old)
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "job-aged-legacy")
	})
	t.Run("unstamped records before activation are allowed", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		earlier := finishedJob("job-before-activation", now.Add(-2*time.Hour), 0)
		earlier.Ledger = 0
		writeLiveJob(t, s.stateDir, earlier)
		if result, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil); err != nil || result.Removed != 1 {
			t.Fatalf("cleanup %+v %v", result, err)
		}
		if _, err := os.Lstat(folder); !os.IsNotExist(err) {
			t.Fatal("folder kept")
		}
	})
	t.Run("no live tombstone-aware relayd", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		none := options
		none.LiveServerPIDs = nil
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), none, now, nil)
		kept(t, folder, err, "no running tombstone-aware relayd")
	})
	t.Run("an unregistered live relayd", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		withParent := options
		withParent.LiveServerPIDs = []int{os.Getpid(), os.Getppid()}
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), withParent, now, nil)
		kept(t, folder, err, "has not registered tombstone support")
	})
	t.Run("a stale registration", func(t *testing.T) {
		s, folder := setup(t)
		activateCleanup(t, s, now)
		path := filepath.Join(hostJobServerDir(s.stateDir), hostJobServerNode()+".json")
		raw, _ := os.ReadFile(path)
		var marker hostJobServerMarker
		_ = json.Unmarshal(raw, &marker)
		marker.ProcessStart = "an earlier process"
		raw, _ = json.Marshal(marker)
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
		_, err := cleanupArchivedHostJobs(s.stateDir, s.hostJobTombstones(), options, now, nil)
		kept(t, folder, err, "has not registered tombstone support")
	})
}

// Every record this daemon creates carries the tombstone ledger stamp.
func TestNewJobRecordsCarryTheTombstoneStamp(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	request := hostRequest{RequestID: "exec", Operation: "exec", JobID: "job-stamped",
		Argv: []string{"/bin/sh", "-c", "true"}, Cwd: s.stateDir}
	if _, err := s.startHostJob(request); err != nil {
		t.Fatal(err)
	}
	waitHostJob(t, s, request.JobID)
	record, err := readArchivedHostJobRecord(filepath.Join(s.stateDir, "host-jobs", request.JobID), request.JobID)
	if err != nil || record.Ledger != hostJobLedgerTombstones {
		t.Fatalf("record %+v %v", record, err)
	}
}

func TestHostJobRetentionPrecedenceAndRejection(t *testing.T) {
	stateDir := t.TempDir()
	path := filepath.Join(stateDir, hostJobRetentionFile)
	write := func(t *testing.T, text string, mode os.FileMode) {
		t.Helper()
		os.Remove(path)
		if err := os.WriteFile(path, []byte(text), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
	}
	expect := func(t *testing.T, want time.Duration, source string, warned bool) {
		t.Helper()
		got := ResolveHostJobRetention(stateDir)
		if got.Duration != want || !strings.HasPrefix(got.Source, source) || (len(got.Warnings) > 0) != warned {
			t.Fatalf("retention %+v, want %v from %q warned=%v", got, want, source, warned)
		}
		if got.Duration < hostJobRetentionMinimum {
			t.Fatal("retention below the minimum")
		}
	}
	t.Setenv("RELAYD_HOST_JOB_RETENTION", "")
	t.Run("default", func(t *testing.T) { expect(t, 7*24*time.Hour, "default", false) })
	t.Run("file", func(t *testing.T) {
		write(t, "1d\n", 0600)
		expect(t, 24*time.Hour, "file "+path, false)
	})
	t.Run("env over file", func(t *testing.T) {
		write(t, "1d\n", 0600)
		t.Setenv("RELAYD_HOST_JOB_RETENTION", "36h")
		expect(t, 36*time.Hour, "env", false)
	})
	t.Run("malformed env falls back to the default", func(t *testing.T) {
		write(t, "1d\n", 0600)
		t.Setenv("RELAYD_HOST_JOB_RETENTION", "soon")
		expect(t, 7*24*time.Hour, "default", true)
	})
	for name, text := range map[string]string{"malformed": "one day", "below the minimum": "30m", "zero": "0d", "negative": "-1d", "empty": ""} {
		t.Run("file "+name+" falls back to the default", func(t *testing.T) {
			write(t, text, 0600)
			expect(t, 7*24*time.Hour, "default", true)
		})
	}
	t.Run("env below the minimum falls back to the default", func(t *testing.T) {
		t.Setenv("RELAYD_HOST_JOB_RETENTION", "59m")
		expect(t, 7*24*time.Hour, "default", true)
	})
	t.Run("a file others can read is rejected", func(t *testing.T) {
		write(t, "1d", 0644)
		expect(t, 7*24*time.Hour, "default", true)
	})
	t.Run("a symlink is rejected", func(t *testing.T) {
		os.Remove(path)
		target := filepath.Join(t.TempDir(), "elsewhere")
		if err := os.WriteFile(target, []byte("1d"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		expect(t, 7*24*time.Hour, "default", true)
	})
}

// The daemon reads the file at every pass and reports what it used.
func TestDaemonPassUsesAndReportsTheRetentionFile(t *testing.T) {
	t.Setenv("RELAYD_HOST_JOB_RETENTION", "")
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	writeArchivedJob(t, s.stateDir, finishedJob("job-two-days", now.Add(-48*time.Hour), 0))
	activateCleanup(t, s, now)
	result, err := s.archiveAndCleanupHostJobs(now)
	if err != nil || result.Removed != 0 || result.RetentionSource != "default" || result.RetentionSeconds != 7*24*3600 {
		t.Fatalf("default pass %+v %v", result, err)
	}
	if err := os.WriteFile(filepath.Join(s.stateDir, hostJobRetentionFile), []byte("1d\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err = s.archiveAndCleanupHostJobs(now)
	if err != nil || result.Removed != 1 || !strings.HasPrefix(result.RetentionSource, "file ") || result.Retention != "24h0m0s" {
		t.Fatalf("file pass %+v %v", result, err)
	}
}

// Without activation the hourly pass archives but deletes nothing, and says so.
func TestHourlyPassWithoutActivationArchivesOnly(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	writeLiveJob(t, s.stateDir, finishedJob("job-live-finished", now.Add(-time.Hour), 0))
	archived := writeArchivedJob(t, s.stateDir, finishedJob("job-archived-old", now.Add(-30*24*time.Hour), 0))
	result, err := s.archiveAndCleanupHostJobs(now)
	if err != nil || !result.CleanupInactive || result.Archived != 1 || result.Removed != 0 || result.TombstonesWritten != 0 {
		t.Fatalf("inactive pass %+v %v", result, err)
	}
	if _, err := os.Stat(filepath.Join(archived, "record.json")); err != nil {
		t.Fatal("an inactive pass deleted an archive")
	}
	if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", "job-live-finished", "record.json")); err != nil {
		t.Fatal("an inactive pass did not archive")
	}
	if markers, _ := readHostJobServerMarkers(s.stateDir); len(markers) != 1 {
		t.Fatal("the pass did not register")
	}
	recordHostJobCleanup(s.stateDir, result, err)
	raw, _ := os.ReadFile(filepath.Join(hostJobTombstoneDir(s.stateDir), "last-cleanup.json"))
	if !strings.Contains(string(raw), `"cleanup_inactive":true`) {
		t.Fatalf("last-cleanup.json %s", raw)
	}
}

// The hourly pass refuses to delete beside a local relayd without tombstone
// support, on any of this node's sockets, including the legacy one.
func TestHourlyPassRefusesBesideALocalLegacyRelayd(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	archived := writeArchivedJob(t, s.stateDir, finishedJob("job-archived-old", now.Add(-30*24*time.Hour), 0))
	activateCleanup(t, s, now)
	s.SetHostJobPeerSockets([]string{fakeProbeSocket(t, []string{"agent_binding_v1"})})
	result, err := s.archiveAndCleanupHostJobs(now)
	if err == nil || !strings.Contains(err.Error(), "does not support job tombstones") || result.Removed != 0 {
		t.Fatalf("pass beside a legacy relayd %+v %v", result, err)
	}
	if _, err := os.Stat(filepath.Join(archived, "record.json")); err != nil {
		t.Fatal("deleted beside a legacy relayd")
	}
	s.SetHostJobPeerSockets([]string{fakeProbeSocket(t, []string{HostJobTombstonesCapability})})
	if result, err := s.archiveAndCleanupHostJobs(now); err != nil || result.Removed != 1 {
		t.Fatalf("pass beside an aware relayd %+v %v", result, err)
	}
}

// fakeProbeSocket answers one probe as this process with the capabilities.
func fakeProbeSocket(t *testing.T, capabilities []string) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "rjp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	socket := filepath.Join(directory, "relayd.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		if _, err := protocol.ReadFrame(connection); err != nil {
			return
		}
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Version: "fixture",
			SupervisorPID: os.Getpid(), Capabilities: capabilities})
		_ = protocol.NewWriter(connection).Write(status)
	}()
	return socket
}

// Replaces root's TestReviewerFirstHourlyPassRegistersBeforeCleanup under
// default-off deletion. Without activation the first hourly pass on a fresh
// state directory registers and deletes nothing. With activation (given
// after the startup registration, as the owner's --activate must be) the
// first pass deletes the eligible folder: zero registrations never block
// cleanup forever.
func TestFirstHourlyPassRegistersAndDeletesOnlyWhenActivated(t *testing.T) {
	now := time.Now()
	t.Run("without activation", func(t *testing.T) {
		s := &Server{stateDir: t.TempDir()}
		folder := writeArchivedJob(t, s.stateDir, finishedJob("job-first-hour", now.Add(-9*24*time.Hour), 0))
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || !result.CleanupInactive || result.Removed != 0 {
			t.Fatalf("first pass %+v %v", result, err)
		}
		if markers, err := readHostJobServerMarkers(s.stateDir); err != nil || len(markers) != 1 {
			t.Fatalf("marker missing: %+v %v", markers, err)
		}
		if _, err := os.Stat(folder); err != nil {
			t.Fatal("deleted without activation")
		}
	})
	t.Run("with activation", func(t *testing.T) {
		s := &Server{stateDir: t.TempDir()}
		folder := writeArchivedJob(t, s.stateDir, finishedJob("job-first-hour", now.Add(-9*24*time.Hour), 0))
		// Serve registers before accepting clients; the owner activates after.
		if err := s.registerHostJobServer(now); err != nil {
			t.Fatal(err)
		}
		if _, err := ActivateHostJobCleanup(s.stateDir, "test", []int{os.Getpid()}, now); err != nil {
			t.Fatal(err)
		}
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || result.CleanupInactive || result.Removed != 1 {
			t.Fatalf("first activated pass %+v %v", result, err)
		}
		if _, err := os.Stat(folder); !os.IsNotExist(err) {
			t.Fatalf("not removed: %v", err)
		}
		if markers, err := readHostJobServerMarkers(s.stateDir); err != nil || len(markers) != 1 {
			t.Fatalf("marker: %+v %v", markers, err)
		}
	})
}

// The largest whole-day count is accepted; one more, or an over-range Go
// duration, is rejected rather than wrapped.
func TestHostJobRetentionRangeBoundary(t *testing.T) {
	limit := int64(math.MaxInt64 / int64(24*time.Hour))
	if got, err := ParseHostJobRetention(fmt.Sprintf("%dd", limit)); err != nil || got != time.Duration(limit)*24*time.Hour || got <= 0 {
		t.Fatalf("largest day count: %v %v", got, err)
	}
	for _, text := range []string{fmt.Sprintf("%dd", limit+1), "9223372036854775808d", "99999999999999h", "-48h"} {
		if got, err := ParseHostJobRetention(text); err == nil {
			t.Fatalf("%s accepted as %v", text, got)
		}
	}
}

// After another daemon archives a tracked job, the owner reads its output
// from the archive and remembers the new folder; once that folder is
// cleaned, the owner falls back to the tombstone.
func TestTrackedJobFollowsAnotherDaemonsArchiveThenTombstone(t *testing.T) {
	stateDir := t.TempDir()
	owner, archiver := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-moved-by-peer", now.Add(-9*24*time.Hour), 6)
	directory := writeLiveJob(t, stateDir, record)
	for name, body := range map[string]string{"stdout": "peer-archived output", "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	job := &hostJob{record: record, directory: directory}
	owner.hostJobs.Store(record.JobID, job)
	if result, err := archiver.archiveAndCleanupHostJobs(now); err != nil || result.Archived != 1 {
		t.Fatalf("archive %+v %v", result, err)
	}
	if got := drain(t, owner, record.JobID); got != "peer-archived output" {
		t.Fatalf("output after a peer archive %q", got)
	}
	job.mu.Lock()
	moved := job.directory
	job.mu.Unlock()
	if moved != filepath.Join(stateDir, "host-jobs-completed", record.JobID) {
		t.Fatalf("tracked directory %s", moved)
	}
	activateCleanup(t, archiver, now)
	if result, err := archiver.archiveAndCleanupHostJobs(now); err != nil || result.Removed != 1 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	snapshot := statusOf(t, owner, record.JobID)
	if snapshot["output_expired"] != true || *snapshot["job"].(hostJobRecord).ExitCode != 6 {
		t.Fatalf("after cleanup %+v", snapshot)
	}
}

// A folder of the same ID that is not this job's (different fingerprint) is
// never adopted.
func TestTrackedJobDoesNotAdoptAnotherGenerationsFolder(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	record := finishedJob("job-not-adopted", now.Add(-time.Hour), 0)
	other := record
	other.Fingerprint = "another-execution"
	writeArchivedJob(t, s.stateDir, other)
	s.hostJobs.Store(record.JobID, &hostJob{record: record, directory: filepath.Join(s.stateDir, "host-jobs", record.JobID)})
	if _, err := s.hostRPC(hostRequest{RequestID: "status", Operation: "status", JobID: record.JobID}); err == nil {
		t.Fatal("status served another generation's folder")
	}
}

// withSnapshotHook runs fn once, between the n-th folder lookup and the
// opening of its output, as a peer daemon's archive or cleanup would.
func withSnapshotHook(t *testing.T, n int, fn func()) {
	t.Helper()
	restore := hostJobBeforeSnapshot
	t.Cleanup(func() { hostJobBeforeSnapshot = restore })
	calls := 0
	hostJobBeforeSnapshot = func(string, string) {
		calls++
		if calls == n {
			fn()
		}
	}
}

// Tracked branch: the owner relocates to the archive, and the peer cleans
// that folder before the owner opens it. The tombstone answers.
func TestTrackedStatusSurvivesCleanupAfterRelocation(t *testing.T) {
	stateDir := t.TempDir()
	owner, peer := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-relocated-then-cleaned", now.Add(-9*24*time.Hour), 6)
	directory := writeLiveJob(t, stateDir, record)
	for name, body := range map[string]string{"stdout": "retained output", "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	owner.hostJobs.Store(record.JobID, &hostJob{record: record, directory: directory})
	if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Archived != 1 {
		t.Fatalf("peer archive %+v %v", result, err)
	}
	activateCleanup(t, peer, now)
	// Lookup 1 is the stale live folder; lookup 2 is the relocated archive.
	withSnapshotHook(t, 2, func() {
		if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Removed != 1 {
			t.Errorf("peer cleanup %+v %v", result, err)
		}
	})
	snapshot := statusOf(t, owner, record.JobID)
	if snapshot["output_expired"] != true || *snapshot["job"].(hostJobRecord).ExitCode != 6 {
		t.Fatalf("status after a cleanup during relocation %+v", snapshot)
	}
}

// Disk branch: the live record is read, then the peer archives the folder
// before its output is opened. The archive answers with the output.
func TestDiskStatusFollowsAnArchiveAfterTheRecordRead(t *testing.T) {
	stateDir := t.TempDir()
	reader, peer := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-disk-archived-mid-read", now.Add(-time.Hour), 4)
	directory := writeLiveJob(t, stateDir, record)
	for name, body := range map[string]string{"stdout": "retained disk output", "stderr": ""} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	withSnapshotHook(t, 1, func() {
		if result, err := peer.archiveAndCleanupHostJobs(now); err != nil || result.Archived != 1 || result.Removed != 0 {
			t.Errorf("peer archive %+v %v", result, err)
		}
	})
	snapshot := statusOf(t, reader, record.JobID)
	if snapshot["output_expired"] == true || string(snapshot["stdout"].([]byte)) != "retained disk output" {
		t.Fatalf("status after an archive during the read %+v", snapshot)
	}
}

// Disk branch, both steps: archived, then cleaned, during one read.
func TestDiskStatusFollowsArchiveThenCleanupDuringOneRead(t *testing.T) {
	stateDir := t.TempDir()
	reader, peer := &Server{stateDir: stateDir}, &Server{stateDir: stateDir}
	now := time.Now()
	record := finishedJob("job-disk-archived-then-cleaned", now.Add(-9*24*time.Hour), 2)
	directory := writeLiveJob(t, stateDir, record)
	for name := range map[string]bool{"stdout": true, "stderr": true} {
		if err := os.WriteFile(filepath.Join(directory, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	activateCleanup(t, peer, now)
	calls := 0
	restore := hostJobBeforeSnapshot
	defer func() { hostJobBeforeSnapshot = restore }()
	hostJobBeforeSnapshot = func(string, string) {
		calls++
		if calls <= 2 {
			// Pass 1 archives, pass 2 cleans: each just before an open.
			if _, err := peer.archiveAndCleanupHostJobs(now); err != nil {
				t.Error(err)
			}
		}
	}
	snapshot := statusOf(t, reader, record.JobID)
	if snapshot["output_expired"] != true || *snapshot["job"].(hostJobRecord).ExitCode != 2 {
		t.Fatalf("status %+v", snapshot)
	}
}

// A folder that keeps moving gives up after a bounded number of lookups.
func TestSnapshotResolutionIsBounded(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	record := finishedJob("job-never-found", time.Now().Add(-time.Hour), 0)
	directory := writeLiveJob(t, s.stateDir, record)
	calls := 0
	restore := hostJobBeforeSnapshot
	defer func() { hostJobBeforeSnapshot = restore }()
	hostJobBeforeSnapshot = func(string, string) { calls++ } // outputs never exist
	if _, err := s.resolveHostJobSnapshot(nil, record, directory, hostRequest{}); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected ENOENT, got %v", err)
	}
	if calls != hostJobSnapshotAttempts {
		t.Fatalf("%d lookups", calls)
	}
}
