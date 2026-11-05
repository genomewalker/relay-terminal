package daemon

import (
	"io"
	"strings"
	"testing"
	"time"
)

func TestReadWorkRequestFrameDoesNotWaitForEOF(t *testing.T) {
	r, w := io.Pipe()
	defer w.Close()
	go w.Write([]byte("{\"a\":1}\n"))
	done := make(chan string, 1)
	go func() { b, _ := readWorkRequestFrame(r, 1024); done <- string(b) }()
	select {
	case got := <-done:
		if got != `{"a":1}` {
			t.Fatalf("frame %q", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("reader waited for EOF while the writer stayed open")
	}
}
func TestReadWorkRequestFrameEOFAndLimit(t *testing.T) {
	if b, err := readWorkRequestFrame(strings.NewReader(`{"a":1}`), 1024); err != nil || string(b) != `{"a":1}` {
		t.Fatalf("EOF frame %q %v", b, err)
	}
	if _, err := readWorkRequestFrame(strings.NewReader(strings.Repeat("x", 20)), 10); err == nil {
		t.Fatal("accepted oversized frame")
	}
}
