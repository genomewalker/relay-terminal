package daemon

import (
	"bytes"
	"io"
	"os"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// Codex (0.169+) compresses a rollout it has not written to for a while into
// rollout-…-<thread>.jsonl.zst, even while a pane still has that thread
// loaded. It reads the compressed form back on resume, so an idle pane's only
// saved conversation is often the compressed file.
const (
	phCodexCompressedSuffix = ".jsonl.zst"
	// A decoded rollout larger than this is refused rather than streamed on.
	phMaxDecompressed = int64(4) << 30
)

func phCodexCompressed(path string) bool {
	return strings.HasSuffix(path, phCodexCompressedSuffix)
}

// phCodexRolloutName reports whether name is session's plain or compressed
// rollout file name.
func phCodexRolloutName(name, session string) bool {
	return strings.HasSuffix(name, "-"+session+".jsonl") || strings.HasSuffix(name, "-"+session+phCodexCompressedSuffix)
}

// phPreferPlainRollout collapses a plain rollout and its compressed twin to
// the plain one, which Codex appends to; anything else is returned unchanged.
func phPreferPlainRollout(matches []string) []string {
	if len(matches) != 2 {
		return matches
	}
	for i, path := range matches {
		other := matches[1-i]
		if phCodexCompressed(other) && other == path+".zst" {
			return []string{path}
		}
	}
	return matches
}

// phTranscriptStream is the decoded content of an opened transcript.
func phTranscriptStream(file *os.File, path string) (io.Reader, func()) {
	if !phCodexCompressed(path) {
		return file, func() {}
	}
	decoder, err := zstd.NewReader(file, zstd.WithDecoderConcurrency(1), zstd.WithDecoderLowmem(true),
		zstd.WithDecoderMaxMemory(256<<20))
	if err != nil {
		phRaise(phValueError, "The compressed conversation could not be read.")
	}
	return io.LimitReader(decoder, phMaxDecompressed), decoder.Close
}

// phDecodedTail is the last limit bytes of a compressed transcript, starting
// at a line boundary when anything before them was dropped.
func phDecodedTail(file *os.File, path string, limit int64) []byte {
	stream, done := phTranscriptStream(file, path)
	defer done()
	var tail []byte
	total := int64(0)
	buffer := make([]byte, 1<<20)
	for {
		n, err := stream.Read(buffer)
		total += int64(n)
		tail = append(tail, buffer[:n]...)
		if int64(len(tail)) > 2*limit {
			tail = append(tail[:0:0], tail[int64(len(tail))-limit:]...)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			phRaise(phValueError, "The compressed conversation could not be read.")
		}
	}
	if total >= phMaxDecompressed {
		phRaise(phValueError, "The compressed conversation is too large to read.")
	}
	if int64(len(tail)) > limit {
		tail = tail[int64(len(tail))-limit:]
	}
	if total > int64(len(tail)) {
		// The first kept line may be partial.
		if index := bytes.IndexByte(tail, '\n'); index >= 0 {
			tail = tail[index+1:]
		} else {
			tail = nil
		}
	}
	return tail
}
