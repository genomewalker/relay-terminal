package daemon

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type externalEventIndex struct {
	mu        sync.Mutex
	journal   *agentEventJournal
	sequence  uint64
	frames    []protocol.Frame
	bytes     int
	hashes    map[[32]byte]protocol.Frame
	hashOrder [][32]byte
	users     int
	lastUsed  time.Time
}

var externalEventIndexes = struct {
	sync.Mutex
	values map[string]*externalEventIndex
}{values: make(map[string]*externalEventIndex)}

func sharedExternalEventIndex(path string) (*externalEventIndex, error) {
	externalEventIndexes.Lock()
	defer externalEventIndexes.Unlock()
	now := time.Now()
	for candidatePath, candidate := range externalEventIndexes.values {
		if candidate.users == 0 && now.Sub(candidate.lastUsed) > time.Hour {
			delete(externalEventIndexes.values, candidatePath)
			_ = candidate.journal.file.Close()
		}
	}
	if existing := externalEventIndexes.values[path]; existing != nil {
		existing.users++
		existing.lastUsed = now
		return existing, nil
	}
	journal, records, err := openAgentEventJournal(path)
	if err != nil {
		return nil, err
	}
	index := &externalEventIndex{journal: journal, hashes: make(map[[32]byte]protocol.Frame), users: 1, lastUsed: now}
	for _, record := range records {
		index.sequence = record.Sequence
		frame := protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), record.Payload...)}
		hash := semanticAgentEventHash(record.Payload)
		index.hashes[hash] = frame
		index.hashOrder = append(index.hashOrder, hash)
		index.appendFrame(frame)
	}
	externalEventIndexes.values[path] = index
	return index, nil
}

func releaseExternalEventIndex(path string, index *externalEventIndex) {
	externalEventIndexes.Lock()
	defer externalEventIndexes.Unlock()
	if externalEventIndexes.values[path] != index {
		return
	}
	if index.users > 0 {
		index.users--
	}
	index.lastUsed = time.Now()
}

func (index *externalEventIndex) index(payload []byte) protocol.Frame {
	index.mu.Lock()
	defer index.mu.Unlock()
	hash := semanticAgentEventHash(payload)
	if frame, exists := index.hashes[hash]; exists {
		return protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), frame.Payload...)}
	}
	index.sequence++
	indexed := indexedAgentPayload(payload, index.sequence)
	if err := index.journal.append(index.sequence, indexed); err != nil {
		fmt.Fprintf(os.Stderr, "relay: observed agent journal append failed: %v\n", err)
	}
	frame := protocol.Frame{Type: protocol.AgentEvent, Payload: indexed}
	index.hashes[hash] = frame
	index.hashOrder = append(index.hashOrder, hash)
	if len(index.hashOrder) > 10_000 {
		oldest := index.hashOrder[0]
		index.hashOrder = index.hashOrder[1:]
		delete(index.hashes, oldest)
	}
	index.appendFrame(frame)
	return protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), indexed...)}
}

func eventDedupHash(payload []byte) [32]byte {
	var envelope map[string]any
	if json.Unmarshal(payload, &envelope) == nil {
		delete(envelope, "relay_event_seq")
		delete(envelope, "relay_recorded_at")
		if normalized, err := json.Marshal(envelope); err == nil {
			return sha256.Sum256(normalized)
		}
	}
	return sha256.Sum256(payload)
}

func semanticAgentEventHash(payload []byte) [32]byte {
	var envelope struct {
		Agent string         `json:"agent"`
		Event map[string]any `json:"event"`
	}
	if json.Unmarshal(payload, &envelope) != nil {
		return sha256.Sum256(payload)
	}
	eventName, _ := envelope.Event["hook_event_name"].(string)
	if eventName == "" {
		eventName, _ = envelope.Event["type"].(string)
	}
	switch eventName {
	case "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "SubagentUpdate", "PeerMessage", "PeerInteraction":
		canonical := map[string]any{"agent": envelope.Agent, "event": eventName}
		for _, key := range []string{
			"agent_id", "subagent_id", "thread_id", "root_id", "from_peer_id", "to_peer_id",
			"message", "message_type", "status",
		} {
			if value, exists := envelope.Event[key]; exists {
				canonical[key] = value
			}
		}
		encoded, _ := json.Marshal(canonical)
		return sha256.Sum256(encoded)
	default:
		return eventDedupHash(payload)
	}
}

func (index *externalEventIndex) framesAfter(sequence uint64) []protocol.Frame {
	index.mu.Lock()
	defer index.mu.Unlock()
	frames := make([]protocol.Frame, 0, len(index.frames))
	for _, frame := range index.frames {
		if indexedAgentSequence(frame.Payload) > sequence {
			frames = append(frames, protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), frame.Payload...)})
		}
	}
	return frames
}

func (index *externalEventIndex) appendFrame(frame protocol.Frame) {
	index.frames = append(index.frames, frame)
	index.bytes += len(frame.Payload)
	for (index.bytes > 16<<20 || len(index.frames) > 10_000) && len(index.frames) > 1 {
		index.bytes -= len(index.frames[0].Payload)
		index.frames = index.frames[1:]
	}
}
