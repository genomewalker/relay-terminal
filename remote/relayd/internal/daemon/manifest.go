package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const workerProtocolVersion = 1

type workerManifest struct {
	Version           int       `json:"version"`
	SessionID         string    `json:"session_id"`
	WorkerPID         int       `json:"worker_pid"`
	WorkerStartTime   uint64    `json:"worker_start_time"`
	ShellPID          int       `json:"shell_pid"`
	NodeBootID        string    `json:"node_boot_id"`
	SocketPath        string    `json:"socket_path"`
	Token             string    `json:"token"`
	Command           string    `json:"command,omitempty"`
	WorkingDirectory  string    `json:"working_directory,omitempty"`
	LastSequence      uint64    `json:"last_sequence"`
	LastEventSequence uint64    `json:"last_event_sequence,omitempty"`
	State             string    `json:"state"`
	ExitCode          int       `json:"exit_code,omitempty"`
	Capabilities      []string  `json:"capabilities,omitempty"`
	CreatedAt         time.Time `json:"created_at"`
	UpdatedAt         time.Time `json:"updated_at"`
}

func (manifest workerManifest) supports(capability string) bool {
	for _, candidate := range manifest.Capabilities {
		if candidate == capability {
			return true
		}
	}
	return false
}

func newWorkerToken() (string, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func loadManifest(path string) (workerManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return workerManifest{}, err
	}
	var manifest workerManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return workerManifest{}, err
	}
	if manifest.Version != workerProtocolVersion || !validSessionID.MatchString(manifest.SessionID) {
		return workerManifest{}, errors.New("invalid Relay worker manifest")
	}
	return manifest, nil
}

func storeManifest(path string, manifest workerManifest) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	manifest.UpdatedAt = time.Now().UTC()
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".worker-*.json")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	removeTemporary = false
	return nil
}

func validateWorkerIdentity(manifest workerManifest) error {
	if manifest.WorkerPID <= 1 || manifest.WorkerStartTime == 0 || manifest.NodeBootID == "" {
		return errors.New("incomplete worker identity")
	}
	bootID, err := nodeBootID()
	if err != nil {
		return err
	}
	if bootID != manifest.NodeBootID {
		return errors.New("worker belongs to a previous node boot")
	}
	startTime, err := processStartTime(manifest.WorkerPID)
	if err != nil {
		return err
	}
	if startTime != manifest.WorkerStartTime {
		return fmt.Errorf("worker PID %d has been reused", manifest.WorkerPID)
	}
	return nil
}

func removeManifest(path string) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return
	}
}
