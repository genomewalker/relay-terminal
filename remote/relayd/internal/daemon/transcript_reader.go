package daemon

import (
	"bufio"
	"errors"
	"io"
	"os"
	"syscall"
)

const maxTranscriptRecordBytes = 8 << 20

// readTranscriptLines follows an append-only JSONL file without letting one
// oversized or partially-written record wedge every later event. It also
// notices truncation and inode replacement, both common during log rotation.
func readTranscriptLines(
	path string,
	offset *int64,
	discardingOversized *bool,
	identity *[2]uint64,
	handle func([]byte),
) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return
	}
	currentIdentity := [2]uint64{}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		currentIdentity = [2]uint64{uint64(stat.Dev), uint64(stat.Ino)}
	}
	if (*identity != [2]uint64{} && *identity != currentIdentity) || info.Size() < *offset {
		*offset = 0
		*discardingOversized = false
	}
	*identity = currentIdentity
	if _, err := file.Seek(*offset, io.SeekStart); err != nil {
		return
	}

	reader := bufio.NewReaderSize(file, 64<<10)
	committed := *offset
	consumed := *offset
	line := make([]byte, 0, 64<<10)
	for {
		fragment, readErr := reader.ReadSlice('\n')
		consumed += int64(len(fragment))
		if *discardingOversized {
			// Once a record is known to be oversized, every byte through its
			// terminating newline is safe to commit. This prevents repeatedly
			// rescanning a multi-megabyte record while it is still being written.
			committed = consumed
			*offset = committed
			if len(fragment) > 0 && fragment[len(fragment)-1] == '\n' {
				*discardingOversized = false
			}
		} else if len(line)+len(fragment) > maxTranscriptRecordBytes {
			line = line[:0]
			*discardingOversized = true
			committed = consumed
			*offset = committed
			if len(fragment) > 0 && fragment[len(fragment)-1] == '\n' {
				*discardingOversized = false
			}
		} else {
			line = append(line, fragment...)
			if !errors.Is(readErr, bufio.ErrBufferFull) {
				if len(line) > 0 && line[len(line)-1] == '\n' {
					handle(line[:len(line)-1])
					committed = consumed
					*offset = committed
				}
				line = line[:0]
			}
		}
		if readErr != nil && !errors.Is(readErr, bufio.ErrBufferFull) {
			return
		}
	}
}
