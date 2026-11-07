package daemon

import (
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
	"runtime"
	"strings"
	"syscall"
	"time"
)

var errNotNativeClaudeFrontend = errors.New("no unique original Claude frontend")
var nativeClaudeSessionID = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)

type nativeClaudeRegistration struct {
	PID          int    `json:"pid"`
	SessionID    string `json:"sessionId"`
	ProcessStart string `json:"procStart"`
	Socket       string `json:"messagingSocketPath"`
	PeerProtocol int    `json:"peerProtocol"`
	Kind         string `json:"kind"`
	Entrypoint   string `json:"entrypoint"`
	PIDDomain    string `json:"pidDomain"`
	RelayProxy   bool   `json:"relayProxy"`
	ParkedJobID  string `json:"parkedJobId,omitempty"`
	JobID        string `json:"jobId,omitempty"`
}

// The provider's public registration contains routing metadata, not keys.
// Match the existing native peer reader: owner and integrity are mandatory;
// readable SDK metadata does not become a control credential.
// Linux SDK registrations use the machine ID and PID namespace (not boot ID).
// Retained worker boot and native process incarnation are verified separately.
func nativeClaudePIDDomain() string {
	if runtime.GOOS != "linux" {
		return runtime.GOOS
	}
	machine, err := os.ReadFile("/etc/machine-id")
	if err != nil {
		return ""
	}
	namespace, err := os.Readlink("/proc/self/ns/pid")
	if err != nil {
		return ""
	}
	return nativeClaudeLinuxPIDDomain(string(machine), namespace)
}

var nativeClaudeMachineID = regexp.MustCompile(`^[a-fA-F0-9]{32}$`)
var nativeClaudePIDNamespace = regexp.MustCompile(`^pid:\[[0-9]+\]$`)

func nativeClaudeLinuxPIDDomain(machine, namespace string) string {
	machine = strings.TrimSpace(machine)
	if !nativeClaudeMachineID.MatchString(machine) || !nativeClaudePIDNamespace.MatchString(namespace) {
		return ""
	}
	return "linux:" + machine + ":" + namespace
}

func nativeClaudeMetadataObject(path string, directory bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0022 != 0 ||
		(directory && !info.IsDir()) || (!directory && !info.Mode().IsRegular()) {
		return errors.New("native Claude metadata owner or integrity mismatch")
	}
	return nil
}

func readNativeClaudeRegistration(path string, pid int, identity string) (nativeClaudeRegistration, []byte, os.FileInfo, error) {
	return readNativeClaudeRegistrationKind(path, pid, identity, "interactive")
}

func readNativeClaudeRegistrationKind(path string, pid int, identity, kind string) (nativeClaudeRegistration, []byte, os.FileInfo, error) {
	return readNativeClaudeRegistrationEntry(path, pid, identity, kind, "cli")
}

// readNativeClaudeRegistrationEntry reads a registration published by the
// given entrypoint: "cli" for terminal sessions, "claude-desktop" for the
// Claude desktop app's background sessions.
func readNativeClaudeRegistrationEntry(path string, pid int, identity, kind, entrypoint string) (nativeClaudeRegistration, []byte, os.FileInfo, error) {
	var empty nativeClaudeRegistration
	for _, item := range []struct {
		path      string
		directory bool
	}{{filepath.Dir(path), true}, {path, false}} {
		if err := nativeClaudeMetadataObject(item.path, item.directory); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return empty, nil, nil, errors.New("native Claude registration metadata not found")
			}
			if errors.Is(err, os.ErrPermission) {
				return empty, nil, nil, errors.New("native Claude registration metadata unreadable")
			}
			return empty, nil, nil, errors.New("native Claude registration owner or integrity mismatch")
		}
	}
	file, err := os.OpenFile(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return empty, nil, nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(opened, current) {
		return empty, nil, nil, errors.New("native Claude registration changed")
	}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	var record nativeClaudeRegistration
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &record) != nil {
		return empty, nil, nil, errors.New("invalid native Claude registration")
	}
	if record.PID != pid || record.ProcessStart != identity || !nativeClaudeSessionID.MatchString(record.SessionID) ||
		record.PeerProtocol != 1 || record.Kind != kind || record.Entrypoint != entrypoint || (nativeClaudePIDDomain() == "" || record.PIDDomain != nativeClaudePIDDomain()) || record.RelayProxy ||
		!filepath.IsAbs(record.Socket) || len(record.Socket) > 4096 || strings.ContainsRune(record.Socket, 0) {
		return empty, nil, nil, errors.New("native Claude registration does not identify this frontend")
	}
	return record, data, opened, nil
}

func nativeClaudeSocketIdentity(path string) (os.FileInfo, error) {
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	p, pok := parent.Sys().(*syscall.Stat_t)
	s, sok := info.Sys().(*syscall.Stat_t)
	if !pok || !sok || !parent.IsDir() || parent.Mode().Perm()&0022 != 0 || int(p.Uid) != os.Getuid() ||
		info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0022 != 0 || int(s.Uid) != os.Getuid() {
		return nil, errors.New("native Claude socket is not privately owned")
	}
	return info, nil
}

// An optional transcript is read from the same private provider namespace:
// config is the frontend's own Claude account directory. A missing initial
// transcript stays empty; this observation grants no input.
func nativeClaudeTranscript(config, session string) (string, error) {
	directory, err := os.Open(filepath.Join(config, "projects"))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(513)
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	if len(entries) > 512 {
		return "", errors.New("native Claude transcript catalog exceeds bound")
	}
	found := ""
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(config, "projects", entry.Name(), session+".jsonl")
		_, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || validateClaudeConfigTranscript(path, config) != nil {
			return "", errors.New("native Claude transcript unavailable")
		}
		if found != "" {
			return "", errors.New("native Claude transcript is ambiguous")
		}
		found = path
	}
	return found, nil
}

// ReadNativeClaudeBinding observes a private native registration and proves
// the socket's kernel owner, without writing protocol bytes or binding files.
// It is an association observation, not a prompt lease or control capability.
func ReadNativeClaudeBinding(pane string) (AgentBindingRecord, error) {
	return readNativeClaudeBinding(pane, "")
}

// ReadNativeClaudePaneJobBinding binds one named background job of the pane's
// Claude frontend: an explicit message target, never the pane default.
func ReadNativeClaudePaneJobBinding(pane, session string) (AgentBindingRecord, error) {
	if !nativeClaudeSessionID.MatchString(session) {
		return AgentBindingRecord{}, errors.New("invalid target session")
	}
	return readNativeClaudeBinding(pane, session)
}

func readNativeClaudeBinding(pane, target string) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	if !validSessionID.MatchString(pane) {
		return empty, errors.New("invalid pane")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return empty, errors.New("native worker unavailable")
	}
	provider, pid := nativeBindingFrontend(manifest.ShellPID)
	if provider != "claude" || pid <= 1 {
		return empty, errNotNativeClaudeFrontend
	}
	start, err := NativeAgentIncarnation(pane, pid, "claude")
	if err != nil {
		return empty, err
	}
	identity, err := processStartIdentity(pid)
	if err != nil {
		return empty, err
	}
	// Claude publishes its session registry in its own account directory: the
	// exact process's, never a fallback when its environment is unreadable.
	config, err := nativeClaudeAccountRoot(pid)
	if err != nil {
		return empty, err
	}
	path := filepath.Join(config, "sessions", fmt.Sprintf("%d.json", pid))
	registration, data, file, err := readNativeClaudeRegistration(path, pid, identity)
	if err != nil {
		return empty, err
	}
	if target != "" {
		return readNativeClaudeTargetJobBinding(pane, pid, start, identity, path, registration, data, file, target)
	}
	if registration.ParkedJobID != "" {
		return readNativeClaudeParkedBinding(pane, pid, start, identity, path, registration, data, file)
	}
	socketBefore, err := nativeClaudeSocketIdentity(registration.Socket)
	if err != nil {
		return empty, err
	}
	connection, err := net.DialTimeout("unix", registration.Socket, 3*time.Second)
	if err != nil {
		return empty, err
	}
	uid, owner, peerErr := PeerCredentials(connection)
	_ = connection.Close()
	if peerErr != nil || uid != os.Getuid() || owner != pid {
		return empty, errors.New("native Claude socket kernel owner mismatch")
	}
	transcript, err := nativeClaudeTranscript(config, registration.SessionID)
	if err != nil {
		return empty, err
	}
	after, afterData, afterFile, err := readNativeClaudeRegistration(path, pid, identity)
	socketAfter, socketErr := nativeClaudeSocketIdentity(registration.Socket)
	if err != nil || socketErr != nil || registration != after || !bytes.Equal(data, afterData) || !os.SameFile(file, afterFile) || !os.SameFile(socketBefore, socketAfter) {
		return empty, errors.New("native Claude publication changed during observation")
	}
	providerAfter, pidAfter := nativeBindingFrontend(manifest.ShellPID)
	current, err := NativeAgentIncarnation(pane, pid, "claude")
	latest, loadErr := loadManifest(server.manifestPath(pane))
	if err != nil || current != start || providerAfter != "claude" || pidAfter != pid || loadErr != nil ||
		latest.WorkerPID != manifest.WorkerPID || latest.WorkerStartTime != manifest.WorkerStartTime || latest.ShellPID != manifest.ShellPID || latest.NodeBootID != manifest.NodeBootID || validateWorkerIdentity(latest) != nil {
		return empty, errors.New("native Claude frontend changed during observation")
	}
	finalTranscript, err := nativeClaudeTranscript(config, registration.SessionID)
	if err != nil || finalTranscript != transcript {
		return empty, errors.New("native Claude transcript association changed")
	}
	socketStat := socketBefore.Sys().(*syscall.Stat_t)
	revisionData, _ := json.Marshal(struct {
		Pane          string
		PID           int
		Start         uint64
		Registration  nativeClaudeRegistration
		Device, Inode uint64
		Transcript    string
	}{pane, pid, start, registration, uint64(socketStat.Dev), uint64(socketStat.Ino), transcript})
	sum := sha256.Sum256(revisionData)
	override, err := claudeRecordOverride(pid, config)
	if err != nil {
		return empty, err
	}
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "claude", ProcessID: pid, ProcessStart: start, ConfigDir: override}, SessionID: registration.SessionID, TranscriptPath: transcript, ObservedAt: time.Now().UTC(), Lifecycle: "unknown", Revision: hex.EncodeToString(sum[:]), Source: "native_registration_kernel_owner"}, nil
}

// nativeClaudeAccountRoot is the account directory of one exact Claude process:
// its own CLAUDE_CONFIG_DIR, or ~/.claude only when that is unset. An unreadable
// environment, an invalid directory or a process that is gone is an error.
// No other account is ever tried.
func nativeClaudeAccountRoot(pid int) (string, error) {
	return agentConfigRoot(pid, "claude")
}
