package daemon

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// PromptOwnerBinding identifies an editable terminal owner without granting input.
// Time, activity, cwd and mutable transcript length are deliberately excluded.
type PromptOwnerBinding struct {
	Version            int    `json:"version"`
	PaneID             string `json:"pane_id"`
	NodeBootID         string `json:"node_boot_id"`
	WorkerPID          int    `json:"worker_pid"`
	WorkerStart        uint64 `json:"worker_start"`
	ShellPID           int    `json:"shell_pid"`
	ShellStart         uint64 `json:"shell_start"`
	Provider           string `json:"provider"`
	ProcessID          int    `json:"process_id"`
	ProcessStart       uint64 `json:"process_start"`
	SessionID          string `json:"session_id,omitempty"`
	TranscriptIdentity string `json:"transcript_identity,omitempty"`
	InputOnly          bool   `json:"input_only,omitempty"`
}

func ReadVerifiedPromptOwnerBinding(pane string) (PromptOwnerBinding, error) {
	return NewServer().readVerifiedPromptOwnerBinding(pane)
}

func (server *Server) readVerifiedPromptOwnerBinding(pane string) (PromptOwnerBinding, error) {
	var empty PromptOwnerBinding
	if !validSessionID.MatchString(pane) {
		return empty, errors.New("invalid prompt pane")
	}
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil || manifest.ShellPID <= 1 {
		return empty, errors.New("prompt worker unavailable")
	}
	workerStart, err := processStartTime(manifest.WorkerPID)
	if err != nil {
		return empty, err
	}
	boot, err := nodeBootID()
	if err != nil {
		return empty, err
	}
	shellStart, err := processStartTime(manifest.ShellPID)
	if err != nil {
		return empty, err
	}
	shellIdentity, err := processStartIdentity(manifest.ShellPID)
	if err != nil {
		return empty, err
	}
	ancestors, err := networkAncestors(manifest.ShellPID, shellIdentity)
	belongs := false
	for _, pid := range ancestors {
		if pid == manifest.WorkerPID {
			belongs = true
		}
	}
	if err != nil || !belongs {
		return empty, errors.New("prompt shell left worker")
	}
	result := PromptOwnerBinding{Version: 1, PaneID: pane, NodeBootID: boot, WorkerPID: manifest.WorkerPID, WorkerStart: workerStart, ShellPID: manifest.ShellPID, ShellStart: shellStart, Provider: "shell", ProcessID: manifest.ShellPID, ProcessStart: shellStart}
	if len(descendantAgentProcesses(manifest.ShellPID)) > 0 {
		provider, pid := nativeBindingFrontend(manifest.ShellPID)
		if pid <= 1 {
			return empty, errors.New("prompt agent is ambiguous")
		}
		record, e := ReadVerifiedAgentBinding(pane)
		if e != nil || record.Producer.ProcessID != pid || record.Producer.Provider != provider || record.TranscriptPath == "" {
			bootstrap, err := server.readVerifiedPromptBootstrapOwner(pane)
			// Stored records are read unverified as well: a record naming this
			// exact process that fails verification must still refuse.
			stored, _ := readStoredVerifiedAgentBinding(pane)
			rawBootstrap, _ := server.readPromptBootstrapOwner(pane)
			evidence := promptOwnerEvidence{
				Provider:          provider,
				PID:               pid,
				RecordNamesPID:    e == nil && record.Producer.ProcessID == pid,
				StoredNamesPID:    stored.Producer.ProcessID == pid,
				BootstrapVerified: err == nil && bootstrap.Producer.ProcessID == pid,
				BootstrapNamesPID: rawBootstrap.Producer.ProcessID == pid,
				SessionConflict:   e == nil && err == nil && record.SessionID != "" && record.SessionID != bootstrap.SessionID,
			}
			switch promptOwnerFallback(evidence) {
			case promptOwnerBootstrap:
				result.Provider = provider
				result.ProcessID = pid
				result.ProcessStart = bootstrap.Producer.ProcessStart
				result.SessionID = bootstrap.SessionID
				result.TranscriptIdentity = "input:" + bootstrap.Revision
				result.InputOnly = true
			case promptOwnerPreSession:
				// The agent is in a startup dialog (folder trust, sign-in)
				// before any session or hook exists, and no record names it.
				// The live frontend, fenced by its kernel start, owns the
				// prompt for input only; it names no conversation.
				start, startErr := NativeAgentIncarnation(pane, pid, provider)
				if startErr != nil || start == 0 {
					return empty, errors.New("prompt agent binding unavailable")
				}
				result.Provider = provider
				result.ProcessID = pid
				result.ProcessStart = start
				result.TranscriptIdentity = PromptOwnerPreSessionIdentity
				result.InputOnly = true
			default:
				return empty, errors.New("prompt agent binding unavailable")
			}
		} else {
			file, e := os.Lstat(record.TranscriptPath)
			if e != nil || !file.Mode().IsRegular() {
				return empty, errors.New("prompt transcript unavailable")
			}
			stat, ok := file.Sys().(*syscall.Stat_t)
			if !ok || int(stat.Uid) != os.Getuid() {
				return empty, errors.New("prompt transcript owner changed")
			}
			result.Provider = provider
			result.ProcessID = pid
			result.ProcessStart = record.Producer.ProcessStart
			result.SessionID = record.SessionID
			result.TranscriptIdentity = fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
			confirmed, confirmationErr := ReadVerifiedAgentBinding(pane)
			afterFile, fileErr := os.Lstat(record.TranscriptPath)
			if confirmationErr != nil || fileErr != nil || !os.SameFile(file, afterFile) || confirmed.Producer.ProcessID != record.Producer.ProcessID || confirmed.Producer.ProcessStart != record.Producer.ProcessStart || confirmed.SessionID != record.SessionID || confirmed.TranscriptPath != record.TranscriptPath {
				return empty, errors.New("prompt transcript changed")
			}
			start, e := NativeAgentIncarnation(pane, pid, provider)
			if e != nil || start != result.ProcessStart {
				return empty, errors.New("prompt agent changed")
			}
		}
	}
	workerAfter, workerErr := processStartTime(manifest.WorkerPID)
	if workerErr != nil || workerAfter != workerStart {
		return empty, errors.New("prompt worker incarnation changed")
	}
	after, err := processStartTime(manifest.ShellPID)
	latest, loadErr := loadManifest(server.manifestPath(pane))
	if err != nil || after != shellStart || validateWorkerIdentity(manifest) != nil || loadErr != nil || latest.WorkerPID != manifest.WorkerPID || latest.WorkerStartTime != manifest.WorkerStartTime || latest.ShellPID != manifest.ShellPID || latest.NodeBootID != manifest.NodeBootID {
		return empty, errors.New("prompt owner changed")
	}
	provider, pid := nativeBindingFrontend(manifest.ShellPID)
	if result.Provider == "shell" {
		if len(descendantAgentProcesses(manifest.ShellPID)) != 0 {
			return empty, errors.New("prompt agent appeared")
		}
	} else if provider != result.Provider || pid != result.ProcessID {
		return empty, errors.New("prompt frontend changed")
	}
	return result, nil
}

// PromptOwnerPreSessionIdentity marks an input-only owner that names no
// conversation: the live agent frontend before its first session exists.
const PromptOwnerPreSessionIdentity = "presession"

type promptOwnerChoice int

const (
	promptOwnerRefuse promptOwnerChoice = iota
	promptOwnerBootstrap
	promptOwnerPreSession
)

// promptOwnerEvidence is what the records say about the live frontend when no
// complete transcript binding names it.
type promptOwnerEvidence struct {
	Provider string
	PID      int
	// A verified agent binding names this process (without a transcript).
	RecordNamesPID bool
	// The stored agent binding names this process, verified or not.
	StoredNamesPID bool
	// A verified SessionStart bootstrap names this process.
	BootstrapVerified bool
	// The stored bootstrap record names this process, verified or not.
	BootstrapNamesPID bool
	// The verified binding and bootstrap name different sessions.
	SessionConflict bool
}

// promptOwnerFallback chooses an owner when no transcript binding names the
// live frontend. A verified Claude bootstrap wins. Only when no record of any
// kind names this exact process is the process itself the input-only owner;
// a record for this process that is incomplete or unverifiable refuses.
func promptOwnerFallback(evidence promptOwnerEvidence) promptOwnerChoice {
	if evidence.PID <= 1 || (evidence.Provider != "claude" && evidence.Provider != "codex") {
		return promptOwnerRefuse
	}
	if evidence.BootstrapVerified {
		if evidence.Provider != "claude" || evidence.SessionConflict {
			return promptOwnerRefuse
		}
		return promptOwnerBootstrap
	}
	if evidence.RecordNamesPID || evidence.StoredNamesPID || evidence.BootstrapNamesPID {
		return promptOwnerRefuse
	}
	return promptOwnerPreSession
}
