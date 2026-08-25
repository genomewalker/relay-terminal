package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const maxAgentJournalBytes = 24 << 20

type indexedAgentRecord struct {
	Sequence uint64          `json:"sequence"`
	Payload  json.RawMessage `json:"payload"`
}

type agentEventJournal struct {
	path string
	file *os.File
	size int64
}

func openAgentEventJournal(path string) (*agentEventJournal, []indexedAgentRecord, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, nil, err
	}
	records, err := readAgentEventRecords(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, err
	}
	journal := &agentEventJournal{path: path, file: file, size: info.Size()}
	if journal.size > maxAgentJournalBytes {
		if err := journal.compact(records); err != nil {
			file.Close()
			return nil, nil, err
		}
		records, _ = readAgentEventRecords(path)
	}
	return journal, records, nil
}

func readAgentEventRecords(path string) ([]indexedAgentRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	records := make([]indexedAgentRecord, 0)
	for scanner.Scan() {
		var record indexedAgentRecord
		if json.Unmarshal(scanner.Bytes(), &record) == nil && record.Sequence > 0 && json.Valid(record.Payload) {
			records = append(records, record)
		}
	}
	return records, scanner.Err()
}

func (journal *agentEventJournal) append(sequence uint64, payload []byte) error {
	record := indexedAgentRecord{Sequence: sequence, Payload: payload}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	written, err := journal.file.Write(data)
	journal.size += int64(written)
	if err != nil {
		return err
	}
	if journal.size > maxAgentJournalBytes {
		records, readErr := readAgentEventRecords(journal.path)
		if readErr != nil {
			return readErr
		}
		return journal.compact(records)
	}
	return nil
}

func (journal *agentEventJournal) compact(records []indexedAgentRecord) error {
	keepBytes := 0
	start := len(records)
	for start > 0 && keepBytes < 16<<20 && len(records)-start < 10_000 {
		start--
		keepBytes += len(records[start].Payload) + 64
	}
	temporary, err := os.CreateTemp(filepath.Dir(journal.path), ".events-*.jsonl")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	for _, record := range records[start:] {
		data, marshalErr := json.Marshal(record)
		if marshalErr != nil {
			temporary.Close()
			return marshalErr
		}
		if _, err := temporary.Write(append(data, '\n')); err != nil {
			temporary.Close()
			return err
		}
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if journal.file != nil {
		_ = journal.file.Close()
	}
	if err := os.Rename(temporaryPath, journal.path); err != nil {
		return err
	}
	file, err := os.OpenFile(journal.path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	journal.file = file
	info, err := file.Stat()
	if err != nil {
		return err
	}
	journal.size = info.Size()
	return nil
}

func indexedAgentPayload(payload []byte, sequence uint64) []byte {
	var envelope map[string]any
	if json.Unmarshal(payload, &envelope) != nil {
		envelope = map[string]any{"agent": "unknown", "event": map[string]any{"type": "InvalidEvent"}}
	}
	envelope["relay_event_seq"] = sequence
	envelope["relay_recorded_at"] = time.Now().UTC().Format(time.RFC3339Nano)
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return append([]byte(nil), payload...)
	}
	return encoded
}

func indexedAgentSequence(payload []byte) uint64 {
	var envelope struct {
		Sequence uint64 `json:"relay_event_seq"`
	}
	_ = json.Unmarshal(payload, &envelope)
	return envelope.Sequence
}
