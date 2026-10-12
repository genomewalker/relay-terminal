package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// RotationPaneStatus is a read-only process observation. It does not claim a
// prompt is ready or an input buffer is empty; the native renderer and agent
// status must establish those facts separately before any guarded send.
type RotationPaneStatus struct {
	PaneID            string `json:"pane_id"`
	SessionID         string `json:"session_id"`
	AgentPID          int    `json:"agent_pid"`
	AgentStart        uint64 `json:"agent_start"`
	WorkerPID         int    `json:"worker_pid"`
	WorkerStart       uint64 `json:"worker_start"`
	State             string `json:"state"`
	InputOutcomeKnown bool   `json:"input_outcome_known"`
}

func (server *Server) RotationStatus(paneID string) (RotationPaneStatus, error) {
	if !validSessionID.MatchString(paneID) {
		return RotationPaneStatus{}, errors.New("invalid rotation pane")
	}
	claimPath := filepath.Join(server.stateDir, "rotation-launches", paneID+".json")
	info, err := os.Lstat(claimPath)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 ||
		info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return RotationPaneStatus{}, errors.New("rotation claim unavailable")
	}
	data, err := os.ReadFile(claimPath)
	if err != nil || len(data) > 65536 {
		return RotationPaneStatus{}, errors.New("rotation claim unreadable")
	}
	var claim claudeRotationClaim
	if json.Unmarshal(data, &claim) != nil || claim.PaneID != paneID || claim.SessionID == "" {
		return RotationPaneStatus{}, errors.New("rotation claim identity mismatch")
	}
	manifest, err := loadManifest(server.manifestPath(paneID))
	if err != nil || manifest.SessionID != paneID || manifest.ShellPID <= 1 {
		return RotationPaneStatus{}, errors.New("rotation worker unavailable")
	}
	state, err := server.workerState(manifest)
	if err != nil || state != "ready" {
		return RotationPaneStatus{}, errors.New("rotation worker identity changed")
	}
	start, err := processStartTime(manifest.ShellPID)
	if err != nil || start == 0 {
		return RotationPaneStatus{}, errors.New("rotation agent process unavailable")
	}
	_, err = os.Lstat(filepath.Join(server.stateDir, "rotation-input", paneID, "outcome-unknown"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return RotationPaneStatus{}, errors.New("rotation input outcome unavailable")
	}
	return RotationPaneStatus{PaneID: paneID, SessionID: claim.SessionID,
		AgentPID: manifest.ShellPID, AgentStart: start,
		WorkerPID: manifest.WorkerPID, WorkerStart: manifest.WorkerStartTime,
		State: "ready", InputOutcomeKnown: errors.Is(err, os.ErrNotExist)}, nil
}
