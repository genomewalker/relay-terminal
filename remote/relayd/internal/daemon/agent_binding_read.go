package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type AgentBindingRecord struct {
	Version        int                   `json:"version"`
	Producer       agentProducer         `json:"producer"`
	SessionID      string                `json:"session_id"`
	TranscriptPath string                `json:"transcript_path"`
	ObservedAt     time.Time             `json:"observed_at"`
	Lifecycle      string                `json:"lifecycle"`
	Revision       string                `json:"revision"`
	Source         string                `json:"source,omitempty"`
	NativeEndpoint *NativeCodexEndpoint  `json:"native_endpoint,omitempty"`
	StockProxy     *StockCodexProxyProof `json:"stock_proxy,omitempty"`
	NativePeer     *NativeClaudePeer     `json:"native_peer,omitempty"`
}

// RetainedClaudeSession preserves conversation association after its frontend
// leaves the pane. This is historical identity only, never an input capability.
// The caller must match it against the provider's current session listing.
func RetainedClaudeSession(pane string) (string, error) {
	if !validSessionID.MatchString(pane) {
		return "", errors.New("invalid pane")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return "", errors.New("retained conversation worker unavailable")
	}
	directory := filepath.Join(server.stateDir, "agent-bindings")
	path := filepath.Join(directory, pane+".json")
	if privateBindingObject(directory, true) != nil || privateBindingObject(path, false) != nil {
		return "", errors.New("retained conversation unavailable")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(opened, current) {
		return "", errors.New("retained conversation changed")
	}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	var record AgentBindingRecord
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &record) != nil ||
		record.Version != 1 || record.Producer.PaneID != pane || record.Producer.Provider != "claude" ||
		!validSessionID.MatchString(record.SessionID) || record.ObservedAt.IsZero() ||
		record.ObservedAt.After(time.Now().Add(time.Minute)) ||
		validateAccountTranscript(record.TranscriptPath, "claude", record.Producer.ConfigDir) != nil {
		return "", errors.New("invalid retained conversation")
	}
	return record.SessionID, nil
}

// NativeAgentIncarnation verifies an original CLI against its retained worker
// without requiring a telemetry record or changing any process.
func NativeAgentIncarnation(pane string, pid int, provider string) (uint64, error) {
	if !validSessionID.MatchString(pane) || pid <= 1 || (provider != "claude" && provider != "codex") {
		return 0, errors.New("invalid native agent identity")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return 0, errors.New("native agent worker unavailable")
	}
	before, err := processStartTime(pid)
	if err != nil || descendantAgentProcesses(manifest.ShellPID)[pid] != provider {
		return 0, errors.New("native agent left pane")
	}
	after, err := processStartTime(pid)
	if err != nil || after != before || validateWorkerIdentity(manifest) != nil {
		return 0, errors.New("native agent identity changed")
	}
	return before, nil
}

// ReadVerifiedAgentBinding never starts a supervisor or repairs stale records.
// Kernel process incarnation and current pane ancestry are checked on every read.
func bindingProducerIsOriginalFrontend(producer agentProducer, provider string, pid int) bool {
	return pid > 1 && producer.ProcessID == pid && producer.Provider == provider
}

func readStoredVerifiedAgentBinding(pane string) (AgentBindingRecord, error) {
	var record AgentBindingRecord
	if !validSessionID.MatchString(pane) {
		return record, errors.New("invalid pane")
	}
	server := NewServer()
	directory := filepath.Join(server.stateDir, "agent-bindings")
	if err := privateBindingObject(directory, true); err != nil {
		return record, err
	}
	path := filepath.Join(directory, pane+".json")
	if err := privateBindingObject(path, false); err != nil {
		return record, err
	}
	file, err := os.Open(path)
	if err != nil {
		return record, err
	}
	defer file.Close()
	opened, err := file.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(opened, current) {
		return record, errors.New("binding changed")
	}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(data) > 65536 {
		return record, errors.New("binding exceeds limit")
	}
	if err := json.Unmarshal(data, &record); err != nil {
		return record, err
	}
	p := record.Producer
	if record.Version != 1 || p.PaneID != pane || p.ProcessID <= 1 || p.ProcessStart == 0 ||
		(p.Provider != "claude" && p.Provider != "codex") || !validSessionID.MatchString(record.SessionID) ||
		record.ObservedAt.IsZero() || record.ObservedAt.After(time.Now().Add(time.Minute)) {
		return record, errors.New("invalid binding record")
	}
	if err := validateAccountTranscript(record.TranscriptPath, p.Provider, p.ConfigDir); err != nil {
		return record, err
	}
	if bootstrap, e := server.readPromptBootstrapOwner(pane); e == nil && bootstrap.Producer.ProcessID == p.ProcessID &&
		bootstrap.Producer.ProcessStart == p.ProcessStart && bootstrap.SessionID != record.SessionID {
		return record, errors.New("agent session changed after transcript binding")
	}
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane {
		return record, errors.New("binding worker unavailable")
	}
	if err := validateWorkerIdentity(manifest); err != nil {
		return record, err
	}
	before, err := processStartTime(p.ProcessID)
	if err != nil || before != p.ProcessStart {
		return record, errors.New("binding producer changed")
	}
	if descendantAgentProcesses(manifest.ShellPID)[p.ProcessID] != p.Provider {
		return record, errors.New("binding producer left pane")
	}
	// A nested Claude instance inherits the pane but owns a different
	// conversation. It cannot replace the original pane frontend's binding.
	provider, pid := nativeBindingFrontend(manifest.ShellPID)
	if !bindingProducerIsOriginalFrontend(p, provider, pid) {
		return record, errors.New("binding producer is not the original pane frontend")
	}
	after, err := processStartTime(p.ProcessID)
	if err != nil || after != before {
		return record, errors.New("binding producer changed")
	}
	providerAfter, pidAfter := nativeBindingFrontend(manifest.ShellPID)
	if !bindingProducerIsOriginalFrontend(p, providerAfter, pidAfter) ||
		validateWorkerIdentity(manifest) != nil {
		return record, errors.New("binding frontend changed during observation")
	}
	return record, nil
}

func privateBindingObject(path string, directory bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0077 != 0 ||
		(directory && !info.IsDir()) || (!directory && !info.Mode().IsRegular()) {
		return errors.New("binding storage is not private")
	}
	return nil
}

// ReadVerifiedAgentBinding re-observes Codex runtime selection on every read.
func ReadVerifiedAgentBinding(pane string) (AgentBindingRecord, error) {
	stored, err := readStoredVerifiedAgentBinding(pane)
	if err == nil && stored.Producer.Provider == "claude" {
		live, liveErr := ReadNativeClaudeBinding(pane)
		if liveErr == nil {
			return live, nil
		}
		if errors.Is(liveErr, errNativeClaudeParkedUnavailable) {
			return AgentBindingRecord{}, liveErr
		}
		return stored, nil
	}
	native, nativeErr := ReadNativeCodexBinding(pane)
	if nativeErr == nil {
		return native, nil
	}
	if errors.Is(nativeErr, errNativeRuntimeUnsupported) && err == nil {
		return stored, nil
	}
	claude, claudeErr := ReadNativeClaudeBinding(pane)
	if claudeErr == nil {
		return claude, nil
	}
	if !errors.Is(claudeErr, errNotNativeClaudeFrontend) {
		// The native Claude reader owns its bounded unavailability reason.
		return AgentBindingRecord{}, claudeErr
	}
	// Neither provider owns the pane: report both, not only the Codex probe,
	// so a Claude pane is never described as a missing Codex frontend.
	return AgentBindingRecord{}, fmt.Errorf("no verified agent frontend (codex: %v; claude: %v)", nativeErr, claudeErr)
}

// ReadNativeAgentBinding observes the original live frontend, bypassing stored
// telemetry. It never writes or deletes a binding or changes provider state.
func ReadNativeAgentBinding(pane string) (AgentBindingRecord, error) {
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
	if pid <= 1 {
		return empty, errors.New("no unique original native frontend")
	}
	switch provider {
	case "claude":
		return ReadNativeClaudeBinding(pane)
	case "codex":
		return ReadNativeCodexBinding(pane)
	default:
		return empty, errors.New("no supported original native frontend")
	}
}
