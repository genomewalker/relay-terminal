package daemon

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// SavedConversationPlan is an explicit recovery of a retained provider session.
// It neither adopts a process nor creates or changes a pane worker.
type SavedConversationPlan struct {
	PaneID     string `json:"pane_id"`
	Provider   string `json:"provider"`
	SessionID  string `json:"session_id"`
	Directory  string `json:"directory"`
	BindingSHA string `json:"binding_sha"`
}

func ReadSavedConversationPlan(pane string) (SavedConversationPlan, error) {
	return readSavedConversationPlan(NewServer(), pane)
}

func readSavedConversationPlan(server *Server, pane string) (SavedConversationPlan, error) {
	var plan SavedConversationPlan
	if !validSessionID.MatchString(pane) {
		return plan, errors.New("invalid saved pane identity")
	}
	if manifest, err := loadManifest(server.manifestPath(pane)); err == nil && validateWorkerIdentity(manifest) == nil {
		// A worker retains replay after its root terminal exits. Its own
		// liveness cannot mean the provider is still running. Require both
		// the durable exit and an absent shell before permitting recovery.
		if manifest.State != "exited" {
			return plan, errors.New("pane worker is still running; reconnect it instead")
		}
		if _, err := processStartTime(manifest.ShellPID); err == nil {
			return plan, errors.New("pane shell is still running; reconnect it instead")
		}
	}
	directory := filepath.Join(server.stateDir, "agent-bindings")
	path := filepath.Join(directory, pane+".json")
	if err := privateBindingObject(directory, true); err != nil {
		return plan, err
	}
	if err := privateBindingObject(path, false); err != nil {
		return plan, err
	}
	file, err := OpenPrivateFile(path, os.O_RDONLY)
	if err != nil {
		return plan, err
	}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	file.Close()
	var binding AgentBindingRecord
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &binding) != nil || binding.Version != 1 ||
		binding.Producer.PaneID != pane || !validSessionID.MatchString(binding.SessionID) ||
		(binding.Producer.Provider != "claude" && binding.Producer.Provider != "codex") ||
		binding.Producer.ProcessID <= 1 || binding.Producer.ProcessStart == 0 {
		return plan, errors.New("saved provider binding is unavailable or invalid")
	}
	if start, err := processStartTime(binding.Producer.ProcessID); err == nil && start == binding.Producer.ProcessStart {
		return plan, errors.New("saved provider process is still running; reconnect it instead")
	}
	if binding.TranscriptPath == "" || validateBindingTranscript(binding.TranscriptPath, binding.Producer.Provider) != nil {
		return plan, errors.New("saved provider transcript is unavailable")
	}
	transcript, err := os.Open(binding.TranscriptPath)
	if err != nil {
		return plan, err
	}
	defer transcript.Close()
	before, err := transcript.Stat()
	current, statErr := os.Lstat(binding.TranscriptPath)
	if err != nil || statErr != nil || !os.SameFile(before, current) || before.Size() > 64<<20 {
		return plan, errors.New("saved transcript changed or exceeds the recovery limit")
	}
	scanner := bufio.NewScanner(io.LimitReader(transcript, 64<<20))
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for count := 0; count < 40000 && scanner.Scan(); count++ {
		var record struct {
			Type      string `json:"type"`
			SessionID string `json:"sessionId"`
			Cwd       string `json:"cwd"`
			Payload   struct {
				ID  string `json:"id"`
				Cwd string `json:"cwd"`
			} `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &record) != nil {
			continue
		}
		if binding.Producer.Provider == "claude" && record.SessionID == binding.SessionID && record.Cwd != "" {
			plan.Directory = record.Cwd
			break
		}
		if binding.Producer.Provider == "codex" && record.Type == "session_meta" && record.Payload.ID == binding.SessionID {
			plan.Directory = record.Payload.Cwd
			break
		}
	}
	after, err := os.Lstat(binding.TranscriptPath)
	if err != nil || !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return SavedConversationPlan{}, errors.New("saved transcript changed during recovery")
	}
	info, err := os.Stat(plan.Directory)
	if scanner.Err() != nil || err != nil || !filepath.IsAbs(plan.Directory) || !info.IsDir() {
		return SavedConversationPlan{}, errors.New("saved session identity or working directory could not be verified")
	}
	digest := sha256.Sum256(data)
	plan.PaneID, plan.Provider, plan.SessionID = pane, binding.Producer.Provider, binding.SessionID
	plan.BindingSHA = hex.EncodeToString(digest[:])
	return plan, nil
}
