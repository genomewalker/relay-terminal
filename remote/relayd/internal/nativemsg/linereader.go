package nativemsg

import (
	"bufio"
	"bytes"
	"io"
	"sort"
)

func sortStrings(values []string) { sort.Strings(values) }

// lineReader is a buffered binary file's readline(limit).
type lineReader struct{ r *bufio.Reader }

func newLineReader(r io.Reader) *lineReader { return &lineReader{bufio.NewReaderSize(r, 65536)} }

// readline returns up to limit bytes, ending at the first newline.
func (l *lineReader) readline(limit int) ([]byte, error) {
	var line []byte
	for len(line) < limit {
		chunk, err := l.r.Peek(1)
		if len(chunk) == 0 {
			if err == io.EOF {
				return line, nil
			}
			return nil, fromOS(err)
		}
		buffered, _ := l.r.Peek(l.r.Buffered())
		if len(buffered) > limit-len(line) {
			buffered = buffered[:limit-len(line)]
		}
		if i := bytes.IndexByte(buffered, '\n'); i >= 0 {
			line = append(line, buffered[:i+1]...)
			l.r.Discard(i + 1)
			return line, nil
		}
		line = append(line, buffered...)
		l.r.Discard(len(buffered))
	}
	return line, nil
}
