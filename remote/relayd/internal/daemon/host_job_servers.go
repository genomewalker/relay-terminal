package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A relayd that predates tombstones checks only the job folders, so once a
// folder is deleted it would admit that job ID again. Every delete path (the
// hourly pass and gc-host-jobs) therefore passes hostJobDeletionGuard:
//
//   - deletion is off until the deployment owner runs gc-host-jobs --activate
//     for this state directory, having confirmed that every node sharing it
//     runs a tombstone-aware relayd; nothing here can prove that by itself;
//   - each tombstone-aware daemon records itself durably in
//     host-jobs-tombstones/servers/<node>.json before it accepts clients, and
//     stamps every job record it creates with hostJobLedgerTombstones;
//   - every live relayd on this node's sockets, the legacy one included,
//     must advertise HostJobTombstonesCapability and match a registration by
//     node, pid and process start;
//   - an unstamped record created after activation, however old, is evidence
//     of an unaware daemon: it is persisted in legacy-evidence.json and blocks
//     deletion until --deactivate and a fresh --activate.
const (
	HostJobTombstonesCapability = "host_job_tombstones_v1"
	hostJobLedgerTombstones     = 2
	hostJobServerProtocol       = 1
)

type hostJobServerMarker struct {
	Node         string `json:"node"`
	PID          int    `json:"pid"`
	ProcessStart string `json:"process_start"`
	Version      string `json:"version"`
	Protocol     int    `json:"protocol"`
	StateDir     string `json:"state_dir"`
	FirstSeen    string `json:"first_seen"`
	StartedAt    string `json:"started_at"`
	RefreshedAt  string `json:"refreshed_at"`
}

func hostJobServerDir(stateDir string) string {
	return filepath.Join(hostJobTombstoneDir(stateDir), "servers")
}

func hostJobServerNode() string {
	node, err := os.Hostname()
	if err != nil || node == "" {
		return "unknown"
	}
	return strings.Map(func(r rune) rune {
		if r == '/' || r == 0 {
			return '_'
		}
		return r
	}, node)
}

// registerHostJobServer writes or refreshes this daemon's marker. The first
// registration time of the node is kept across restarts.
func (s *Server) registerHostJobServer(now time.Time) error {
	start, err := processStartIdentity(os.Getpid())
	if err != nil {
		return err
	}
	node := hostJobServerNode()
	path := filepath.Join(hostJobServerDir(s.stateDir), node+".json")
	marker := hostJobServerMarker{Node: node, PID: os.Getpid(), ProcessStart: start, Version: s.buildVersion,
		Protocol: hostJobServerProtocol, StateDir: s.stateDir, FirstSeen: now.UTC().Format(time.RFC3339Nano),
		StartedAt: now.UTC().Format(time.RFC3339Nano), RefreshedAt: now.UTC().Format(time.RFC3339Nano)}
	if raw, err := os.ReadFile(path); err == nil {
		var previous hostJobServerMarker
		if json.Unmarshal(raw, &previous) == nil && previous.FirstSeen != "" {
			marker.FirstSeen = previous.FirstSeen
			if previous.PID == marker.PID && previous.ProcessStart == start {
				marker.StartedAt = previous.StartedAt
			}
		}
	}
	raw, err := json.Marshal(marker)
	if err != nil {
		return err
	}
	return durableWriteFile(path, raw)
}

func readHostJobServerMarkers(stateDir string) ([]hostJobServerMarker, error) {
	entries, err := os.ReadDir(hostJobServerDir(stateDir))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var markers []hostJobServerMarker
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(hostJobServerDir(stateDir), entry.Name()))
		if err != nil {
			return nil, err
		}
		var marker hostJobServerMarker
		if err := json.Unmarshal(raw, &marker); err != nil || marker.Protocol < hostJobServerProtocol {
			return nil, fmt.Errorf("unreadable tombstone server marker %s", entry.Name())
		}
		markers = append(markers, marker)
	}
	return markers, nil
}

// hostJobLedgerEpoch is the first registration of any tombstone-aware daemon.
func hostJobLedgerEpoch(markers []hostJobServerMarker) (time.Time, error) {
	var epoch time.Time
	for _, marker := range markers {
		seen, err := time.Parse(time.RFC3339Nano, marker.FirstSeen)
		if err != nil {
			return time.Time{}, fmt.Errorf("unreadable tombstone server marker for %s", marker.Node)
		}
		if epoch.IsZero() || seen.Before(epoch) {
			epoch = seen
		}
	}
	if epoch.IsZero() {
		return epoch, errors.New("no tombstone-aware relayd has registered for this state directory; nothing was deleted")
	}
	return epoch, nil
}

// verifyLiveHostJobServers is the gc-host-jobs handshake: each live daemon
// probed on this node must hold a current marker for this state directory.
func verifyLiveHostJobServers(markers []hostJobServerMarker, livePIDs []int) error {
	if len(livePIDs) == 0 {
		return errors.New("no running tombstone-aware relayd on this node; start relayd or use --dry-run")
	}
	node := hostJobServerNode()
	for _, pid := range livePIDs {
		start, err := processStartIdentity(pid)
		if err != nil {
			return fmt.Errorf("cannot verify relayd pid %d: %w", pid, err)
		}
		matched := false
		for _, marker := range markers {
			matched = matched || marker.Node == node && marker.PID == pid && marker.ProcessStart == start
		}
		if !matched {
			return fmt.Errorf("relayd pid %d has not registered tombstone support for this state directory; nothing was deleted", pid)
		}
	}
	return nil
}

// unawareHostJobRecord reports a record that a tombstone-unaware daemon
// created after the baseline. There is no age limit: a daemon seen creating
// one may still be running, however long ago its last record was made.
func unawareHostJobRecord(record hostJobRecord, baseline time.Time) bool {
	if record.Ledger >= hostJobLedgerTombstones {
		return false
	}
	created, err := time.Parse(time.RFC3339Nano, record.CreatedAt)
	return err == nil && created.After(baseline)
}

// liveUnawareHostJobs scans the live ledger for records an unaware daemon
// created after the baseline.
func liveUnawareHostJobs(stateDir string, baseline time.Time) ([]hostJobRecord, error) {
	root := filepath.Join(stateDir, "host-jobs")
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var unaware []hostJobRecord
	for _, entry := range entries {
		if !entry.IsDir() || !validSessionID.MatchString(entry.Name()) {
			continue
		}
		record, err := readArchivedHostJobRecord(filepath.Join(root, entry.Name()), entry.Name())
		if err == nil && unawareHostJobRecord(record, baseline) {
			unaware = append(unaware, record)
		}
	}
	return unaware, nil
}

// hostJobDeletionGuard is the one gate every delete path passes, the hourly
// pass and gc-host-jobs alike. It requires an activation, no standing legacy
// evidence, a registration, and a registration for each live relayd on this
// node. It returns the baseline after which an unstamped record is evidence
// of an unaware daemon: the later of the first registration and activation.
func hostJobDeletionGuard(stateDir string, livePIDs []int) (time.Time, error) {
	activation, err := readHostJobActivation(stateDir)
	if err != nil {
		return time.Time{}, err
	}
	if evidence, found, err := readHostJobLegacyEvidence(stateDir); found {
		if err != nil {
			return time.Time{}, err
		}
		return time.Time{}, legacyEvidenceError(evidence)
	}
	markers, err := readHostJobServerMarkers(stateDir)
	if err != nil {
		return time.Time{}, err
	}
	epoch, err := hostJobLedgerEpoch(markers)
	if err != nil {
		return time.Time{}, err
	}
	if err := verifyLiveHostJobServers(markers, livePIDs); err != nil {
		return time.Time{}, err
	}
	activated, _ := time.Parse(time.RFC3339Nano, activation.ActivatedAt)
	if activated.After(epoch) {
		return activated, nil
	}
	return epoch, nil
}

// Deleting is off until the deployment owner activates it for this state
// directory, after confirming that every node sharing it runs a
// tombstone-aware relayd: `relayd gc-host-jobs --activate`. Registrations
// and the evidence scan cannot prove that a silent daemon on another node
// was upgraded; activation is that explicit precondition. Without it the
// hourly pass still archives, which deletes nothing.
const (
	hostJobActivationFile     = "activation.json"
	hostJobLegacyEvidenceFile = "legacy-evidence.json"
)

var errHostJobCleanupInactive = errors.New("cleanup inactive: archive deletion has not been activated for this state directory (relayd gc-host-jobs --activate)")

type hostJobActivation struct {
	ActivatedBy string `json:"activated_by"`
	UID         int    `json:"uid"`
	Node        string `json:"node"`
	ActivatedAt string `json:"activated_at"`
	Version     string `json:"version"`
	StateDir    string `json:"state_dir"`
}

type hostJobLegacyEvidence struct {
	Records []hostJobLegacyRecord `json:"records"`
}

type hostJobLegacyRecord struct {
	JobID     string `json:"job_id"`
	CreatedAt string `json:"created_at"`
	FoundAt   string `json:"found_at"`
}

// readOwnerOnlyFile reads a small regular file owned by this user that no
// one else can read or write.
func readOwnerOnlyFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 65536 {
		return nil, errors.New("not a small regular file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("mode %v is readable or writable by others", info.Mode().Perm())
	}
	if owner, ok := fileOwner(info); ok && owner != os.Getuid() {
		return nil, errors.New("not owned by this user")
	}
	return os.ReadFile(path)
}

func readHostJobActivation(stateDir string) (hostJobActivation, error) {
	var activation hostJobActivation
	path := filepath.Join(hostJobTombstoneDir(stateDir), hostJobActivationFile)
	raw, err := readOwnerOnlyFile(path)
	if os.IsNotExist(err) {
		return activation, errHostJobCleanupInactive
	}
	if err != nil {
		return activation, fmt.Errorf("activation marker %s rejected: %w; nothing was deleted", path, err)
	}
	if err := json.Unmarshal(raw, &activation); err != nil {
		return activation, fmt.Errorf("activation marker %s is unreadable; nothing was deleted", path)
	}
	if _, err := time.Parse(time.RFC3339Nano, activation.ActivatedAt); err != nil {
		return activation, fmt.Errorf("activation marker %s has no valid time; nothing was deleted", path)
	}
	return activation, nil
}

// readHostJobLegacyEvidence returns the sticky block, if any. An evidence
// file that exists but cannot be read still blocks.
func readHostJobLegacyEvidence(stateDir string) (hostJobLegacyEvidence, bool, error) {
	var evidence hostJobLegacyEvidence
	path := filepath.Join(hostJobTombstoneDir(stateDir), hostJobLegacyEvidenceFile)
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return evidence, false, nil
	}
	if err != nil || json.Unmarshal(raw, &evidence) != nil {
		return evidence, true, fmt.Errorf("legacy evidence %s is unreadable; cleanup stays blocked", path)
	}
	return evidence, true, nil
}

func legacyEvidenceError(evidence hostJobLegacyEvidence) error {
	ids := make([]string, 0, len(evidence.Records))
	for _, record := range evidence.Records {
		ids = append(ids, record.JobID)
	}
	return fmt.Errorf("cleanup blocked: a relayd without tombstone support created %s after registration; "+
		"upgrade every node, then gc-host-jobs --deactivate and --activate", strings.Join(ids, ", "))
}

// recordHostJobLegacyEvidence persists the block before the run refuses.
func recordHostJobLegacyEvidence(stateDir string, records []hostJobRecord, now time.Time) error {
	evidence, _, _ := readHostJobLegacyEvidence(stateDir)
	for _, record := range records {
		evidence.Records = append(evidence.Records, hostJobLegacyRecord{JobID: record.JobID, CreatedAt: record.CreatedAt,
			FoundAt: now.UTC().Format(time.RFC3339Nano)})
	}
	raw, err := json.Marshal(evidence)
	if err != nil {
		return err
	}
	return durableWriteFile(filepath.Join(hostJobTombstoneDir(stateDir), hostJobLegacyEvidenceFile), raw)
}

// ActivateHostJobCleanup records the deployment owner's activation. It is
// refused while legacy evidence stands (deactivate first) or when a live
// relayd on this node lacks tombstone support. The caller probes the sockets.
func ActivateHostJobCleanup(stateDir, version string, livePIDs []int, now time.Time) (hostJobActivation, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	var activation hostJobActivation
	unlock, err := lockHostJobLedger(stateDir, hostJobLedgerWait)
	if err != nil {
		return activation, err
	}
	defer unlock()
	if evidence, found, err := readHostJobLegacyEvidence(stateDir); found {
		if err != nil {
			return activation, err
		}
		return activation, fmt.Errorf("%v; run gc-host-jobs --deactivate first", legacyEvidenceError(evidence))
	}
	markers, err := readHostJobServerMarkers(stateDir)
	if err != nil {
		return activation, err
	}
	if err := verifyLiveHostJobServers(markers, livePIDs); err != nil {
		return activation, err
	}
	who := "unknown"
	if current, err := user.Current(); err == nil {
		who = current.Username
	}
	activation = hostJobActivation{ActivatedBy: who, UID: os.Getuid(), Node: hostJobServerNode(),
		ActivatedAt: now.UTC().Format(time.RFC3339Nano), Version: version, StateDir: stateDir}
	raw, err := json.Marshal(activation)
	if err != nil {
		return activation, err
	}
	return activation, durableWriteFile(filepath.Join(hostJobTombstoneDir(stateDir), hostJobActivationFile), raw)
}

// DeactivateHostJobCleanup turns deletion off and clears legacy evidence;
// a fresh activation starts a new baseline.
func DeactivateHostJobCleanup(stateDir string) error {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	unlock, err := lockHostJobLedger(stateDir, hostJobLedgerWait)
	if err != nil {
		return err
	}
	defer unlock()
	directory := hostJobTombstoneDir(stateDir)
	// Activation goes first: a crash between the two leaves deletion off.
	for _, name := range []string{hostJobActivationFile, hostJobLegacyEvidenceFile} {
		if err := os.Remove(filepath.Join(directory, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
		if err := syncDirectory(directory); err != nil {
			return err
		}
	}
	return nil
}

// ProbeHostJobTombstoneServers probes each relayd socket on this node and
// returns the pids of the live ones. A live relayd without tombstone support,
// or one that answers but cannot be verified, is an error. A socket nobody
// listens on is not a live relayd.
func ProbeHostJobTombstoneServers(sockets []string) ([]int, error) {
	var pids []int
	seen := map[string]bool{}
	for _, socket := range sockets {
		if socket == "" || seen[socket] {
			continue
		}
		seen[socket] = true
		if _, err := os.Lstat(socket); os.IsNotExist(err) {
			continue
		}
		connection, err := net.DialTimeout("unix", socket, 500*time.Millisecond)
		if err != nil {
			if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, os.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("relayd at %s could not be verified: %v", socket, err)
		}
		pid, err := probeHostJobTombstoneServer(connection)
		connection.Close()
		if err != nil {
			return nil, fmt.Errorf("relayd at %s: %v", socket, err)
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

func probeHostJobTombstoneServer(connection net.Conn) (int, error) {
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	if err := RequirePeerUID(connection, os.Getuid()); err != nil {
		return 0, err
	}
	_, peerPID, err := PeerCredentials(connection)
	if err != nil {
		return 0, err
	}
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, SessionID: "_probe", Probe: true})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return 0, err
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return 0, errors.New("could not be verified: invalid probe response")
	}
	var status protocol.StatusPayload
	if err := protocol.DecodeJSON(frame, &status); err != nil || status.State != "ready" {
		return 0, errors.New("could not be verified: not ready")
	}
	if !slices.Contains(status.Capabilities, HostJobTombstonesCapability) {
		return 0, fmt.Errorf("relayd %s does not support job tombstones", status.Version)
	}
	pid := peerPID
	if pid <= 0 {
		pid = status.SupervisorPID
	}
	if pid <= 0 || status.SupervisorPID > 0 && status.SupervisorPID != pid {
		return 0, errors.New("could not be verified: pid mismatch")
	}
	return pid, nil
}
