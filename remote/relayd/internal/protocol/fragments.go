package protocol

import (
	"encoding/binary"
	"errors"
	"io"
)

const FragmentChunkBytes = 32 << 10
const fragmentHeaderBytes = 18
const maxPartialBytes = 32 << 20
const maxPartialMessages = 64

type partialMessage struct {
	kind  Type
	total int
	data  []byte
}
type FragmentReader struct {
	source    io.Reader
	Enabled   bool
	partial   map[uint64]*partialMessage
	reserved  int
	completed map[uint64]bool
	history   []uint64
}

func NewFragmentReader(source io.Reader) *FragmentReader {
	return &FragmentReader{source: source, partial: make(map[uint64]*partialMessage), completed: make(map[uint64]bool)}
}
func FragmentFrame(id uint64, kind Type, total, offset int, chunk []byte) Frame {
	data := make([]byte, fragmentHeaderBytes+len(chunk))
	data[0] = 1
	data[1] = byte(kind)
	binary.BigEndian.PutUint64(data[2:10], id)
	binary.BigEndian.PutUint32(data[10:14], uint32(total))
	binary.BigEndian.PutUint32(data[14:18], uint32(offset))
	copy(data[18:], chunk)
	return Frame{Type: Fragment, Payload: data}
}
func (r *FragmentReader) Read() (Frame, error) {
	for {
		frame, err := ReadFrame(r.source)
		if err != nil {
			return Frame{}, err
		}
		if frame.Type != Fragment {
			return frame, nil
		}
		if !r.Enabled {
			return Frame{}, errors.New("wire fragments were not negotiated")
		}
		data := frame.Payload
		if len(data) <= fragmentHeaderBytes || len(data) > fragmentHeaderBytes+FragmentChunkBytes || data[0] != 1 {
			return Frame{}, errors.New("invalid fragment")
		}
		kind := Type(data[1])
		id := binary.BigEndian.Uint64(data[2:10])
		total := int(binary.BigEndian.Uint32(data[10:14]))
		offset := int(binary.BigEndian.Uint32(data[14:18]))
		chunk := data[18:]
		if id == 0 || kind == Fragment || kind == Capabilities || total <= 0 || total > MaxPayload || offset > total || len(chunk) > total-offset || r.completed[id] {
			return Frame{}, errors.New("invalid fragment identity or bounds")
		}
		part := r.partial[id]
		if part == nil {
			if offset != 0 || len(r.partial) >= maxPartialMessages || r.reserved+total > maxPartialBytes {
				return Frame{}, errors.New("fragment assembly capacity or initial offset invalid")
			}
			part = &partialMessage{kind: kind, total: total, data: make([]byte, 0, total)}
			r.partial[id] = part
			r.reserved += total
		}
		if part.kind != kind || part.total != total || len(part.data) != offset {
			return Frame{}, errors.New("fragment metadata or offset changed")
		}
		part.data = append(part.data, chunk...)
		if len(part.data) == total {
			delete(r.partial, id)
			r.reserved -= total
			r.completed[id] = true
			r.history = append(r.history, id)
			if len(r.history) > 512 {
				delete(r.completed, r.history[0])
				r.history = r.history[1:]
			}
			return Frame{Type: kind, Payload: part.data}, nil
		}
	}
}
