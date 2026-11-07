package daemon

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The durable peer-listener registry lets a new supervisor resume the message
// listeners its predecessor drained for an upgrade. One entry per route holds
// the typed launch specification and the owning agent's identity; it never
// holds a secret. Each launched listener derives its own mailbox token.

var (
	peerListenerRoute   = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}$`)
	peerListenerSession = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)
)

const (
	peerListenerEntryLimit = 512 << 10
	peerListenerScriptMax  = 256 << 10
	peerListenerMaxEntries = 256
)

// The registry directory of the owner's own account: the CLAUDE_CONFIG_DIR of
// that exact process, or ~/.claude when it has none. An unreadable environment
// is an error, never a fallback to another account. A variable so tests can
// substitute a registry without spawning agent processes.
var peerListenerOwnerRegistry = func(pid int) (string, error) {
	root, err := agentConfigRoot(pid, "claude")
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "sessions"), nil
}

type peerListenerSpec struct {
	Executable   string `json:"executable,omitempty"`
	Interpreter  string `json:"interpreter"`
	Script       string `json:"script"`
	Route        string `json:"route"`
	OwnerPID     int    `json:"owner_pid"`
	OwnerStart   string `json:"owner_start"`
	OwnerSession string `json:"owner_session"`
}

func (spec *peerListenerSpec) validate() error {
	if spec.Executable != "" {
		if spec.Interpreter != "" || spec.Script != "" || len(spec.Executable) > 4096 || strings.ContainsAny(spec.Executable, "\x00\r\n") ||
			(spec.Executable != ".local/bin/relayd" && (!filepath.IsAbs(spec.Executable) || filepath.Clean(spec.Executable) != spec.Executable)) {
			return errors.New("invalid native peer listener executable")
		}
	} else {
		// Retained for exact readback of old registrations and their drain
		// receipts. A Python registration cannot be launched by this daemon.
		interpreter := spec.Interpreter
		if interpreter == "" || len(interpreter) > 4096 || strings.ContainsAny(interpreter, "\x00\n") ||
			(!filepath.IsAbs(interpreter) && strings.Contains(interpreter, "/")) {
			return errors.New("invalid peer listener interpreter")
		}
		if spec.Script == "" || len(spec.Script) > peerListenerScriptMax || strings.ContainsRune(spec.Script, 0) {
			return errors.New("invalid peer listener script")
		}
	}
	if !peerListenerRoute.MatchString(spec.Route) || !peerListenerSession.MatchString(spec.OwnerSession) {
		return errors.New("invalid peer listener route or owner session")
	}
	if spec.OwnerPID <= 1 || spec.OwnerStart == "" || len(spec.OwnerStart) > 64 || strings.ContainsAny(spec.OwnerStart, "\x00\n") {
		return errors.New("invalid peer listener owner identity")
	}
	return nil
}

// The listener's positional contract (relay-desktop-remote.py listen).
func (spec *peerListenerSpec) argv() []string {
	if spec.Executable != "" {
		return []string{spec.Executable, "desktop-remote", "listen", strconv.Itoa(spec.OwnerPID), spec.OwnerSession, spec.OwnerStart, spec.Route}
	}
	return []string{spec.Interpreter, "-u", "-c", spec.Script, "listen",
		strconv.Itoa(spec.OwnerPID), spec.OwnerSession, spec.OwnerStart, spec.Route}
}

// The same address the listener derives; recorded for inspection only.
func peerListenerMailbox(route string) string {
	sum := sha256.Sum256([]byte(route))
	return filepath.Join("/tmp", fmt.Sprintf("relay-desktop-%d", os.Getuid()), hex.EncodeToString(sum[:])[:24])
}

type peerListenerOwner struct {
	PID     int    `json:"pid"`
	Start   string `json:"start"`
	Session string `json:"session"`
}

// Route and owner, the identity every job in one successor chain shares.
type peerListenerBinding struct {
	Route string            `json:"route"`
	Owner peerListenerOwner `json:"owner"`
}

func (spec *peerListenerSpec) binding() *peerListenerBinding {
	if spec == nil {
		return nil
	}
	return &peerListenerBinding{Route: spec.Route,
		Owner: peerListenerOwner{PID: spec.OwnerPID, Start: spec.OwnerStart, Session: spec.OwnerSession}}
}

type peerListenerLaunch struct {
	Executable  string `json:"executable,omitempty"`
	Interpreter string `json:"interpreter"`
	Script      string `json:"script"`
	Cwd         string `json:"cwd,omitempty"`
}

type peerListenerEntry struct {
	Version   int                `json:"version"`
	Kind      string             `json:"kind"`
	Route     string             `json:"route"`
	Mailbox   string             `json:"mailbox"`
	Owner     peerListenerOwner  `json:"owner"`
	Launch    peerListenerLaunch `json:"launch"`
	JobID     string             `json:"job_id"`
	State     string             `json:"state"` // "active" while served, "suspended" when drained for upgrade
	UpdatedAt string             `json:"updated_at"`
}

func (entry peerListenerEntry) spec() *peerListenerSpec {
	return &peerListenerSpec{Executable: entry.Launch.Executable, Interpreter: entry.Launch.Interpreter, Script: entry.Launch.Script, Route: entry.Route,
		OwnerPID: entry.Owner.PID, OwnerStart: entry.Owner.Start, OwnerSession: entry.Owner.Session}
}

func (s *Server) peerListenerDir() string { return filepath.Join(s.stateDir, "peer-listeners") }

func (s *Server) peerListenerPath(route string) string {
	sum := sha256.Sum256([]byte(route))
	return filepath.Join(s.peerListenerDir(), hex.EncodeToString(sum[:])[:32]+".json")
}

// Read refuses symlinks, foreign or group/world-accessible files, oversize
// files and entries that do not describe the route their name is derived from.
func (s *Server) readPeerListenerFile(path string) (peerListenerEntry, error) {
	var entry peerListenerEntry
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return entry, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return entry, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || int(stat.Uid) != os.Getuid() || info.Mode().Perm() != 0o600 || info.Size() > peerListenerEntryLimit {
		return entry, errors.New("unsafe peer listener registry entry")
	}
	data, err := io.ReadAll(io.LimitReader(file, peerListenerEntryLimit+1))
	if err != nil || len(data) > peerListenerEntryLimit || json.Unmarshal(data, &entry) != nil {
		return entry, errors.New("invalid peer listener registry entry")
	}
	if entry.Version != 1 || entry.Kind != hostJobKindPeerListener || !validSessionID.MatchString(entry.JobID) ||
		(entry.State != "active" && entry.State != "suspended") || entry.spec().validate() != nil ||
		entry.Mailbox != peerListenerMailbox(entry.Route) || s.peerListenerPath(entry.Route) != path {
		return entry, errors.New("invalid peer listener registry entry")
	}
	return entry, nil
}

func (s *Server) writePeerListenerEntry(entry peerListenerEntry) error {
	entry.Version, entry.Kind, entry.Mailbox = 1, hostJobKindPeerListener, peerListenerMailbox(entry.Route)
	entry.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if err := entry.spec().validate(); err != nil {
		return err
	}
	data, err := json.Marshal(entry)
	if err != nil || len(data) > peerListenerEntryLimit {
		return errors.New("peer listener registry entry exceeds limit")
	}
	if err := EnsurePrivateRuntimeDir(s.peerListenerDir()); err != nil {
		return err
	}
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return err
	}
	temp := filepath.Join(s.peerListenerDir(), ".entry-"+hex.EncodeToString(suffix[:]))
	fd, err := syscall.Open(temp, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), temp)
	defer os.Remove(temp)
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	// rename replaces a planted symlink itself; it never writes through one.
	if err := os.Rename(temp, s.peerListenerPath(entry.Route)); err != nil {
		return err
	}
	directory, err := os.Open(s.peerListenerDir())
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func (s *Server) recordPeerListener(spec *peerListenerSpec, cwd, jobID string) error {
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	return s.writePeerListenerEntry(peerListenerEntry{Route: spec.Route, JobID: jobID, State: "active",
		Owner:  peerListenerOwner{PID: spec.OwnerPID, Start: spec.OwnerStart, Session: spec.OwnerSession},
		Launch: peerListenerLaunch{Executable: spec.Executable, Interpreter: spec.Interpreter, Script: spec.Script, Cwd: cwd}})
}

// A natural exit ends the registration; a suspended entry awaits resume.
func (s *Server) releasePeerListener(route, jobID string) {
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	path := s.peerListenerPath(route)
	if entry, err := s.readPeerListenerFile(path); err == nil && entry.JobID == jobID && entry.State == "active" {
		_ = os.Remove(path)
	}
}

// Marked durably before the drain signal, so the exit is not a deregistration.
func (s *Server) suspendPeerListener(route, jobID string) error {
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	entry, err := s.readPeerListenerFile(s.peerListenerPath(route))
	if err != nil {
		return err
	}
	if entry.JobID != jobID || entry.State != "active" {
		return errors.New("peer listener registry does not name this job")
	}
	entry.State = "suspended"
	return s.writePeerListenerEntry(entry)
}

func (s *Server) peerListenerRegistered(route, jobID string) bool {
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	entry, err := s.readPeerListenerFile(s.peerListenerPath(route))
	return err == nil && entry.JobID == jobID && entry.State == "active"
}

// The caller holds hostJobsMu.
func (s *Server) activePeerListenerLocked(route string) string {
	serving := ""
	s.hostJobs.Range(func(key, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		if job.listener != nil && job.listener.Route == route && (job.record.State == "starting" || job.record.State == "running") {
			serving = key.(string)
		}
		job.mu.Unlock()
		return serving == ""
	})
	return serving
}

// The caller holds hostJobsMu. The ID is durably reserved as terminal.
func (s *Server) reserveSupersededHostJob(r hostRequest, fingerprint, directory, serving string) (any, error) {
	if e := os.MkdirAll(filepath.Dir(directory), 0700); e != nil {
		return nil, e
	}
	if e := os.Mkdir(directory, 0700); e != nil {
		return nil, errors.New("job ID already reserved")
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	job := &hostJob{notify: make(chan struct{}, 1), directory: directory, record: hostJobRecord{JobID: r.JobID, Fingerprint: fingerprint,
		Kind: r.Kind, Listener: r.Listener.binding(), State: "failed", Error: "peer listener route is already served; no process was started", Successor: serving, CreatedAt: now, Ledger: hostJobLedgerTombstones}}
	if e := job.save(); e != nil {
		return nil, e
	}
	s.hostJobs.Store(r.JobID, job)
	return job.record, nil
}

// The owner is gone or is no longer the recorded incarnation or conversation.
// Its entry can never be restored, so resumption drops it.
var errPeerListenerOwnerChanged = errors.New("peer listener owner process ended or changed")

// The owner must be the same live agent incarnation in the same conversation,
// checked against the kernel and the owner's own account registry. Only
// errPeerListenerOwnerChanged proves the owner is gone; any other error means
// the owner could not be verified now, and the caller must not restore it.
func verifyPeerListenerOwner(owner peerListenerOwner) error {
	if start, err := processStartIdentity(owner.PID); err != nil {
		if errors.Is(syscall.Kill(owner.PID, 0), syscall.ESRCH) {
			return errPeerListenerOwnerChanged
		}
		return errors.New("peer listener owner identity unavailable")
	} else if start != owner.Start {
		return errPeerListenerOwnerChanged
	}
	registry, err := peerListenerOwnerRegistry(owner.PID)
	if err != nil {
		return err
	}
	path := filepath.Join(registry, strconv.Itoa(owner.PID)+".json")
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("peer listener owner registration is unavailable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0o022 != 0 || info.Size() > 65536 {
		return errors.New("unsafe peer listener owner registration")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return errors.New("peer listener owner registration is unreadable")
	}
	var record struct {
		PID       int    `json:"pid"`
		SessionID string `json:"sessionId"`
		ProcStart string `json:"procStart"`
	}
	if json.Unmarshal(data, &record) != nil {
		return errors.New("peer listener owner registration is unparsable")
	}
	if record.PID != owner.PID || record.SessionID != owner.Session || record.ProcStart != owner.Start {
		return errPeerListenerOwnerChanged
	}
	return nil
}

func (s *Server) resumePeerListeners() int {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	return s.resumePeerListenersLocked()
}

// The caller holds hostJobsMu. Only entries drained by an upgrade resume, and
// only for an owner verified now. An owner that ended or changed removes its
// entry; one that cannot be verified leaves it suspended.
func (s *Server) resumePeerListenersLocked() int {
	entries, err := os.ReadDir(s.peerListenerDir())
	if err != nil || len(entries) > peerListenerMaxEntries {
		return 0
	}
	resumed := 0
	for _, item := range entries {
		if !strings.HasSuffix(item.Name(), ".json") || strings.HasPrefix(item.Name(), ".") {
			continue
		}
		path := filepath.Join(s.peerListenerDir(), item.Name())
		s.peerListenersMu.Lock()
		entry, err := s.readPeerListenerFile(path)
		s.peerListenersMu.Unlock()
		if err != nil || entry.State != "suspended" || s.activePeerListenerLocked(entry.Route) != "" {
			continue // unverifiable entries are left for inspection, never launched
		}
		if err := verifyPeerListenerOwner(entry.Owner); err != nil {
			// Only a proven change drops the entry. An owner that cannot be
			// verified now (its account unreadable, its registration briefly
			// missing) keeps its suspended entry for a later start: the inbox is
			// not restored, and it is not lost.
			if errors.Is(err, errPeerListenerOwnerChanged) {
				s.peerListenersMu.Lock()
				if current, readErr := s.readPeerListenerFile(path); readErr == nil && current.JobID == entry.JobID {
					_ = os.Remove(path)
				}
				s.peerListenersMu.Unlock()
			}
			continue
		}
		var id [16]byte
		if _, err := rand.Read(id[:]); err != nil {
			continue
		}
		spec, err := nativePeerListenerSuccessor(entry.spec())
		if err != nil {
			continue
		} // Unknown legacy source remains suspended for inspection.
		r := hostRequest{JobID: "job-" + hex.EncodeToString(id[:]), Kind: hostJobKindPeerListener, KeepStdin: true,
			Cwd: entry.Launch.Cwd, Listener: spec}
		directory := filepath.Join(s.stateDir, "host-jobs", r.JobID)
		result, err := s.launchHostJobLocked(r, hostJobFingerprint(r), directory)
		if record, ok := result.(hostJobRecord); err != nil || !ok || record.State != "running" {
			continue // the entry stays suspended; the next supervisor start retries
		}
		s.linkHostJobSuccessor(entry.JobID, r.JobID)
		resumed++
	}
	return resumed
}

// The drained job names its successor so its client follows the resumed
// listener instead of launching another one.
func (s *Server) linkHostJobSuccessor(previous, successor string) {
	if value, ok := s.hostJobs.Load(previous); ok {
		job := value.(*hostJob)
		job.mu.Lock()
		job.record.Successor = successor
		job.save()
		job.mu.Unlock()
		return
	}
	raw, directory, tombstone, err := s.readHostJobRecord(previous)
	if err != nil || tombstone != nil {
		return // a tombstone has no record to update
	}
	job := &hostJob{directory: directory}
	if json.Unmarshal(raw, &job.record) != nil || job.record.JobID != previous {
		return
	}
	job.record.Successor = successor
	job.save()
}

// An explicit disconnect addresses the inbox, not one incarnation of it: the
// client may still name a drained or superseded job, any number of handoffs
// ago, while the registry has resumed its inbox under a later successor. Every
// incarnation of one inbox carries the same binding (route and exact owner
// pid, start and session), so the cancel resolves the inbox by that binding
// directly instead of walking the successor chain: it removes the route's
// registration when its owner is this exact owner, and stops every running
// job with this binding. A registration or job of any other owner is never
// touched. Holding hostJobsMu serializes it with resume, reservation and
// upgrade preparation, so a cancelled inbox is never relaunched from a stale
// entry. It reports handled=false for any job that is not a peer listener.
func (s *Server) cancelPeerListenerJob(jobID string) (any, bool, error) {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	addressed, ok := s.peerListenerChainRecord(jobID)
	if !ok {
		return nil, false, nil
	}
	binding := *addressed.Listener
	if err := s.removePeerListenerBinding(binding); err != nil {
		return nil, true, err
	}
	var signalErr error
	s.hostJobs.Range(func(_, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		defer job.mu.Unlock()
		if job.record.Listener == nil || *job.record.Listener != binding || job.cmd == nil || job.record.State != "running" {
			return true
		}
		if err := syscall.Kill(-job.cmd.Process.Pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
			signalErr = err
			return false
		}
		return true
	})
	if signalErr != nil {
		return nil, true, signalErr
	}
	if addressed.State == "running" || addressed.State == "starting" {
		if _, ok := s.hostJobs.Load(addressed.JobID); !ok {
			addressed.State = "unknown_after_daemon_restart"
		}
	}
	return addressed, true, nil
}

// Removes the route's registration when it belongs to this exact owner,
// whichever incarnation it names. An unreadable entry for the route cannot be
// attributed to another owner and must not outlive an explicit disconnect.
func (s *Server) removePeerListenerBinding(binding peerListenerBinding) error {
	s.peerListenersMu.Lock()
	defer s.peerListenersMu.Unlock()
	path := s.peerListenerPath(binding.Route)
	entry, err := s.readPeerListenerFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err == nil && (entry.Route != binding.Route || entry.Owner != binding.Owner) {
		return nil
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// A listener job's record, from memory or the durable ledger. The caller
// holds hostJobsMu.
func (s *Server) peerListenerChainRecord(jobID string) (hostJobRecord, bool) {
	var record hostJobRecord
	if value, ok := s.hostJobs.Load(jobID); ok {
		job := value.(*hostJob)
		job.mu.Lock()
		record = job.record
		job.mu.Unlock()
	} else {
		raw, _, tombstone, err := s.readHostJobRecord(jobID)
		if err != nil || tombstone != nil || json.Unmarshal(raw, &record) != nil || record.JobID != jobID {
			return hostJobRecord{}, false
		}
	}
	if record.Kind != hostJobKindPeerListener || record.Listener == nil {
		return hostJobRecord{}, false
	}
	return record, true
}
