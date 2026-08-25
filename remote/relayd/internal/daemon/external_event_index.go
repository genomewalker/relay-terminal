package daemon

import (
	"crypto/sha256"
	"encoding/json"
	"sync"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type externalEventIndex struct {
	mu       sync.Mutex
	journal  *agentEventJournal
	sequence uint64
	frames   []protocol.Frame
	bytes    int
	hashes   map[[32]byte]protocol.Frame
}

var externalEventIndexes sync.Map

func sharedExternalEventIndex(path string) (*externalEventIndex, error) {
	if existing, ok := externalEventIndexes.Load(path); ok {
		return existing.(*externalEventIndex), nil
	}
	journal, records, err := openAgentEventJournal(path)
	if err != nil {
		return nil, err
	}
	index := &externalEventIndex{journal: journal, hashes: make(map[[32]byte]protocol.Frame)}
	for _, record := range records {
		index.sequence = record.Sequence
		frame := protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), record.Payload...)}
		index.hashes[eventDedupHash(record.Payload)] = frame
		index.appendFrame(frame)
	}
	actual, loaded := externalEventIndexes.LoadOrStore(path, index)
	if loaded {
		_ = journal.file.Close()
		return actual.(*externalEventIndex), nil
	}
	return index, nil
}

func (index *externalEventIndex) index(payload []byte) protocol.Frame {
	index.mu.Lock()
	defer index.mu.Unlock()
	hash := eventDedupHash(payload)
	if frame, exists := index.hashes[hash]; exists {
		return protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), frame.Payload...)}
	}
	index.sequence++
	indexed := indexedAgentPayload(payload, index.sequence)
	_ = index.journal.append(index.sequence, indexed)
	frame := protocol.Frame{Type: protocol.AgentEvent, Payload: indexed}
	index.hashes[hash] = frame
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
