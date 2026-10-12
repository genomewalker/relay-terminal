package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// A verified SessionStart identifies a live input actor before its first
// transcript exists. This record grants no conversation/history binding.
type promptBootstrapOwner struct {
	Version     int           `json:"version"`
	Producer    agentProducer `json:"producer"`
	SessionID   string        `json:"session_id"`
	NodeBootID  string        `json:"node_boot_id"`
	WorkerPID   int           `json:"worker_pid"`
	WorkerStart uint64        `json:"worker_start"`
	ShellPID    int           `json:"shell_pid"`
	ShellStart  uint64        `json:"shell_start"`
	ObservedAt  time.Time     `json:"observed_at"`
	Revision    string        `json:"revision"`
}

func (server *Server) storePromptBootstrapOwner(manifest workerManifest, producer agentProducer, session string) error {
	if producer.Provider != "claude" || !validSessionID.MatchString(session) {
		return errors.New("invalid prompt bootstrap owner")
	}
	workerStart, err := processStartTime(manifest.WorkerPID)
	if err != nil {
		return err
	}
	shellStart, err := processStartTime(manifest.ShellPID)
	if err != nil {
		return err
	}
	actual, err := NativeAgentIncarnation(producer.PaneID, producer.ProcessID, producer.Provider)
	if err != nil || actual != producer.ProcessStart {
		return errors.New("prompt bootstrap actor changed")
	}
	revision, err := newWorkerToken()
	if err != nil {
		return err
	}
	record := promptBootstrapOwner{Version: 1, Producer: producer, SessionID: session, NodeBootID: manifest.NodeBootID,
		WorkerPID: manifest.WorkerPID, WorkerStart: workerStart, ShellPID: manifest.ShellPID, ShellStart: shellStart, ObservedAt: time.Now().UTC(), Revision: revision}
	directory := filepath.Join(server.stateDir, "prompt-owners")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if err := privateBindingObject(directory, true); err != nil {
		return err
	}
	return writeBindingRecord(directory, producer.PaneID, record)
}

func (server *Server) readPromptBootstrapOwner(pane string) (promptBootstrapOwner, error) {
	var record promptBootstrapOwner
	if !validSessionID.MatchString(pane) {
		return record, errors.New("invalid prompt bootstrap pane")
	}
	directory := filepath.Join(server.stateDir, "prompt-owners")
	if err := privateBindingObject(directory, true); err != nil {
		return record, err
	}
	data, err := privatePromptEditorBytes(filepath.Join(directory, pane+".json"), 65536)
	if err != nil {
		return record, err
	}
	if json.Unmarshal(data, &record) != nil || record.Version != 1 || record.Producer.PaneID != pane || record.Producer.Provider != "claude" ||
		record.Producer.ProcessID <= 1 || record.Producer.ProcessStart == 0 || !validSessionID.MatchString(record.SessionID) ||
		record.WorkerPID <= 1 || record.WorkerStart == 0 || record.ShellPID <= 1 || record.ShellStart == 0 || record.NodeBootID == "" ||
		record.Revision == "" || len(record.Revision) > 64 || record.ObservedAt.IsZero() || record.ObservedAt.After(time.Now().Add(time.Minute)) {
		return record, errors.New("invalid prompt bootstrap record")
	}
	return record, nil
}

func (server *Server) readVerifiedPromptBootstrapOwner(pane string) (promptBootstrapOwner, error) {
	record, err := server.readPromptBootstrapOwner(pane)
	if err != nil {
		return record, err
	}
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || validateWorkerIdentity(manifest) != nil || manifest.NodeBootID != record.NodeBootID ||
		manifest.WorkerPID != record.WorkerPID || manifest.ShellPID != record.ShellPID {
		return record, errors.New("prompt bootstrap worker changed")
	}
	workerStart, err := processStartTime(manifest.WorkerPID)
	if err != nil || workerStart != record.WorkerStart {
		return record, errors.New("prompt bootstrap worker incarnation changed")
	}
	shellStart, err := processStartTime(manifest.ShellPID)
	if err != nil || shellStart != record.ShellStart {
		return record, errors.New("prompt bootstrap shell changed")
	}
	actual, err := NativeAgentIncarnation(pane, record.Producer.ProcessID, record.Producer.Provider)
	if err != nil || actual != record.Producer.ProcessStart {
		return record, errors.New("prompt bootstrap actor changed")
	}
	confirmed, err := server.readPromptBootstrapOwner(pane)
	if err != nil || confirmed != record {
		return record, errors.New("prompt bootstrap record changed")
	}
	return record, nil
}
