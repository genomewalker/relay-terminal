package daemon

import (
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type agentProducer struct {
	PaneID       string `json:"pane_id"`
	Provider     string `json:"provider"`
	ProcessID    int    `json:"process_id"`
	ProcessStart uint64 `json:"process_start"`
	SenderPID    int    `json:"sender_pid"`
}

// Infer the provider root from the sender's kernel ancestry. Claimed PIDs,
// working directories and transcript timestamps cannot identify a producer.
func verifiedAgentProducer(connection net.Conn, manifest workerManifest, provider string) (agentProducer, error) {
	uid, sender, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || sender <= 1 {
		return agentProducer{}, errors.New("agent sender unavailable")
	}
	return verifiedAgentProcess(sender, manifest, provider)
}

func verifiedAgentProcess(sender int, manifest workerManifest, provider string) (agentProducer, error) {
	if err := validateWorkerIdentity(manifest); err != nil {
		return agentProducer{}, err
	}
	senderStart, err := processStartTime(sender)
	if err != nil {
		return agentProducer{}, err
	}
	expected, err := processStartIdentity(sender)
	if err != nil {
		return agentProducer{}, err
	}
	chain, err := networkAncestors(sender, expected)
	if err != nil {
		return agentProducer{}, err
	}
	agents := descendantAgentProcesses(manifest.ShellPID)
	belongs := false
	root := 0
	starts := map[int]uint64{}
	for _, pid := range chain {
		start, e := processStartTime(pid)
		if e != nil {
			return agentProducer{}, e
		}
		starts[pid] = start
		if root == 0 && agents[pid] == provider {
			root = pid
		}
		if pid == manifest.ShellPID {
			belongs = true
			break
		}
	}
	if !belongs || root == 0 {
		return agentProducer{}, errors.New("agent sender belongs to another pane")
	}
	for pid, before := range starts {
		after, e := processStartTime(pid)
		if e != nil || after != before {
			return agentProducer{}, errors.New("agent ancestry changed")
		}
	}
	after, err := processStartTime(sender)
	if err != nil || after != senderStart {
		return agentProducer{}, errors.New("agent sender changed")
	}
	return agentProducer{manifest.SessionID, provider, root, starts[root], sender}, nil
}

// StoreNativeAgentHook binds a real CLI hook even when its already-running
// supervisor predates binding telemetry. The producer is this invocation's
// verified kernel ancestry, never a PID or process identity in the hook JSON.
func StoreNativeAgentHook(pane, provider string, raw []byte) error {
	if !validSessionID.MatchString(pane) || (provider != "claude" && provider != "codex") || len(raw) > 1<<20 {
		return errors.New("invalid native hook target")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane {
		return errors.New("native hook worker unavailable")
	}
	producer, err := verifiedAgentProcess(os.Getpid(), manifest, provider)
	if err != nil {
		return err
	}
	var hook map[string]any
	if json.Unmarshal(raw, &hook) != nil {
		return errors.New("invalid native hook event")
	}
	name, _ := hook["hook_event_name"].(string)
	if name == "SessionStart" {
		session, _ := hook["session_id"].(string)
		if err := server.storePromptBootstrapOwner(manifest, producer, session); err != nil {
			return err
		}
	}
	state := "unknown"
	switch name {
	case "Stop":
		state = "stop_observed"
	case "Notification":
		if hook["notification_type"] == "idle_prompt" {
			state = "quiet"
		} else {
			state = "needs_input"
		}
	case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
		state = "active"
	case "PermissionRequest":
		state = "needs_input"
	case "SessionEnd":
		state = "exited"
	}
	return server.storeAgentBinding(map[string]any{
		"session_id": hook["session_id"], "transcript_path": hook["transcript_path"],
		"lifecycle": state,
	}, producer)
}

// A new opt-in hook channel keeps binding metadata outside the activity journal.
// Legacy event streams remain compatible until they adopt producer authentication.
func (server *Server) forwardAuthenticatedAgentEvents(connection, worker net.Conn, manifest workerManifest) {
	writer := protocol.NewWriter(worker)
	var binding map[string]any
	for {
		_ = connection.SetReadDeadline(time.Now().Add(30 * time.Second))
		frame, err := protocol.ReadFrame(connection)
		if err != nil || len(frame.Payload) > 1<<20 {
			return
		}
		var input map[string]any
		if json.Unmarshal(frame.Payload, &input) != nil {
			return
		}
		provider, _ := input["agent"].(string)
		if provider == "" {
			provider, _ = input["provider"].(string)
		}
		if provider != "claude" && provider != "codex" {
			return
		}
		producer, err := verifiedAgentProducer(connection, manifest, provider)
		if err != nil {
			return
		}
		if frame.Type == protocol.AgentBinding {
			delete(input, "lifecycle")
			if server.storeAgentBinding(input, producer) != nil {
				return
			}
			binding = input
			continue
		}
		if frame.Type != protocol.AgentEvent || input["source"] != "hook" {
			return
		}
		event, ok := input["event"].(map[string]any)
		if !ok {
			return
		}
		raw, err := json.Marshal(event)
		if err != nil {
			return
		}
		payload, err := CanonicalAgentEnvelope(provider, raw, "hook")
		if err != nil {
			return
		}
		var envelope map[string]any
		if json.Unmarshal(payload, &envelope) != nil {
			return
		}
		if binding == nil {
			return
		}
		name, _ := event["hook_event_name"].(string)
		state := "unknown"
		if provider == "claude" {
			switch name {
			case "Stop":
				state = "stop_observed"
			case "Notification":
				notification, _ := event["notification_type"].(string)
				if notification == "idle_prompt" {
					state = "quiet"
				} else {
					state = "needs_input"
				}
			case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
				state = "active"
			case "PermissionRequest":
				state = "needs_input"
			case "SessionEnd":
				state = "exited"
			}
		}
		binding["lifecycle"] = state
		if err := server.storeAgentBinding(binding, producer); err != nil {
			return
		}
		envelope["relay_producer"] = producer
		payload, err = json.Marshal(envelope)
		if err != nil {
			return
		}
		_ = worker.SetWriteDeadline(time.Now().Add(3 * time.Second))
		if writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: payload}) != nil {
			return
		}
		// Keep the sender alive through verification. This acknowledges only
		// forwarding, not worker persistence or completion of an agent turn.
		acknowledgment, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "agent_event_received"})
		if err != nil {
			return
		}
		_ = connection.SetWriteDeadline(time.Now().Add(3 * time.Second))
		if protocol.NewWriter(connection).Write(acknowledgment) != nil {
			return
		}

	}
}

func (server *Server) storeAgentBinding(input map[string]any, producer agentProducer) error {
	session, _ := input["session_id"].(string)
	transcript, _ := input["transcript_path"].(string)
	if session == "" || len(session) > 128 || !validSessionID.MatchString(session) || len(transcript) > 4096 || strings.ContainsRune(transcript, 0) {
		return errors.New("invalid agent binding")
	}
	if err := validateBindingTranscript(transcript, producer.Provider); err != nil {
		return err
	}
	if bootstrap, e := server.readPromptBootstrapOwner(producer.PaneID); e == nil && bootstrap.Producer.ProcessID == producer.ProcessID &&
		bootstrap.Producer.ProcessStart == producer.ProcessStart && bootstrap.SessionID != session {
		return errors.New("agent event belongs to an earlier session")
	}
	directory := filepath.Join(server.stateDir, "agent-bindings")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if err := privateBindingObject(directory, true); err != nil {
		return err
	}
	revision, err := newWorkerToken()
	if err != nil {
		return err
	}
	lifecycle, _ := input["lifecycle"].(string)
	if lifecycle == "" {
		lifecycle = "unknown"
	}
	record := map[string]any{"lifecycle": lifecycle, "revision": revision, "version": 1, "producer": producer, "session_id": session, "transcript_path": transcript, "observed_at": time.Now().UTC().Format(time.RFC3339Nano)}
	return writeBindingRecord(directory, producer.PaneID, record)
}

func validateBindingTranscript(transcript, provider string) error {
	if len(transcript) > 4096 || strings.ContainsRune(transcript, 0) {
		return errors.New("invalid transcript binding")
	}
	if transcript != "" {
		info, err := os.Lstat(transcript)
		if err != nil || !filepath.IsAbs(transcript) || !info.Mode().IsRegular() {
			return errors.New("invalid transcript binding")
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != os.Getuid() {
			return errors.New("transcript owner mismatch")
		}
		if provider == "codex" && os.Getenv("CODEX_HOME") != "" {
			_, err := rotationSourcePath(transcript, provider)
			return err
		}
		marker := string(filepath.Separator) + "." + provider + string(filepath.Separator)
		if !strings.Contains(filepath.Clean(transcript), marker) {
			return errors.New("transcript provider mismatch")
		}

	}
	return nil
}

func writeBindingRecord(directory, pane string, record any) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, ".binding-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), filepath.Join(directory, pane+".json"))
}

// Read-only negotiation ensures an upgraded CLI never sends a new frame to a
// stale supervisor/worker. Probe cannot create or resume a terminal session.
func RequireAgentBindingCapability(socket, paneID string) error {
	connection, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := RequirePeerUID(connection, os.Getuid()); err != nil {
		return err
	}
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion, SessionID: paneID, Probe: true})
	if err != nil {
		return err
	}
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return err
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return errors.New("agent binding negotiation failed")
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(frame, &status) != nil || status.State != "ready" {
		return errors.New("agent binding unavailable")
	}
	for _, capability := range status.Capabilities {
		if capability == "agent_binding_v1" {
			return nil
		}
	}
	return errors.New("supervisor does not support agent binding")
}
