package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

// guardedRotationInput is called only after a worker-token-authenticated
// guarded-input Hello. inputMu serializes this check, all ordinary input, and
// the PTY write. A consumed operation ID is never retried after a lost reply.
func (session *Session) guardedRotationInput(operationID string, pid int, expectedStart uint64, text string) error {
	if operationID == "" || len(operationID) > 110 || pid <= 0 || expectedStart == 0 ||
		text == "" || len(text) > 8192 || !utf8.ValidString(text) || strings.ContainsAny(text, "\x00\r\n") {
		return errors.New("invalid guarded input")
	}
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	if !session.rotationControlled || session.rotationHumanInputSeen ||
		pid != session.processID() || session.rotationGuardDirectory == "" {
		return errors.New("rotation does not exclusively own this input")
	}
	session.mu.Lock()
	exited := session.exited
	session.mu.Unlock()
	if exited {
		return io.ErrClosedPipe
	}
	before, err := processStartTime(pid)
	if err != nil || before != expectedStart {
		return errors.New("agent process incarnation changed")
	}
	// The private marker is durable before the write. If the agent or daemon
	// dies at any point from here, an external observer must reconcile it.
	if err := os.MkdirAll(session.rotationGuardDirectory, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(session.rotationGuardDirectory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return errors.New("guarded input directory is not private")
	}
	id := sha256.Sum256([]byte(operationID))
	path := filepath.Join(session.rotationGuardDirectory, hex.EncodeToString(id[:])+".json")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return errors.New("guarded input already claimed or unavailable")
	}
	marker, _ := json.Marshal(map[string]any{"operation_id": operationID, "pid": pid,
		"process_start": expectedStart})
	if _, err := file.Write(marker); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	directory, err := os.Open(session.rotationGuardDirectory)
	if err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return err
	}
	// A worker crash or partial PTY write leaves this durable marker behind.
	// A later operation must not type into a possibly unfinished input line.
	unknownPath := filepath.Join(session.rotationGuardDirectory, "outcome-unknown")
	unknown, err := os.OpenFile(unknownPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		_ = directory.Close()
		return errors.New("prior guarded input outcome is unknown")
	}
	if err := unknown.Sync(); err != nil {
		_ = unknown.Close()
		_ = directory.Close()
		return err
	}
	if err := unknown.Close(); err != nil {
		_ = directory.Close()
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return err
	}
	defer directory.Close()
	after, err := processStartTime(pid)
	if err != nil || after != expectedStart {
		return errors.New("agent process incarnation changed")
	}
	// The automation lease stays installed. Ordinary GUI input is refused
	// until an explicit native takeover changes ownership and stops rotation.
	session.rotationGuardInstalled = true
	data := append([]byte(text), '\r')
	for len(data) > 0 {
		count, err := session.pty.Write(data)
		if err != nil {
			return err
		}
		if count <= 0 {
			return io.ErrNoProgress
		}
		data = data[count:]
	}
	if err := os.Remove(unknownPath); err != nil {
		return err
	}
	return directory.Sync()
}
