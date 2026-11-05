package daemon

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var errNativeClaudeParkedUnavailable = errors.New("native Claude parked conversation unavailable")
var nativeClaudeJobID = regexp.MustCompile(`^[a-fA-F0-9]{8}$`)

// The foreground CLI remains the pane's producer. A parked native job owns its
// current model conversation and inbox independently of the daemon's ancestry.
type NativeClaudePeer struct {
	PID             int    `json:"pid"`
	ProcessStart    string `json:"process_start"`
	Socket          string `json:"socket"`
	SocketIdentity  string `json:"socket_identity"`
	JobID           string `json:"job_id"`
	FrontendSession string `json:"frontend_session"`
}

type nativeClaudePublication struct {
	record nativeClaudeRegistration
	data   []byte
	file   os.FileInfo
	path   string
}

func nativeClaudeParkedPair(front, background nativeClaudeRegistration) error {
	if front.Kind != "interactive" || background.Kind != "bg" ||
		front.Entrypoint != "cli" || background.Entrypoint != "cli" ||
		front.RelayProxy || background.RelayProxy ||
		!nativeClaudeJobID.MatchString(front.ParkedJobID) || front.ParkedJobID != background.JobID ||
		!nativeClaudeSessionID.MatchString(front.SessionID) || !nativeClaudeSessionID.MatchString(background.SessionID) ||
		front.PID <= 1 || background.PID <= 1 || front.PID == background.PID ||
		front.PIDDomain == "" || front.PIDDomain != background.PIDDomain {
		return errors.New("native parked job publications do not match")
	}
	return nil
}

// An empty job lists every live background publication.
func nativeClaudePublications(config, kind, job string) ([]nativeClaudePublication, error) {
	registry := filepath.Join(config, "sessions")
	paths, err := filepath.Glob(filepath.Join(registry, "*.json"))
	if err != nil || len(paths) > 1024 || nativeClaudeMetadataObject(registry, true) != nil {
		return nil, errors.New("native session registry unavailable or exceeds limit")
	}
	result := []nativeClaudePublication{}
	for _, path := range paths {
		pid, err := strconv.Atoi(filepath.Base(path[:len(path)-len(".json")]))
		if err != nil || pid <= 1 {
			continue
		}
		start, err := processStartIdentity(pid)
		if err != nil {
			continue
		}
		record, data, file, err := readNativeClaudeRegistrationKind(path, pid, start, kind)
		if err != nil || (kind == "bg" && job != "" && record.JobID != job) ||
			(kind == "interactive" && record.ParkedJobID != job) {
			continue
		}
		result = append(result, nativeClaudePublication{record, data, file, path})
	}
	return result, nil
}

func nativeClaudePeerOwner(record nativeClaudeRegistration) (os.FileInfo, error) {
	before, err := nativeClaudeSocketIdentity(record.Socket)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("unix", record.Socket, 3*time.Second)
	if err != nil {
		return nil, err
	}
	uid, pid, err := PeerCredentials(conn)
	_ = conn.Close()
	start, startErr := processStartIdentity(record.PID)
	after, socketErr := nativeClaudeSocketIdentity(record.Socket)
	if err != nil || uid != os.Getuid() || pid != record.PID || startErr != nil ||
		start != record.ProcessStart || socketErr != nil || !os.SameFile(before, after) {
		return nil, errors.New("native parked inbox kernel owner changed")
	}
	return after, nil
}

func nativeClaudeNextSession(path, session string) (string, error) {
	if nativeClaudeMetadataObject(path, false) != nil {
		return "", errors.New("native continuation transcript is unsafe")
	}
	f, err := os.OpenFile(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", err
	}
	defer f.Close()
	opened, err := f.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(opened, current) || opened.Size() > 64<<20 {
		return "", errors.New("native continuation transcript changed or exceeds limit")
	}
	scan := bufio.NewScanner(io.LimitReader(f, (64<<20)+1))
	scan.Buffer(make([]byte, 65536), 16<<20)
	next := ""
	for scan.Scan() {
		var row struct {
			Type    string `json:"type"`
			Session string `json:"sessionId"`
			Next    string `json:"continuedInSessionId"`
		}
		if json.Unmarshal(scan.Bytes(), &row) == nil && row.Type == "continued-in" && row.Session == session {
			if !nativeClaudeSessionID.MatchString(row.Next) || row.Next == session || (next != "" && next != row.Next) {
				return "", errors.New("native continuation is invalid or ambiguous")
			}
			next = row.Next
		}
	}
	if err := scan.Err(); err != nil {
		return "", err
	}
	return next, nil
}

func nativeClaudeContinuesTo(config, source, target string) error {
	seen := map[string]bool{}
	for hop := 0; hop < 8; hop++ {
		if source == target {
			return nil
		}
		if seen[source] {
			break
		}
		seen[source] = true
		path, err := nativeClaudeTranscript(config, source)
		if err != nil || path == "" {
			break
		}
		source, err = nativeClaudeNextSession(path, source)
		if err != nil || source == "" {
			break
		}
	}
	return errors.New("parked job lacks an explicit native conversation continuation")
}

// Claude's job markers: working and blocked jobs are live; these have ended.
// A missing or unknown state is never treated as ended.
var nativeClaudeFinishedJobStates = map[string]bool{"done": true, "failed": true, "stopped": true,
	"killed": true, "cancelled": true, "completed": true}

// The pane a background job was started from. Only RELAY_SESSION is kept.
var nativeClaudeJobPane = func(pid int) string { return processEnvironmentValue(pid, "RELAY_SESSION") }

type nativeClaudePaneJob struct {
	publication nativeClaudePublication
	JobID       string
	SessionID   string
	State       string
}

func (job nativeClaudePaneJob) finished() bool { return nativeClaudeFinishedJobStates[job.State] }

// readNativeClaudeJobState reads only the state marker of a job's private
// state.json; every other field, including any credential, is ignored.
func readNativeClaudeJobState(config, job string) (string, error) {
	if !nativeClaudeJobID.MatchString(job) {
		return "", errors.New("invalid native job identifier")
	}
	path := filepath.Join(config, "jobs", job, "state.json")
	if nativeClaudeMetadataObject(filepath.Dir(path), true) != nil || nativeClaudeMetadataObject(path, false) != nil {
		return "", errors.New("native job state owner or integrity mismatch")
	}
	f, err := os.OpenFile(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", err
	}
	defer f.Close()
	opened, err := f.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(opened, current) || opened.Size() > 1<<20 {
		return "", errors.New("native job state changed or exceeds limit")
	}
	var marker struct {
		State string `json:"state"`
	}
	if err := json.NewDecoder(io.LimitReader(f, 1<<20)).Decode(&marker); err != nil {
		return "", err
	}
	if len(marker.State) > 32 {
		return "", errors.New("invalid native job state")
	}
	return marker.State, nil
}

// nativeClaudePaneJobs lists the live background jobs started from this pane,
// with their state. An unreadable state stays unknown, which counts as live.
func nativeClaudePaneJobs(config, pane string) ([]nativeClaudePaneJob, error) {
	publications, err := nativeClaudePublications(config, "bg", "")
	if err != nil {
		return nil, err
	}
	jobs := []nativeClaudePaneJob{}
	for _, publication := range publications {
		record := publication.record
		if !nativeClaudeJobID.MatchString(record.JobID) || nativeClaudeJobPane(record.PID) != pane {
			continue
		}
		state, _ := readNativeClaudeJobState(config, record.JobID)
		jobs = append(jobs, nativeClaudePaneJob{publication, record.JobID, record.SessionID, state})
	}
	return jobs, nil
}

// nativeClaudeParkedChoice keeps the frontend's parked job as the pane binding
// unless it has ended while another of the pane's jobs is live. That pane is
// ambiguous and refuses: it never switches to the other job by itself, since
// only the parked job carries the frontend's continuation proof.
func nativeClaudeParkedChoice(parked, parkedState string, jobs []nativeClaudePaneJob) error {
	live := []string{}
	for _, job := range jobs {
		if job.JobID != parked && !job.finished() {
			live = append(live, job.JobID)
		}
	}
	if !nativeClaudeFinishedJobStates[parkedState] || len(live) == 0 {
		return nil
	}
	sort.Strings(live)
	return fmt.Errorf("parked job %s is %s while this pane's job(s) %s are live; address one by target session",
		parked, parkedState, strings.Join(live, ", "))
}

// nativeClaudeTargetChoice selects the one live pane job running session.
func nativeClaudeTargetChoice(session string, jobs []nativeClaudePaneJob) (nativeClaudePaneJob, error) {
	matches := []nativeClaudePaneJob{}
	for _, job := range jobs {
		if job.SessionID == session {
			matches = append(matches, job)
		}
	}
	if len(matches) != 1 {
		return nativeClaudePaneJob{}, errors.New("target session is not exactly one live background job of this pane")
	}
	if matches[0].finished() {
		return nativeClaudePaneJob{}, fmt.Errorf("target job %s is %s", matches[0].JobID, matches[0].State)
	}
	return matches[0], nil
}

func readNativeClaudeParkedBinding(pane string, pid int, start uint64, identity, path string,
	front nativeClaudeRegistration, frontData []byte, frontFile os.FileInfo) (result AgentBindingRecord, resultErr error) {
	defer func() {
		if resultErr != nil {
			resultErr = fmt.Errorf("%w: %v", errNativeClaudeParkedUnavailable, resultErr)
		}
	}()
	if !nativeClaudeJobID.MatchString(front.ParkedJobID) {
		return result, errors.New("invalid native parked job identifier")
	}
	// The front's publication lies in its account's sessions directory; the
	// background job and its transcripts share that account directory.
	config := filepath.Dir(filepath.Dir(path))
	paneJobs, err := nativeClaudePaneJobs(config, pane)
	if err != nil {
		return result, err
	}
	parkedState, _ := readNativeClaudeJobState(config, front.ParkedJobID)
	if err := nativeClaudeParkedChoice(front.ParkedJobID, parkedState, paneJobs); err != nil {
		return result, err
	}
	backgrounds, err := nativeClaudePublications(config, "bg", front.ParkedJobID)
	if err != nil || len(backgrounds) != 1 {
		return result, errors.New("no unique live background job publication")
	}
	background := backgrounds[0]
	if err := nativeClaudeParkedPair(front, background.record); err != nil {
		return result, err
	}
	fronts, err := nativeClaudePublications(config, "interactive", front.ParkedJobID)
	if err != nil || len(fronts) != 1 || fronts[0].record.PID != pid {
		return result, errors.New("parked job has no unique live foreground publication")
	}
	frontSocket, err := nativeClaudePeerOwner(front)
	if err != nil {
		return result, err
	}
	backgroundSocket, err := nativeClaudePeerOwner(background.record)
	if err != nil {
		return result, err
	}
	if err := nativeClaudeContinuesTo(config, front.SessionID, background.record.SessionID); err != nil {
		return result, err
	}
	transcript, err := nativeClaudeTranscript(config, background.record.SessionID)
	if err != nil || transcript == "" {
		return result, errors.New("native background conversation transcript unavailable")
	}
	after, afterData, afterFile, err := readNativeClaudeRegistration(path, pid, identity)
	bgAfter, bgData, bgFile, bgErr := readNativeClaudeRegistrationKind(background.path,
		background.record.PID, background.record.ProcessStart, "bg")
	frontSocketAfter, frontSocketErr := nativeClaudeSocketIdentity(front.Socket)
	bgSocketAfter, bgSocketErr := nativeClaudeSocketIdentity(background.record.Socket)
	if err != nil || bgErr != nil || frontSocketErr != nil || bgSocketErr != nil ||
		after != front || bgAfter != background.record || !bytes.Equal(frontData, afterData) ||
		!bytes.Equal(background.data, bgData) || !os.SameFile(frontFile, afterFile) ||
		!os.SameFile(background.file, bgFile) || !os.SameFile(frontSocket, frontSocketAfter) ||
		!os.SameFile(backgroundSocket, bgSocketAfter) {
		return result, errors.New("native parked job publication changed during observation")
	}
	if _, err := NativeAgentIncarnation(pane, pid, "claude"); err != nil {
		return result, err
	}
	bgStat := backgroundSocket.Sys().(*syscall.Stat_t)
	peer := &NativeClaudePeer{PID: background.record.PID, ProcessStart: background.record.ProcessStart,
		Socket: background.record.Socket, SocketIdentity: fmt.Sprintf("%d:%d", bgStat.Dev, bgStat.Ino),
		JobID: front.ParkedJobID, FrontendSession: front.SessionID}
	revisionData, _ := json.Marshal(struct {
		Pane       string
		Frontend   nativeClaudeRegistration
		Background nativeClaudeRegistration
		Peer       NativeClaudePeer
		Transcript string
	}{pane, front, background.record, *peer, transcript})
	sum := sha256.Sum256(revisionData)
	override, err := claudeRecordOverride(pid, config)
	if err != nil {
		return result, err
	}
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "claude",
		ProcessID: pid, ProcessStart: start, ConfigDir: override}, SessionID: background.record.SessionID,
		TranscriptPath: transcript, ObservedAt: time.Now().UTC(), Lifecycle: "unknown",
		Revision: hex.EncodeToString(sum[:]), Source: "native_parked_job_kernel_owner", NativePeer: peer}, nil
}

// readNativeClaudeTargetJobBinding proves an explicitly addressed background
// job of this pane: the frontend's own registration, a background publication
// for exactly that session started from this pane (RELAY_SESSION), not ended
// per its state.json, with a kernel-owned inbox and a transcript, all stable
// across the observation. It does not require the frontend's continuation
// chain: the sender names the conversation instead of inferring it.
func readNativeClaudeTargetJobBinding(pane string, pid int, start uint64, identity, path string,
	front nativeClaudeRegistration, frontData []byte, frontFile os.FileInfo, session string) (result AgentBindingRecord, resultErr error) {
	config := filepath.Dir(filepath.Dir(path))
	jobs, err := nativeClaudePaneJobs(config, pane)
	if err != nil {
		return result, err
	}
	job, err := nativeClaudeTargetChoice(session, jobs)
	if err != nil {
		return result, err
	}
	background := job.publication
	if background.record.Entrypoint != "cli" || background.record.RelayProxy || background.record.PID == pid ||
		front.PIDDomain == "" || front.PIDDomain != background.record.PIDDomain {
		return result, errors.New("target background job publication does not match this frontend")
	}
	backgroundSocket, err := nativeClaudePeerOwner(background.record)
	if err != nil {
		return result, err
	}
	transcript, err := nativeClaudeTranscript(config, session)
	if err != nil || transcript == "" {
		return result, errors.New("target background conversation transcript unavailable")
	}
	after, afterData, afterFile, err := readNativeClaudeRegistration(path, pid, identity)
	bgAfter, bgData, bgFile, bgErr := readNativeClaudeRegistrationKind(background.path,
		background.record.PID, background.record.ProcessStart, "bg")
	bgSocketAfter, bgSocketErr := nativeClaudeSocketIdentity(background.record.Socket)
	stateAfter, _ := readNativeClaudeJobState(config, job.JobID)
	if err != nil || bgErr != nil || bgSocketErr != nil || after != front || bgAfter != background.record ||
		!bytes.Equal(frontData, afterData) || !bytes.Equal(background.data, bgData) || !os.SameFile(frontFile, afterFile) ||
		!os.SameFile(background.file, bgFile) || !os.SameFile(backgroundSocket, bgSocketAfter) ||
		nativeClaudeFinishedJobStates[stateAfter] || nativeClaudeJobPane(background.record.PID) != pane {
		return result, errors.New("target background job changed during observation")
	}
	if _, err := NativeAgentIncarnation(pane, pid, "claude"); err != nil {
		return result, err
	}
	bgStat := backgroundSocket.Sys().(*syscall.Stat_t)
	peer := &NativeClaudePeer{PID: background.record.PID, ProcessStart: background.record.ProcessStart,
		Socket: background.record.Socket, SocketIdentity: fmt.Sprintf("%d:%d", bgStat.Dev, bgStat.Ino),
		JobID: job.JobID, FrontendSession: front.SessionID}
	revisionData, _ := json.Marshal(struct {
		Pane       string
		Frontend   nativeClaudeRegistration
		Background nativeClaudeRegistration
		Peer       NativeClaudePeer
		Transcript string
	}{pane, front, background.record, *peer, transcript})
	sum := sha256.Sum256(revisionData)
	override, err := claudeRecordOverride(pid, config)
	if err != nil {
		return result, err
	}
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "claude",
		ProcessID: pid, ProcessStart: start, ConfigDir: override}, SessionID: session,
		TranscriptPath: transcript, ObservedAt: time.Now().UTC(), Lifecycle: "unknown",
		Revision: hex.EncodeToString(sum[:]), Source: "native_pane_job_kernel_owner", NativePeer: peer}, nil
}
