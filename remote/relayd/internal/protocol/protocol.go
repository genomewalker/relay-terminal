package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

type Type byte

const (
	Hello          Type = 1
	Input          Type = 2
	Resize         Type = 3
	Output         Type = 4
	Status         Type = 5
	Detach         Type = 6
	Ping           Type = 7
	Pong           Type = 8
	AgentEvent     Type = 9
	Artifact       Type = 10
	InputAck       Type = 11
	InputV2        Type = 12
	HostEvent      Type = 13
	WorkspaceState Type = 14
	ViewportCommit Type = 15
	ViewportAck    Type = 16
)

const MaxPayload = 16 << 20

type Frame struct {
	Type    Type
	Payload []byte
}

func HostEventFrame(sessionID string, inner Frame) Frame {
	session := []byte(sessionID)
	payload := make([]byte, 3+len(session)+len(inner.Payload))
	binary.BigEndian.PutUint16(payload[:2], uint16(len(session)))
	payload[2] = byte(inner.Type)
	copy(payload[3:], session)
	copy(payload[3+len(session):], inner.Payload)
	return Frame{Type: HostEvent, Payload: payload}
}

func ParseHostEvent(frame Frame) (string, Frame, error) {
	if frame.Type != HostEvent || len(frame.Payload) < 3 {
		return "", Frame{}, errors.New("invalid host event frame")
	}
	length := int(binary.BigEndian.Uint16(frame.Payload[:2]))
	if length <= 0 || 3+length > len(frame.Payload) {
		return "", Frame{}, errors.New("invalid host event session")
	}
	return string(frame.Payload[3 : 3+length]), Frame{
		Type: Type(frame.Payload[2]), Payload: append([]byte(nil), frame.Payload[3+length:]...),
	}, nil
}

type HelloPayload struct {
	Version         int    `json:"version"`
	SessionID       string `json:"session_id"`
	ParentSessionID string `json:"parent_session_id,omitempty"`
	WorkspaceID     string `json:"workspace_id,omitempty"`
	TabID           string `json:"tab_id,omitempty"`
	PaneTitle       string `json:"pane_title,omitempty"`
	ContentKind     string `json:"content_kind,omitempty"`
	Command         string `json:"command,omitempty"`
	Cols            uint16 `json:"cols"`
	Rows            uint16 `json:"rows"`
	LastSeq         uint64 `json:"last_seq"`
	LastEventSeq    uint64 `json:"last_event_seq,omitempty"`
	EventOnly       bool   `json:"event_only,omitempty"`
	ObserveEvents   bool   `json:"observe_events,omitempty"`
	TerminalOnly    bool   `json:"terminal_only,omitempty"`
	Probe           bool   `json:"probe,omitempty"`
	WorkerToken     string `json:"worker_token,omitempty"`
	NodeMux         bool   `json:"node_mux,omitempty"`
	ClientID        string `json:"client_id,omitempty"`
}

type StatusPayload struct {
	State           string   `json:"state"`
	Version         string   `json:"version,omitempty"`
	ProtocolVersion int      `json:"protocol_version,omitempty"`
	SupervisorPID   int      `json:"supervisor_pid,omitempty"`
	ExitCode        int      `json:"exit_code,omitempty"`
	Message         string   `json:"message,omitempty"`
	WorkerPID       int      `json:"worker_pid,omitempty"`
	Capabilities    []string `json:"capabilities,omitempty"`
	OutputReset     bool     `json:"output_reset,omitempty"`
	EventReset      bool     `json:"event_reset,omitempty"`
	ControlGranted  *bool    `json:"control_granted,omitempty"`
	ClientCount     int      `json:"client_count,omitempty"`
}

const inputIdentityBytes = 16

func InputV2Frame(clientID [inputIdentityBytes]byte, sequence uint64, data []byte) Frame {
	payload := make([]byte, inputIdentityBytes+8+len(data))
	copy(payload[:inputIdentityBytes], clientID[:])
	binary.BigEndian.PutUint64(payload[inputIdentityBytes:inputIdentityBytes+8], sequence)
	copy(payload[inputIdentityBytes+8:], data)
	return Frame{Type: InputV2, Payload: payload}
}

func ParseInputV2(frame Frame) ([inputIdentityBytes]byte, uint64, []byte, error) {
	var clientID [inputIdentityBytes]byte
	if frame.Type != InputV2 || len(frame.Payload) < inputIdentityBytes+8 {
		return clientID, 0, nil, errors.New("invalid acknowledged input frame")
	}
	copy(clientID[:], frame.Payload[:inputIdentityBytes])
	sequence := binary.BigEndian.Uint64(frame.Payload[inputIdentityBytes : inputIdentityBytes+8])
	if sequence == 0 {
		return clientID, 0, nil, errors.New("invalid acknowledged input sequence")
	}
	return clientID, sequence, frame.Payload[inputIdentityBytes+8:], nil
}

func InputAckFrame(clientID [inputIdentityBytes]byte, sequence uint64) Frame {
	payload := make([]byte, inputIdentityBytes+8)
	copy(payload[:inputIdentityBytes], clientID[:])
	binary.BigEndian.PutUint64(payload[inputIdentityBytes:], sequence)
	return Frame{Type: InputAck, Payload: payload}
}

func ParseInputAck(frame Frame) ([inputIdentityBytes]byte, uint64, error) {
	var clientID [inputIdentityBytes]byte
	if frame.Type != InputAck || len(frame.Payload) != inputIdentityBytes+8 {
		return clientID, 0, errors.New("invalid input acknowledgement")
	}
	copy(clientID[:], frame.Payload[:inputIdentityBytes])
	return clientID, binary.BigEndian.Uint64(frame.Payload[inputIdentityBytes:]), nil
}

func JSONFrame[T any](typ Type, value T) (Frame, error) {
	payload, err := json.Marshal(value)
	return Frame{Type: typ, Payload: payload}, err
}

func DecodeJSON[T any](frame Frame, destination *T) error {
	return json.Unmarshal(frame.Payload, destination)
}

func OutputFrame(sequence uint64, data []byte) Frame {
	payload := make([]byte, 8+len(data))
	binary.BigEndian.PutUint64(payload[:8], sequence)
	copy(payload[8:], data)
	return Frame{Type: Output, Payload: payload}
}

func ParseOutput(frame Frame) (uint64, []byte, error) {
	if frame.Type != Output || len(frame.Payload) < 8 {
		return 0, nil, errors.New("invalid output frame")
	}
	return binary.BigEndian.Uint64(frame.Payload[:8]), frame.Payload[8:], nil
}

func ArtifactFrame(path string, data []byte) Frame {
	pathBytes := []byte(path)
	payload := make([]byte, 4+len(pathBytes)+len(data))
	binary.BigEndian.PutUint32(payload[:4], uint32(len(pathBytes)))
	copy(payload[4:], pathBytes)
	copy(payload[4+len(pathBytes):], data)
	return Frame{Type: Artifact, Payload: payload}
}

func ParseArtifact(frame Frame) (string, []byte, error) {
	if frame.Type != Artifact || len(frame.Payload) < 4 {
		return "", nil, errors.New("invalid artifact frame")
	}
	pathLength := int(binary.BigEndian.Uint32(frame.Payload[:4]))
	if pathLength <= 0 || pathLength > len(frame.Payload)-4 {
		return "", nil, errors.New("invalid artifact path")
	}
	return string(frame.Payload[4 : 4+pathLength]), frame.Payload[4+pathLength:], nil
}

func ResizeFrame(cols, rows uint16) Frame {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint16(payload[:2], cols)
	binary.BigEndian.PutUint16(payload[2:], rows)
	return Frame{Type: Resize, Payload: payload}
}

func ParseResize(frame Frame) (uint16, uint16, error) {
	if frame.Type != Resize || len(frame.Payload) != 4 {
		return 0, 0, errors.New("invalid resize frame")
	}
	return binary.BigEndian.Uint16(frame.Payload[:2]), binary.BigEndian.Uint16(frame.Payload[2:]), nil
}

func ViewportCommitFrame(generation uint64, cols, rows uint16) Frame {
	payload := make([]byte, 12)
	binary.BigEndian.PutUint64(payload[:8], generation)
	binary.BigEndian.PutUint16(payload[8:10], cols)
	binary.BigEndian.PutUint16(payload[10:12], rows)
	return Frame{Type: ViewportCommit, Payload: payload}
}

func ParseViewportCommit(frame Frame) (uint64, uint16, uint16, error) {
	if frame.Type != ViewportCommit || len(frame.Payload) != 12 {
		return 0, 0, 0, errors.New("invalid viewport commit frame")
	}
	generation := binary.BigEndian.Uint64(frame.Payload[:8])
	cols := binary.BigEndian.Uint16(frame.Payload[8:10])
	rows := binary.BigEndian.Uint16(frame.Payload[10:12])
	if generation == 0 || cols == 0 || rows == 0 {
		return 0, 0, 0, errors.New("invalid viewport commit values")
	}
	return generation, cols, rows, nil
}

func ViewportAckFrame(generation, repaintSequence uint64) Frame {
	payload := make([]byte, 16)
	binary.BigEndian.PutUint64(payload[:8], generation)
	binary.BigEndian.PutUint64(payload[8:], repaintSequence)
	return Frame{Type: ViewportAck, Payload: payload}
}

func ParseViewportAck(frame Frame) (uint64, uint64, error) {
	if frame.Type != ViewportAck || len(frame.Payload) != 16 {
		return 0, 0, errors.New("invalid viewport acknowledgement")
	}
	generation := binary.BigEndian.Uint64(frame.Payload[:8])
	if generation == 0 {
		return 0, 0, errors.New("invalid viewport generation")
	}
	return generation, binary.BigEndian.Uint64(frame.Payload[8:]), nil
}

func ReadFrame(reader io.Reader) (Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return Frame{}, err
	}
	length := binary.BigEndian.Uint32(header[1:])
	if length > MaxPayload {
		return Frame{}, fmt.Errorf("payload too large: %d", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return Frame{}, err
	}
	return Frame{Type: Type(header[0]), Payload: payload}, nil
}

type Writer struct {
	writer io.Writer
	mu     sync.Mutex
}

func NewWriter(writer io.Writer) *Writer {
	return &Writer{writer: writer}
}

func (writer *Writer) Write(frame Frame) error {
	if len(frame.Payload) > MaxPayload {
		return fmt.Errorf("payload too large: %d", len(frame.Payload))
	}
	writer.mu.Lock()
	defer writer.mu.Unlock()
	var header [5]byte
	header[0] = byte(frame.Type)
	binary.BigEndian.PutUint32(header[1:], uint32(len(frame.Payload)))
	if _, err := writer.writer.Write(header[:]); err != nil {
		return err
	}
	_, err := writer.writer.Write(frame.Payload)
	return err
}
