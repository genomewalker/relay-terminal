package daemon

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/programstatus"
	"github.com/relay-terminal/relayd/internal/protocol"
)

// workerReexecStateFormat versions the state a pane worker hands to the image
// it re-executes. An image accepts only formats it can restore exactly; the
// old image runs the new image's probe before exec and refuses otherwise.
const workerReexecStateFormat = 1

// The state is bounded by the replay ring and event history it carries.
const workerReexecStateLimit = 64 << 20

// workerReexecState is everything a Session holds that is not recoverable
// from the kernel (PTY, shell process) or from disk (journal, manifest,
// rotation record): output and event cursors, replay, dedup hashes, terminal
// input modes, program status, the input lease and transcript positions.
type workerReexecState struct {
	Format                 int                        `json:"format"`
	Operation              string                     `json:"operation"`
	SessionID              string                     `json:"session_id"`
	ShellPID               int                        `json:"shell_pid"`
	ShellStart             uint64                     `json:"shell_start"`
	Sequence               uint64                     `json:"sequence"`
	Replay                 []workerReexecRecord       `json:"replay"`
	ReplayTrimmed          bool                       `json:"replay_trimmed,omitempty"`
	EventSequence          uint64                     `json:"event_sequence"`
	EventHistory           [][]byte                   `json:"event_history,omitempty"`
	EventHashOrder         [][]byte                   `json:"event_hash_order,omitempty"`
	EventJournalError      string                     `json:"event_journal_error,omitempty"`
	LatestAgentEvent       []byte                     `json:"latest_agent_event,omitempty"`
	ActiveSubagents        map[string][]byte          `json:"active_subagents,omitempty"`
	ActiveAgentRoots       map[string][]byte          `json:"active_agent_roots,omitempty"`
	AgentProcesses         map[int]string             `json:"agent_processes,omitempty"`
	InputSequences         map[string]uint64          `json:"input_sequences,omitempty"`
	HumanInputRevision     uint64                     `json:"human_input_revision"`
	RotationHumanInputSeen bool                       `json:"rotation_human_input_seen,omitempty"`
	TerminalModes          terminalModeSnapshot       `json:"terminal_modes"`
	ProgramStatus          programstatus.TrackerState `json:"program_status"`
	ProgramStatusRevision  uint64                     `json:"program_status_revision"`
	ControlClientID        string                     `json:"control_client_id,omitempty"`
	Transcripts            []transcriptCursor         `json:"transcripts,omitempty"`
	ManifestCreatedAt      time.Time                  `json:"manifest_created_at"`
}

type workerReexecRecord struct {
	Sequence  uint64           `json:"sequence"`
	Data      []byte           `json:"data"`
	Artifacts []protocol.Frame `json:"artifacts,omitempty"`
}

type terminalModeSnapshot struct {
	OSC           []byte       `json:"osc,omitempty"`
	CommandActive bool         `json:"command_active,omitempty"`
	EscapeState   uint8        `json:"escape_state,omitempty"`
	CSI           []byte       `json:"csi,omitempty"`
	KeyboardStack []int        `json:"keyboard_stack"`
	PrivateModes  map[int]bool `json:"private_modes,omitempty"`
}

func (state *terminalModeState) export() terminalModeSnapshot {
	modes := make(map[int]bool, len(state.privateModes))
	for mode, enabled := range state.privateModes {
		modes[mode] = enabled
	}
	return terminalModeSnapshot{
		OSC: append([]byte(nil), state.osc...), CommandActive: state.commandActive, EscapeState: state.escapeState,
		CSI: append([]byte(nil), state.csi...), KeyboardStack: append([]int(nil), state.keyboardStack...), PrivateModes: modes,
	}
}

func restoreTerminalModes(snapshot terminalModeSnapshot) terminalModeState {
	state := newTerminalModeState()
	if len(snapshot.KeyboardStack) > 0 {
		state.keyboardStack = append([]int(nil), snapshot.KeyboardStack...)
	}
	for mode, enabled := range snapshot.PrivateModes {
		state.privateModes[mode] = enabled
	}
	state.osc = append(state.osc[:0], snapshot.OSC...)
	state.csi = append(state.csi[:0], snapshot.CSI...)
	state.commandActive = snapshot.CommandActive
	state.escapeState = snapshot.EscapeState
	return state
}

// exportReexecState captures the session. The caller holds inputMu, resizeMu
// and eventMu and has stopped the output reader, so nothing changes after it.
func (session *Session) exportReexecState(operation string, transcripts []transcriptCursor, createdAt time.Time) (workerReexecState, error) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.exited || session.process == nil || session.process.Process == nil {
		return workerReexecState{}, errors.New("pane shell has exited")
	}
	shellPID := session.process.Process.Pid
	shellStart, err := processStartTime(shellPID)
	if err != nil {
		return workerReexecState{}, fmt.Errorf("pane shell identity: %w", err)
	}
	state := workerReexecState{
		Format: workerReexecStateFormat, Operation: operation, SessionID: session.id,
		ShellPID: shellPID, ShellStart: shellStart,
		Sequence: session.sequence, ReplayTrimmed: session.replayTrimmed,
		EventSequence: session.eventSequence, EventJournalError: session.eventJournalError,
		LatestAgentEvent:   append([]byte(nil), session.latestAgentEvent...),
		ActiveSubagents:    cloneByteMap(session.activeSubagents),
		ActiveAgentRoots:   cloneByteMap(session.activeAgentRoots),
		AgentProcesses:     cloneAgentProcesses(session.agentProcesses),
		InputSequences:     make(map[string]uint64, len(session.inputSequences)),
		HumanInputRevision: session.humanInputRevision, RotationHumanInputSeen: session.rotationHumanInputSeen,
		TerminalModes:         session.terminalModes.export(),
		ProgramStatus:         session.programStatus.Export(),
		ProgramStatusRevision: session.programStatusRevision,
		ControlClientID:       session.controlClientID,
		Transcripts:           transcripts,
		ManifestCreatedAt:     createdAt,
	}
	for _, item := range session.replay {
		state.Replay = append(state.Replay, workerReexecRecord{Sequence: item.sequence, Data: item.data, Artifacts: item.artifacts})
	}
	for _, frame := range session.eventHistory {
		state.EventHistory = append(state.EventHistory, frame.Payload)
	}
	for _, hash := range session.eventHashOrder {
		state.EventHashOrder = append(state.EventHashOrder, append([]byte(nil), hash[:]...))
	}
	for clientID, sequence := range session.inputSequences {
		state.InputSequences[hex.EncodeToString(clientID[:])] = sequence
	}
	return state, nil
}

// restoreReexecState applies a carried state to a session built around the
// inherited PTY and shell, before any of its goroutines start.
func (session *Session) restoreReexecState(state workerReexecState) error {
	if state.Format != workerReexecStateFormat || state.SessionID != session.id {
		return errors.New("worker state belongs to another format or session")
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	session.sequence = state.Sequence
	session.replay = session.replay[:0]
	session.replayBytes = 0
	for _, item := range state.Replay {
		session.replay = append(session.replay, record{sequence: item.Sequence, data: item.Data, artifacts: item.Artifacts})
		session.replayBytes += len(item.Data)
		for _, artifact := range item.Artifacts {
			session.replayBytes += len(artifact.Payload)
		}
	}
	session.replayTrimmed = state.ReplayTrimmed
	session.eventSequence = state.EventSequence
	session.eventJournalError = state.EventJournalError
	session.eventHistory, session.eventHistoryBytes = nil, 0
	for _, payload := range state.EventHistory {
		session.appendEventHistory(protocol.Frame{Type: protocol.AgentEvent, Payload: payload})
	}
	session.eventHashes = make(map[[32]byte]struct{}, len(state.EventHashOrder))
	session.eventHashOrder = session.eventHashOrder[:0]
	for _, raw := range state.EventHashOrder {
		var hash [32]byte
		if len(raw) != len(hash) {
			return errors.New("invalid event hash in worker state")
		}
		copy(hash[:], raw)
		session.eventHashes[hash] = struct{}{}
		session.eventHashOrder = append(session.eventHashOrder, hash)
	}
	session.latestAgentEvent = state.LatestAgentEvent
	session.activeSubagents = nonNilByteMap(state.ActiveSubagents)
	session.activeAgentRoots = nonNilByteMap(state.ActiveAgentRoots)
	session.agentProcesses = cloneAgentProcesses(state.AgentProcesses)
	session.agentProcessesSeeded = true
	for key, sequence := range state.InputSequences {
		var clientID [16]byte
		raw, err := hex.DecodeString(key)
		if err != nil || len(raw) != len(clientID) {
			return errors.New("invalid input client in worker state")
		}
		copy(clientID[:], raw)
		session.inputSequences[clientID] = sequence
	}
	session.humanInputRevision = state.HumanInputRevision
	session.rotationHumanInputSeen = state.RotationHumanInputSeen
	session.terminalModes = restoreTerminalModes(state.TerminalModes)
	session.programStatus.Restore(state.ProgramStatus)
	session.programStatusRevision = state.ProgramStatusRevision
	if state.ControlClientID != "" {
		// Every attachment closed at exec. Hold the lease for its owner exactly
		// as an ungraceful disconnect does, so its reconnect keeps control.
		session.controlClientID = state.ControlClientID
		session.controlGraceUntil = time.Now().Add(5 * time.Second)
	}
	session.reexecOperation = state.Operation
	return nil
}

func writeWorkerReexecState(file *os.File, state workerReexecState) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if len(data) > workerReexecStateLimit {
		return errors.New("worker state exceeds the handoff limit")
	}
	if _, err := file.WriteAt(data, 0); err != nil {
		return err
	}
	return file.Truncate(int64(len(data)))
}

// readWorkerReexecState uses positioned reads, so the probe and the new image
// can each read the same open file description.
func readWorkerReexecState(file *os.File) (workerReexecState, error) {
	data, err := io.ReadAll(io.NewSectionReader(file, 0, workerReexecStateLimit+1))
	if err != nil {
		return workerReexecState{}, err
	}
	if len(data) > workerReexecStateLimit {
		return workerReexecState{}, errors.New("worker state exceeds the handoff limit")
	}
	var state workerReexecState
	if err := json.Unmarshal(data, &state); err != nil {
		return workerReexecState{}, err
	}
	if state.Format != workerReexecStateFormat || !validSessionID.MatchString(state.SessionID) || state.ShellPID <= 1 {
		return workerReexecState{}, fmt.Errorf("unsupported worker state format %d", state.Format)
	}
	return state, nil
}

// ProbeWorkerReexecState is run by the old image, as the new executable, on
// the exact state it is about to hand over. Exec happens only if it passes.
func ProbeWorkerReexecState(file *os.File, output io.Writer) error {
	state, err := readWorkerReexecState(file)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(map[string]any{"format": state.Format, "session_id": state.SessionID})
}

func cloneByteMap(source map[string][]byte) map[string][]byte {
	result := make(map[string][]byte, len(source))
	for key, value := range source {
		result[key] = append([]byte(nil), value...)
	}
	return result
}

func nonNilByteMap(source map[string][]byte) map[string][]byte {
	if source == nil {
		return make(map[string][]byte)
	}
	return source
}
