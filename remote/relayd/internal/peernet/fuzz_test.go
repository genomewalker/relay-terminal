package peernet

import (
	"bufio"
	"bytes"
	"strings"
	"testing"
)

func FuzzPeerFrameBoundary(f *testing.F) {
	for _, data := range [][]byte{[]byte("{}\nnext\n"), []byte("unterminated"), []byte(strings.Repeat("x", MaxFrame) + "\n"), []byte("\n"), nil} {
		f.Add(data)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > MaxFrame*2+10 {
			return
		}
		r := bufio.NewReaderSize(bytes.NewReader(data), MaxFrame+1)
		got, err := line(r)
		end := bytes.IndexByte(data, '\n')
		accepted := end >= 0 && end+1 <= MaxFrame
		if accepted {
			if err != nil || !bytes.Equal(got, data[:end+1]) {
				t.Fatal("lossless bounded first frame changed")
			}
		} else if err == nil {
			t.Fatal("accepted truncated or oversized frame")
		}
	})
}
