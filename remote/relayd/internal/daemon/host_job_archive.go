package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type HostJobArchiveResult struct {
	Archived int
	Retained int
}

// hostJobArchiveAge is how long a finished job stays in the live ledger
// before an upgrade may move it. Status reads of a finished job are served
// from the archive as well, so this only needs to outlast a client's last read.
const hostJobArchiveAge = 2 * time.Minute

// ArchiveCompletedHostJobs makes room for the bounded legacy upgrade guard.
// Entire completed job directories are retained, including output and the
// durable execution fingerprint. Recent and unresolved jobs, and listener
// records the registry still names, stay in place.
func ArchiveCompletedHostJobs(stateDir string) (HostJobArchiveResult, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	return archiveCompletedHostJobs(stateDir, 3000, time.Now().Add(-hostJobArchiveAge))
}

func archiveCompletedHostJobs(stateDir string, keep int, cutoff time.Time) (HostJobArchiveResult, error) {
	var result HostJobArchiveResult
	root := filepath.Join(stateDir, "host-jobs")
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	result.Retained = len(entries)
	if result.Retained <= keep {
		return result, nil
	}
	// Moves into the archive never interleave with its cleanup, in any process.
	unlock, err := lockHostJobLedger(stateDir, hostJobLedgerWait)
	if err != nil {
		return result, err
	}
	defer unlock()
	archive := filepath.Join(stateDir, "host-jobs-completed")
	if err := os.MkdirAll(archive, 0700); err != nil {
		return result, err
	}
	listeners := registeredListenerJobs(stateDir)
	for _, entry := range entries {
		if result.Retained <= keep {
			break
		}
		if !entry.IsDir() || !validSessionID.MatchString(entry.Name()) {
			continue
		}
		directory := filepath.Join(root, entry.Name())
		path := filepath.Join(directory, "record.json")
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			continue
		}
		raw, err := os.ReadFile(path)
		var record hostJobRecord
		if err != nil || json.Unmarshal(raw, &record) != nil || record.JobID != entry.Name() ||
			!hostJobArchivable(record, cutoff, listeners) {
			continue
		}
		target := filepath.Join(archive, entry.Name())
		if _, err := os.Lstat(target); !os.IsNotExist(err) {
			return result, fmt.Errorf("completed job archive already reserves %s", entry.Name())
		}
		if err := os.Rename(directory, target); err != nil {
			return result, err
		}
		result.Archived++
		result.Retained--
	}
	if result.Retained > keep {
		return result, fmt.Errorf("upgrade deferred: %d recent or unresolved job records remain", result.Retained)
	}
	return result, nil
}

// hostJobArchivable: finished and last updated before the cutoff. A finished
// peer listener moves too, unless the listener registry still names it: the
// registry's job is the one a resume or upgrade links a successor into, so
// its folder must not move under that write. A moved listener record stays
// readable (status, disconnect and successor lookups read the archive as
// well) and the archive cleanup never deletes listener records. listeners is
// nil when the registry could not be read; then no listener moves.
func hostJobArchivable(record hostJobRecord, cutoff time.Time, listeners map[string]bool) bool {
	if record.State != "exited" && record.State != "failed" {
		return false
	}
	if record.Kind == hostJobKindPeerListener || record.Listener != nil {
		if listeners == nil || listeners[record.JobID] {
			return false
		}
	}
	finished, err := time.Parse(time.RFC3339Nano, record.UpdatedAt)
	return err == nil && finished.Before(cutoff)
}

// registeredListenerJobs names every job the listener registry refers to. It
// returns nil when the directory or any registry record cannot be read or
// parsed, so an unreadable registry keeps every listener record in place.
func registeredListenerJobs(stateDir string) map[string]bool {
	named := map[string]bool{}
	entries, err := os.ReadDir(filepath.Join(stateDir, "peer-listeners"))
	if os.IsNotExist(err) {
		return named
	}
	if err != nil {
		return nil
	}
	for _, entry := range entries {
		// Only <hash>.json entries are registry records, as resume reads them;
		// a writer's .entry-* temp file left by a crash is not one.
		name := entry.Name()
		if entry.IsDir() || strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(stateDir, "peer-listeners", name))
		if errors.Is(err, os.ErrNotExist) {
			continue // removed since the listing: it names nothing now
		}
		if err != nil {
			return nil
		}
		var head struct {
			JobID string `json:"job_id"`
		}
		if json.Unmarshal(data, &head) != nil {
			// A partial temp file or a foreign file: be conservative.
			return nil
		}
		if head.JobID != "" {
			named[head.JobID] = true
		}
	}
	return named
}

// archiveFinishedHostJobsLocked is the daemon's periodic archive step, with
// the upgrade step's rules but no keep threshold: every finished job older
// than hostJobArchiveAge moves, at most limit per pass. A job this daemon
// still tracks is checked and moved under its own lock, and its directory
// follows it, so status reads keep working. The caller holds the ledger lock.
func (s *Server) archiveFinishedHostJobsLocked(now time.Time, limit int) (int, error) {
	root := filepath.Join(s.stateDir, "host-jobs")
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	archive := filepath.Join(s.stateDir, "host-jobs-completed")
	if err := os.MkdirAll(archive, 0700); err != nil {
		return 0, err
	}
	cutoff := now.Add(-hostJobArchiveAge)
	listeners := registeredListenerJobs(s.stateDir)
	archived := 0
	for _, entry := range entries {
		if limit > 0 && archived >= limit {
			break
		}
		if !entry.IsDir() || !validSessionID.MatchString(entry.Name()) {
			continue
		}
		directory, target := filepath.Join(root, entry.Name()), filepath.Join(archive, entry.Name())
		if value, ok := s.hostJobs.Load(entry.Name()); ok {
			job := value.(*hostJob)
			job.mu.Lock()
			moved := job.directory == directory && hostJobArchivable(job.record, cutoff, listeners) && moveHostJobFolder(directory, target)
			if moved {
				job.directory = target
				archived++
			}
			job.mu.Unlock()
			continue
		}
		record, err := readArchivedHostJobRecord(directory, entry.Name())
		if err == nil && hostJobArchivable(record, cutoff, listeners) && moveHostJobFolder(directory, target) {
			archived++
		}
	}
	return archived, nil
}

// hostJobSnapshotAttempts bounds how often one status read follows a folder
// that moves (live to archive, archive to deleted) while it is being read.
const hostJobSnapshotAttempts = 4

// Tests run a peer's archive or cleanup between a folder's lookup and the
// opening of its output.
var hostJobBeforeSnapshot = func(jobID, directory string) {}

// resolveHostJobSnapshot reads a job's output from directory. If the folder
// of a finished job is gone, it looks again: the live ledger, then the
// archive, then the tombstone, a bounded number of times, since a peer
// daemon sharing the state directory can move or clean the folder at any
// point; job.mu does not hold it off. Only this generation is ever served:
// a folder or tombstone must match the job ID, fingerprint and creation
// time. A tracked job (job non-nil, job.mu held) remembers the new folder.
func (s *Server) resolveHostJobSnapshot(job *hostJob, record hostJobRecord, directory string, r hostRequest) (any, error) {
	finished := record.State == "exited" || record.State == "failed"
	var err error
	for attempt := 0; attempt < hostJobSnapshotAttempts; attempt++ {
		hostJobBeforeSnapshot(record.JobID, directory)
		var snapshot any
		snapshot, err = hostJobSnapshot(record, directory, r)
		if !errors.Is(err, os.ErrNotExist) || !finished {
			return snapshot, err
		}
		if moved, found := s.locateHostJobFolder(record); found {
			directory = moved
			if job != nil {
				job.directory = moved
			}
			continue // the folder may vanish again before the next open
		}
		tombstone, found, lookupErr := s.hostJobTombstones().Lookup(record.JobID)
		if lookupErr == nil && found && tombstone.Fingerprint == record.Fingerprint && tombstone.CreatedAt == record.CreatedAt {
			return hostJobTombstoneSnapshot(tombstone, r)
		}
		// Between the archive's rename and the tombstone's index refresh
		// nothing is visible yet; look again.
	}
	return nil, err
}

// relocateTrackedHostJob points a tracked job at its own folder when that
// has moved from job.directory. The caller holds job.mu.
func (s *Server) relocateTrackedHostJob(job *hostJob) (string, bool) {
	directory, found := s.locateHostJobFolder(job.record)
	if !found || directory == job.directory {
		return "", false
	}
	job.directory = directory
	return directory, true
}

// locateHostJobFolder finds record's own folder, live or archived.
func (s *Server) locateHostJobFolder(record hostJobRecord) (string, bool) {
	for _, root := range []string{"host-jobs", "host-jobs-completed"} {
		directory := filepath.Join(s.stateDir, root, record.JobID)
		found, err := readArchivedHostJobRecord(directory, record.JobID)
		if err == nil && found.Fingerprint == record.Fingerprint && found.CreatedAt == record.CreatedAt {
			return directory, true
		}
	}
	return "", false
}

// An archive slot that is already taken keeps both folders where they are.
func moveHostJobFolder(directory, target string) bool {
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		return false
	}
	return os.Rename(directory, target) == nil
}

// A completed archive remains a reservation: losing the live directory must
// never allow the same job ID to launch the command a second time. Once the
// archive cleanup has deleted a folder, its tombstone is the reservation:
// tombstone is then non-nil and directory empty.
func (s *Server) readHostJobRecord(jobID string) ([]byte, string, *hostJobTombstone, error) {
	raw, directory, err := readHostJobFolder(s.stateDir, jobID)
	if !errors.Is(err, os.ErrNotExist) {
		return raw, directory, nil, err
	}
	// The cleanup writes the tombstone durably before it moves the folder,
	// so a reader that missed the folder finds the tombstone.
	tombstone, found, lookupErr := s.hostJobTombstones().Lookup(jobID)
	if lookupErr != nil {
		return nil, directory, nil, lookupErr
	}
	if !found {
		return nil, directory, nil, os.ErrNotExist
	}
	raw, err = json.Marshal(tombstone.record())
	return raw, "", &tombstone, err
}

func readHostJobFolder(stateDir, jobID string) ([]byte, string, error) {
	for _, root := range []string{"host-jobs", "host-jobs-completed"} {
		directory := filepath.Join(stateDir, root, jobID)
		raw, err := os.ReadFile(filepath.Join(directory, "record.json"))
		if err == nil {
			return raw, directory, nil
		}
		if !os.IsNotExist(err) {
			return nil, directory, err
		}
		if _, directoryErr := os.Lstat(directory); !os.IsNotExist(directoryErr) {
			return nil, directory, errors.New("reserved host job has an unreadable record; do not replay")
		}
	}
	return nil, filepath.Join(stateDir, "host-jobs", jobID), os.ErrNotExist
}
