package protocol

import (
	"bytes"
	"testing"
)

func BenchmarkFrameRoundTrip4KiB(b *testing.B) {
	payload := bytes.Repeat([]byte("x"), 4<<10)
	frame := Frame{Type: Output, Payload: payload}
	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	for range b.N {
		var buffer bytes.Buffer
		if err := NewWriter(&buffer).Write(frame); err != nil {
			b.Fatal(err)
		}
		if _, err := ReadFrame(&buffer); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkHostEnvelope256B(b *testing.B) {
	inner := Frame{Type: AgentEvent, Payload: bytes.Repeat([]byte("e"), 256)}
	b.ReportAllocs()
	b.SetBytes(int64(len(inner.Payload)))
	for range b.N {
		frame := HostEventFrame("0198f5ef-9fd5-7a11-80c0-000000000001", inner)
		if _, _, err := ParseHostEvent(frame); err != nil {
			b.Fatal(err)
		}
	}
}
