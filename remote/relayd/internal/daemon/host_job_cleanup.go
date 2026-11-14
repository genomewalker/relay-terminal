package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Archived host-job folders are deleted after a retention period. Each ID
// stays reserved throughout: its tombstone is appended and fsynced before
// the folder is moved into a staging directory and deleted, so after a crash
// at any step either the folder or the tombstone holds the ID.
const (
	hostJobRetentionDefault  = 7 * 24 * time.Hour
	hostJobRetentionMinimum  = time.Hour
	hostJobLedgerWait        = 30 * time.Second
	hostJobCleanupInterval   = time.Hour
	hostJobCleanupFirstDelay = 10 * time.Minute
	hostJobCleanupBatch      = 1000  // tombstones per fsync
	hostJobCleanupDaemonMax  = 20000 // folders per hourly run
	hostJobCleanupListMax    = 20
	hostJobCleanupStagingDir = "host-jobs-cleanup"
)

type HostJobCleanupOptions struct {
	OlderThan time.Duration
	DryRun    bool
	Limit     int           // folders removed per run; zero means no limit
	Wait      time.Duration // for the ledger lock; zero skips a busy run
	// LiveServerPIDs are the live relayd processes on this node, probed on
	// every relayd socket (ProbeHostJobTombstoneServers); each must hold a
	// current registration for this state directory. The daemon includes itself.
	LiveServerPIDs []int
}

type HostJobCleanupResult struct {
	Retention         string   `json:"retention"`
	RetentionSeconds  int64    `json:"retention_seconds"`
	RetentionSource   string   `json:"retention_source"`
	RetentionWarnings []string `json:"retention_warnings,omitempty"`
	Archived          int      `json:"archived"` // daemon pass only: live jobs moved first
	CleanupInactive   bool     `json:"cleanup_inactive,omitempty"`
	// CleanupOtherNode names the activation node when this daemon runs on
	// another node sharing the state directory and therefore only archived.
	CleanupOtherNode  string   `json:"cleanup_other_node,omitempty"`
	Examined          int      `json:"examined"`
	Eligible          int      `json:"eligible"`
	BytesEligible     int64    `json:"bytes_eligible"`
	Removed           int      `json:"removed"`
	BytesFreed        int64    `json:"bytes_freed"`
	TombstonesWritten int      `json:"tombstones_written"`
	EligibleQuery     int      `json:"eligible_query"` // of Eligible: app queries past their hour
	KeptRecent        int      `json:"kept_recent"`
	KeptUnresolved    int      `json:"kept_unresolved"`
	KeptListener      int      `json:"kept_listener"`
	KeptUnreadable    int      `json:"kept_unreadable"`
	KeptOther         int      `json:"kept_other"`
	Unreadable        []string `json:"unreadable,omitempty"`
	StagedRemoved     int      `json:"staged_removed"`
	StagedRestored    int      `json:"staged_restored"`
	LimitReached      bool     `json:"limit_reached"`
	UnawareRecord     string   `json:"unaware_record,omitempty"`
	DryRun            bool     `json:"dry_run"`
}

// Tests stop a run at a step to model a crash there.
type hostJobCleanupHooks struct {
	afterTombstones func() error
	afterStage      func(jobID, staged string) error
}

// ParseHostJobRetention accepts whole days ("7d") or a Go duration ("36h").
func ParseHostJobRetention(text string) (time.Duration, error) {
	var retention time.Duration
	if days, ok := strings.CutSuffix(text, "d"); ok {
		count, err := strconv.ParseInt(days, 10, 64)
		// Checked before multiplying: a larger count would wrap the duration.
		if err != nil || count < 0 || count > int64(math.MaxInt64/int64(24*time.Hour)) {
			return 0, fmt.Errorf("invalid retention %q", text)
		}
		retention = time.Duration(count) * 24 * time.Hour
	} else {
		parsed, err := time.ParseDuration(text)
		if err != nil {
			return 0, fmt.Errorf("invalid retention %q", text)
		}
		retention = parsed
	}
	if retention < hostJobRetentionMinimum {
		return 0, fmt.Errorf("retention %q is below the %v minimum", text, hostJobRetentionMinimum)
	}
	return retention, nil
}

// HostJobRetention is the effective retention and where it came from.
type HostJobRetention struct {
	Duration time.Duration
	Source   string
	Warnings []string
}

// hostJobRetentionFile holds a per-host retention ("1d"), read at every
// pass so it survives supervisor restarts and upgrades that drop the
// environment. It must be a small regular file owned by this user and
// readable by no one else.
const hostJobRetentionFile = "host-job-retention"

// ResolveHostJobRetention: RELAYD_HOST_JOB_RETENTION, then the state
// directory's host-job-retention file, then seven days. A malformed or
// too-short value is rejected with a warning and the default is used.
func ResolveHostJobRetention(stateDir string) HostJobRetention {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	retention := HostJobRetention{Duration: hostJobRetentionDefault, Source: "default"}
	if text := os.Getenv("RELAYD_HOST_JOB_RETENTION"); text != "" {
		parsed, err := ParseHostJobRetention(strings.TrimSpace(text))
		if err != nil {
			retention.Warnings = append(retention.Warnings, "RELAYD_HOST_JOB_RETENTION rejected: "+err.Error()+"; using the default")
			return retention
		}
		return HostJobRetention{Duration: parsed, Source: "env RELAYD_HOST_JOB_RETENTION"}
	}
	path := filepath.Join(stateDir, hostJobRetentionFile)
	text, err := readHostJobRetentionFile(path)
	if os.IsNotExist(err) {
		return retention
	}
	if err == nil {
		var parsed time.Duration
		if parsed, err = ParseHostJobRetention(text); err == nil {
			return HostJobRetention{Duration: parsed, Source: "file " + path}
		}
	}
	retention.Warnings = append(retention.Warnings, path+" rejected: "+err.Error()+"; using the default")
	return retention
}

func readHostJobRetentionFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() > 64 {
		return "", errors.New("not a small regular file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("mode %v is readable or writable by others", info.Mode().Perm())
	}
	if owner, ok := fileOwner(info); ok && owner != os.Getuid() {
		return "", errors.New("not owned by this user")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(raw)), nil
}

func fileOwner(info os.FileInfo) (int, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return int(stat.Uid), true
}

func (r HostJobRetention) apply(result *HostJobCleanupResult) {
	result.Retention = r.Duration.String()
	result.RetentionSeconds = int64(r.Duration / time.Second)
	result.RetentionSource = r.Source
	result.RetentionWarnings = r.Warnings
}

// ApplyHostJobRetention records the retention a run used in its report.
func ApplyHostJobRetention(result *HostJobCleanupResult, retention HostJobRetention) {
	retention.apply(result)
}

func (s *Server) hostJobTombstones() *hostJobTombstoneIndex {
	s.tombstonesOnce.Do(func() { s.tombstones = newHostJobTombstoneIndex(s.stateDir) })
	return s.tombstones
}

// CleanupArchivedHostJobs is `relayd gc-host-jobs`: it runs in its own
// process with its own index, and a running daemon sees its tombstones on
// its next lookup miss.
func CleanupArchivedHostJobs(stateDir string, options HostJobCleanupOptions) (HostJobCleanupResult, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	if options.OlderThan < hostJobRetentionMinimum {
		return HostJobCleanupResult{}, fmt.Errorf("retention is below the %v minimum", hostJobRetentionMinimum)
	}
	return cleanupArchivedHostJobs(stateDir, newHostJobTombstoneIndex(stateDir), options, time.Now(), nil)
}

func (s *Server) runHostJobArchiveCleanup(ctx context.Context) {
	timer := time.NewTimer(hostJobCleanupFirstDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		result, err := s.archiveAndCleanupHostJobs(time.Now())
		recordHostJobCleanup(s.stateDir, result, err)
		timer.Reset(hostJobCleanupInterval)
	}
}

// archiveAndCleanupHostJobs is one serialized daemon pass under the ledger
// lock: finished live jobs older than two minutes move into the archive,
// then archived jobs past the retention are tombstoned and deleted. Without
// it the live ledger grows until the next upgrade. A busy lock skips the pass.
func (s *Server) archiveAndCleanupHostJobs(now time.Time) (HostJobCleanupResult, error) {
	// Read at every pass: a changed setting takes effect without a restart.
	retention := ResolveHostJobRetention(s.stateDir)
	result, err := s.archiveAndCleanupHostJobsWith(retention, now)
	retention.apply(&result)
	return result, err
}

func (s *Server) archiveAndCleanupHostJobsWith(retention HostJobRetention, now time.Time) (HostJobCleanupResult, error) {
	unlock, err := lockHostJobLedger(s.stateDir, 0)
	if err != nil {
		return HostJobCleanupResult{}, err
	}
	defer unlock()
	_ = s.registerHostJobServer(now)
	archived, err := s.archiveFinishedHostJobsLocked(now, hostJobCleanupDaemonMax)
	if err != nil {
		return HostJobCleanupResult{Archived: archived}, err
	}
	// Archiving deletes nothing; deleting waits for activation.
	activation, err := readHostJobActivation(s.stateDir)
	if errors.Is(err, errHostJobCleanupInactive) {
		return HostJobCleanupResult{Archived: archived, CleanupInactive: true}, nil
	}
	// A shared state directory is cleaned by one daemon: the one on the node
	// that activated deletion. A daemon on another node may run an older
	// release with older retention rules, so it only archives.
	if err == nil && !hostJobActivationNodeIs(activation.Node, hostJobServerNode()) {
		return HostJobCleanupResult{Archived: archived, CleanupOtherNode: activation.Node}, nil
	}
	// The same local handshake as gc-host-jobs: every relayd on this node,
	// this one included, must support tombstones and be registered.
	live, err := ProbeHostJobTombstoneServers(s.hostJobPeerSockets)
	if err != nil {
		return HostJobCleanupResult{Archived: archived}, err
	}
	if !slices.Contains(live, os.Getpid()) {
		live = append(live, os.Getpid())
	}
	options := HostJobCleanupOptions{OlderThan: retention.Duration, Limit: hostJobCleanupDaemonMax, LiveServerPIDs: live}
	result, err := cleanupArchivedHostJobsLocked(s.stateDir, s.hostJobTombstones(), options, now, nil)
	result.Archived = archived
	return result, err
}

// SetHostJobPeerSockets names every relayd socket on this node, its own
// included, for the deletion handshake.
func (s *Server) SetHostJobPeerSockets(sockets []string) { s.hostJobPeerSockets = sockets }

// The daemon's last run, for inspection; nothing reads it back.
func recordHostJobCleanup(stateDir string, result HostJobCleanupResult, runErr error) {
	for _, warning := range result.RetentionWarnings {
		fmt.Fprintf(os.Stderr, "relay: host job cleanup warning: %s\n", warning)
	}
	outcome := "ok"
	if result.CleanupInactive {
		outcome = "cleanup inactive (not activated; archived only)"
	}
	if result.CleanupOtherNode != "" {
		outcome = "deletion runs on " + result.CleanupOtherNode + ", the activation node; archived only"
	}
	if runErr != nil {
		outcome = runErr.Error()
	}
	fmt.Fprintf(os.Stderr, "relay: host job cleanup: retention %s (%s); archived %d, removed %d, freed %d bytes, kept unreadable %d: %s\n",
		result.Retention, result.RetentionSource, result.Archived, result.Removed, result.BytesFreed, result.KeptUnreadable, outcome)
	report := map[string]any{"at": time.Now().UTC().Format(time.RFC3339), "result": result}
	if runErr != nil {
		report["error"] = runErr.Error()
	}
	raw, err := json.Marshal(report)
	if err != nil {
		return
	}
	path := filepath.Join(hostJobTombstoneDir(stateDir), "last-cleanup.json")
	if os.WriteFile(path+".tmp", raw, 0600) == nil {
		_ = os.Rename(path+".tmp", path)
	}
}

type hostJobCleanupCandidate struct {
	record hostJobRecord
	bytes  int64
}

func cleanupArchivedHostJobs(stateDir string, index *hostJobTombstoneIndex, options HostJobCleanupOptions, now time.Time, hooks *hostJobCleanupHooks) (HostJobCleanupResult, error) {
	result := HostJobCleanupResult{DryRun: options.DryRun}
	if hooks == nil {
		hooks = &hostJobCleanupHooks{}
	}
	cutoff := now.Add(-options.OlderThan)
	archive := filepath.Join(stateDir, "host-jobs-completed")
	if options.DryRun {
		// A dry run takes no lock and creates nothing.
		_, err := classifyArchivedHostJobs(archive, cutoff, hostJobQueryCutoff(now, options.OlderThan), 0, time.Time{}, nil, &result)
		return result, err
	}
	unlock, err := lockHostJobLedger(stateDir, options.Wait)
	if err != nil {
		return result, err
	}
	defer unlock()
	return cleanupArchivedHostJobsLocked(stateDir, index, options, now, hooks)
}

// cleanupArchivedHostJobsLocked is the cleanup proper. The caller holds the
// ledger lock.
func cleanupArchivedHostJobsLocked(stateDir string, index *hostJobTombstoneIndex, options HostJobCleanupOptions, now time.Time, hooks *hostJobCleanupHooks) (HostJobCleanupResult, error) {
	result := HostJobCleanupResult{}
	if hooks == nil {
		hooks = &hostJobCleanupHooks{}
	}
	cutoff := now.Add(-options.OlderThan)
	archive := filepath.Join(stateDir, "host-jobs-completed")
	baseline, err := hostJobDeletionGuard(stateDir, options.LiveServerPIDs)
	if err != nil {
		return result, err
	}
	if err := index.Load(); err != nil {
		return result, err
	}
	// Before any delete, including the staging sweep: tombstones from an
	// earlier run count only once this run has synced them.
	if err := syncHostJobTombstones(stateDir); err != nil {
		return result, err
	}
	unaware, err := liveUnawareHostJobs(stateDir, baseline)
	if err != nil {
		return result, err
	}
	candidates, err := classifyArchivedHostJobs(archive, cutoff, hostJobQueryCutoff(now, options.OlderThan), options.Limit, baseline, &unaware, &result)
	if err != nil {
		return result, err
	}
	if len(unaware) > 0 {
		// Sticky: the block outlives the records; see host_job_servers.go.
		result.UnawareRecord = unaware[0].JobID
		if err := recordHostJobLegacyEvidence(stateDir, unaware, now); err != nil {
			return result, err
		}
		evidence, _, _ := readHostJobLegacyEvidence(stateDir)
		return result, legacyEvidenceError(evidence)
	}
	if err := sweepHostJobCleanupStaging(stateDir, index, &result); err != nil {
		return result, err
	}
	for start := 0; start < len(candidates); start += hostJobCleanupBatch {
		batch := candidates[start:min(start+hostJobCleanupBatch, len(candidates))]
		var pending []hostJobTombstone
		for _, candidate := range batch {
			_, found, err := index.Lookup(candidate.record.JobID)
			if err != nil {
				return result, err
			}
			if !found {
				pending = append(pending, hostJobTombstoneFor(candidate.record))
			}
		}
		if err := appendHostJobTombstones(stateDir, pending, now); err != nil {
			return result, err
		}
		result.TombstonesWritten += len(pending)
		if hooks.afterTombstones != nil {
			if err := hooks.afterTombstones(); err != nil {
				return result, err
			}
		}
		for _, candidate := range batch {
			removed, err := removeArchivedHostJob(stateDir, index, candidate.record, hooks)
			if err != nil {
				return result, err
			}
			if removed {
				result.Removed++
				result.BytesFreed += candidate.bytes
			}
		}
	}
	return result, nil
}

func hostJobTombstoneFor(record hostJobRecord) hostJobTombstone {
	return hostJobTombstone{JobID: record.JobID, Fingerprint: record.Fingerprint, CreatedAt: record.CreatedAt,
		UpdatedAt: record.UpdatedAt, State: record.State, ExitCode: record.ExitCode}
}

// hostJobQueryCutoff is the cutoff for app query records: an hour, or the
// host retention when that is shorter.
func hostJobQueryCutoff(now time.Time, retention time.Duration) time.Time {
	return now.Add(-min(retention, hostJobQueryRetentionAge))
}

// classifyArchivedHostJobs counts every archive entry and returns the
// eligible ones, at most limit when limit is positive: finished, older than
// the cutoff (queryCutoff for app query records), not a peer listener, with
// a readable record naming its folder.
func classifyArchivedHostJobs(archive string, cutoff, queryCutoff time.Time, limit int, baseline time.Time, unaware *[]hostJobRecord, result *HostJobCleanupResult) ([]hostJobCleanupCandidate, error) {
	entries, err := os.ReadDir(archive)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var candidates []hostJobCleanupCandidate
	for _, entry := range entries {
		result.Examined++
		if !entry.IsDir() || !validSessionID.MatchString(entry.Name()) {
			result.KeptOther++
			continue
		}
		directory := filepath.Join(archive, entry.Name())
		record, err := readArchivedHostJobRecord(directory, entry.Name())
		if err != nil {
			result.KeptUnreadable++
			if len(result.Unreadable) < hostJobCleanupListMax {
				result.Unreadable = append(result.Unreadable, entry.Name())
			}
			continue
		}
		if unaware != nil && unawareHostJobRecord(record, baseline) {
			*unaware = append(*unaware, record)
		}
		if record.State != "exited" && record.State != "failed" {
			result.KeptUnresolved++
			continue
		}
		if record.Kind == hostJobKindPeerListener || record.Listener != nil {
			result.KeptListener++
			continue
		}
		finished, err := time.Parse(time.RFC3339Nano, record.UpdatedAt)
		if err != nil {
			result.KeptUnreadable++
			if len(result.Unreadable) < hostJobCleanupListMax {
				result.Unreadable = append(result.Unreadable, entry.Name())
			}
			continue
		}
		query := record.Retention == hostJobRetentionQuery
		if !finished.Before(cutoff) && !(query && finished.Before(queryCutoff)) {
			result.KeptRecent++
			continue
		}
		if limit > 0 && len(candidates) >= limit {
			result.LimitReached = true
			continue
		}
		bytes := hostJobFolderBytes(directory)
		result.Eligible++
		if query && !finished.Before(cutoff) {
			result.EligibleQuery++
		}
		result.BytesEligible += bytes
		candidates = append(candidates, hostJobCleanupCandidate{record: record, bytes: bytes})
	}
	return candidates, nil
}

func readArchivedHostJobRecord(directory, jobID string) (hostJobRecord, error) {
	var record hostJobRecord
	path := filepath.Join(directory, "record.json")
	info, err := os.Lstat(path)
	if err != nil {
		return record, err
	}
	if !info.Mode().IsRegular() || info.Size() > 65536 {
		return record, errors.New("record is not a small regular file")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return record, err
	}
	if err := json.Unmarshal(raw, &record); err != nil {
		return record, err
	}
	if record.JobID != jobID {
		return record, errors.New("record names another job")
	}
	return record, nil
}

func hostJobFolderBytes(directory string) int64 {
	var total int64
	_ = filepath.WalkDir(directory, func(_ string, entry fs.DirEntry, err error) error {
		if err == nil && entry.Type().IsRegular() {
			if info, infoErr := entry.Info(); infoErr == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

// removeArchivedHostJob deletes one archived folder whose tombstone is
// durable: one rename takes it out of the archive, the staged record is
// checked against the tombstone, then it is deleted. The caller holds the
// ledger lock.
func removeArchivedHostJob(stateDir string, index *hostJobTombstoneIndex, record hostJobRecord, hooks *hostJobCleanupHooks) (bool, error) {
	tombstone, found, err := index.Lookup(record.JobID)
	if err != nil {
		return false, err
	}
	if !found || tombstone.Fingerprint != record.Fingerprint || tombstone.CreatedAt != record.CreatedAt {
		return false, fmt.Errorf("job %s has no matching tombstone; its folder was kept", record.JobID)
	}
	staging := filepath.Join(stateDir, hostJobCleanupStagingDir)
	if err := os.MkdirAll(staging, 0700); err != nil {
		return false, err
	}
	directory := filepath.Join(stateDir, "host-jobs-completed", record.JobID)
	staged := filepath.Join(staging, fmt.Sprintf("%s.%d", record.JobID, time.Now().UnixNano()))
	if err := os.Rename(directory, staged); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if hooks.afterStage != nil {
		if err := hooks.afterStage(record.JobID, staged); err != nil {
			return false, err
		}
	}
	moved, err := readArchivedHostJobRecord(staged, record.JobID)
	if err != nil || moved.Fingerprint != record.Fingerprint || moved.CreatedAt != record.CreatedAt {
		// Not the folder that was inspected: put it back, still reserved.
		if restoreErr := os.Rename(staged, directory); restoreErr != nil {
			return false, fmt.Errorf("job %s changed during cleanup and is held at %s: %w", record.JobID, staged, restoreErr)
		}
		return false, fmt.Errorf("job %s changed during cleanup; its folder was restored", record.JobID)
	}
	return true, os.RemoveAll(staged)
}

// sweepHostJobCleanupStaging finishes a run that stopped after staging: a
// staged folder with a tombstone is deleted; one without (not produced by
// this ordering) is returned to the archive.
func sweepHostJobCleanupStaging(stateDir string, index *hostJobTombstoneIndex, result *HostJobCleanupResult) error {
	staging := filepath.Join(stateDir, hostJobCleanupStagingDir)
	entries, err := os.ReadDir(staging)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		dot := strings.LastIndexByte(entry.Name(), '.')
		if dot <= 0 || !validSessionID.MatchString(entry.Name()[:dot]) {
			continue
		}
		jobID, staged := entry.Name()[:dot], filepath.Join(staging, entry.Name())
		_, found, err := index.Lookup(jobID)
		if err != nil {
			return err
		}
		if found {
			if err := os.RemoveAll(staged); err != nil {
				return err
			}
			result.StagedRemoved++
			continue
		}
		target := filepath.Join(stateDir, "host-jobs-completed", jobID)
		if _, err := os.Lstat(target); !os.IsNotExist(err) {
			return fmt.Errorf("staged job %s has no tombstone and its archive slot is taken", jobID)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err := os.Rename(staged, target); err != nil {
			return err
		}
		result.StagedRestored++
	}
	return nil
}
