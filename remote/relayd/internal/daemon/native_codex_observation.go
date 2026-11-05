package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// Observation reads immutable session metadata, not a quiescent transcript.
// Rotation/restore admission continues to use the full strict source reader.
func readHostRotationNativeObservationCandidate(ctx context.Context, pane string) (hostRotationNativeCandidate, error) {
	var empty hostRotationNativeCandidate
	before, err := ReadNativeAgentBinding(pane)
	if err != nil {
		return empty, err
	}
	if before.Producer.Provider != "codex" {
		return readHostRotationNativeCandidate(ctx, pane)
	}
	path, err := bindingSourcePath(before, "codex")
	if err != nil {
		return empty, err
	}
	cwd, info, err := readCodexObservationHeader(path, before.SessionID)
	if err != nil {
		return empty, err
	}
	after, err := ReadNativeAgentBinding(pane)
	if err != nil || !sameHostRotationNativeBinding(before, after) {
		return empty, errors.New("native session changed during observation")
	}
	candidate := hostRotationNativeCandidate{Version: 1, State: "ready", CWD: cwd, Binding: before, path: path, info: info, directories: []string{cwd}}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	if err := candidate.verifyCurrentCWD(); err != nil {
		return empty, err
	}
	return candidate, nil
}

func readCodexObservationHeader(path, session string) (string, os.FileInfo, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return "", nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	first, err := file.Stat()
	if err != nil || !first.Mode().IsRegular() {
		return "", nil, errors.New("native metadata source unavailable")
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		return "", nil, errors.New("native session metadata unavailable")
	}
	header := bytes.Clone(scanner.Bytes())
	id, _, kind, err := nativeCodexOpenTranscriptMetadata(header)
	var metadata struct {
		Payload struct {
			CWD string `json:"cwd"`
		} `json:"payload"`
	}
	if err != nil || id != session || kind != "root" || json.Unmarshal(header, &metadata) != nil || !filepath.IsAbs(metadata.Payload.CWD) {
		return "", nil, errors.New("native session metadata mismatch")
	}
	// Appends are ordinary agent output. Replacement, truncation or an edited
	// metadata prefix invalidate this read, without hashing the full transcript.
	again := make([]byte, len(header))
	if _, err := file.ReadAt(again, 0); err != nil || !bytes.Equal(header, again) {
		return "", nil, errors.New("native session metadata changed")
	}
	current, err := os.Lstat(path)
	if err != nil || !os.SameFile(first, current) || current.Mode() != first.Mode() || current.Size() < int64(len(header)) {
		return "", nil, errors.New("native metadata source changed")
	}
	return metadata.Payload.CWD, current, nil
}
