package daemon

import (
	"encoding/binary"
	"io"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// Historical records can be only a few bytes each. Batch their ordered bytes
// while the worker's explicit replay boundary is open; live output stays prompt.
type terminalReplayBatch struct {
	replaying bool
	payload   []byte
	emit      func(protocol.Frame) error
}

const terminalReplayBatchBytes = 64 << 10

func forwardTerminalReplay(destination io.Writer, source io.Reader) error {
	writer := protocol.NewWriter(destination)
	batch := terminalReplayBatch{emit: writer.Write}
	for {
		frame, err := protocol.ReadFrame(source)
		if err != nil {
			if flushErr := batch.flush(); flushErr != nil {
				return flushErr
			}
			return err
		}
		if err := batch.write(frame); err != nil {
			return err
		}
		if frame.Type == protocol.Status {
			var status protocol.StatusPayload
			if protocol.DecodeJSON(frame, &status) == nil &&
				(status.State == "caught_up" || (status.State == "attached" && !batch.replaying)) {
				// Once history is delivered, preserve the low-overhead live pipe.
				_, err := io.Copy(destination, source)
				return err
			}
		}
	}
}

func (batch *terminalReplayBatch) flush() error {
	if len(batch.payload) == 0 {
		return nil
	}
	frame := protocol.Frame{Type: protocol.Output, Payload: batch.payload}
	batch.payload = nil
	return batch.emit(frame)
}

func (batch *terminalReplayBatch) write(frame protocol.Frame) error {
	if batch.replaying && frame.Type == protocol.Output && len(frame.Payload) >= 8 &&
		binary.BigEndian.Uint64(frame.Payload[:8]) != 0 {
		if len(batch.payload) > 0 && len(batch.payload)+len(frame.Payload)-8 > terminalReplayBatchBytes {
			if err := batch.flush(); err != nil {
				return err
			}
		}
		if len(frame.Payload) >= terminalReplayBatchBytes {
			if err := batch.flush(); err != nil {
				return err
			}
			return batch.emit(frame)
		}
		if len(batch.payload) == 0 {
			batch.payload = make([]byte, 8, terminalReplayBatchBytes)
		}
		copy(batch.payload[:8], frame.Payload[:8])
		batch.payload = append(batch.payload, frame.Payload[8:]...)
		if len(batch.payload) >= terminalReplayBatchBytes {
			return batch.flush()
		}
		return nil
	}
	// Keep control frames, sequence-zero resets and agent events in exact order.
	if err := batch.flush(); err != nil {
		return err
	}
	if frame.Type == protocol.Status {
		var status protocol.StatusPayload
		if protocol.DecodeJSON(frame, &status) == nil {
			switch status.State {
			case "attached", "read_only":
				batch.replaying = statusSupportsCapability(status.Capabilities, "event_cursor_v1")
			case "caught_up", "exited", "error":
				batch.replaying = false
			}
		}
	}
	return batch.emit(frame)
}
