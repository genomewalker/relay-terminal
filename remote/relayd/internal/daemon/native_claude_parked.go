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
	"strconv"
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

func nativeClaudePublications(home, kind, job string) ([]nativeClaudePublication, error) {
	registry := filepath.Join(home, ".claude", "sessions")
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
		if err != nil || (kind == "bg" && record.JobID != job) ||
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

func nativeClaudeContinuesTo(home, source, target string) error {
	seen := map[string]bool{}
	for hop := 0; hop < 8; hop++ {
		if source == target {
			return nil
		}
		if seen[source] {
			break
		}
		seen[source] = true
		path, err := nativeClaudeTranscript(home, source)
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
	home, err := os.UserHomeDir()
	if err != nil {
		return result, err
	}
	backgrounds, err := nativeClaudePublications(home, "bg", front.ParkedJobID)
	if err != nil || len(backgrounds) != 1 {
		return result, errors.New("no unique live background job publication")
	}
	background := backgrounds[0]
	if err := nativeClaudeParkedPair(front, background.record); err != nil {
		return result, err
	}
	fronts, err := nativeClaudePublications(home, "interactive", front.ParkedJobID)
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
	if err := nativeClaudeContinuesTo(home, front.SessionID, background.record.SessionID); err != nil {
		return result, err
	}
	transcript, err := nativeClaudeTranscript(home, background.record.SessionID)
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
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "claude",
		ProcessID: pid, ProcessStart: start}, SessionID: background.record.SessionID,
		TranscriptPath: transcript, ObservedAt: time.Now().UTC(), Lifecycle: "unknown",
		Revision: hex.EncodeToString(sum[:]), Source: "native_parked_job_kernel_owner", NativePeer: peer}, nil
}
