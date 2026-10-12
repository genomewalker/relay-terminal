//go:build linux

package agentlaunch

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// CodexStartSettings are effective values recorded by the source thread's
// completed turn. They are restart metadata, not model-facing handoff text.
type CodexStartSettings struct {
	SourceThreadID  string         `json:"source_thread_id"`
	SourceTurnID    string         `json:"source_turn_id"`
	StartParameters map[string]any `json:"start_parameters"`
	Effort          string         `json:"effort,omitempty"`
	RolloutPath     string         `json:"rollout_path"`
}

func DiscoverCodexStartSettings(snapshot Snapshot, threadID string) (CodexStartSettings, error) {
	if !sessionUUID.MatchString(threadID) {
		return CodexStartSettings{}, errors.New("invalid source thread")
	}
	socket, err := DiscoverCodexSocket(snapshot)
	if err != nil {
		return CodexStartSettings{}, err
	}
	// A resumed CLI names its exact source. Other CLI forms need an independent
	// authenticated pane-to-thread binding before automatic enrollment.
	bound := false
	for i, arg := range snapshot.EffectiveArgs {
		if arg == "resume" && i+1 < len(snapshot.EffectiveArgs) && snapshot.EffectiveArgs[i+1] == threadID {
			bound = true
		}
	}
	if !bound {
		return CodexStartSettings{}, errors.New("source CLI is not bound to this thread")
	}
	root := filepath.Dir(filepath.Dir(socket.Path))
	sessions := filepath.Join(root, "sessions")
	var found string
	visited := 0
	err = filepath.WalkDir(sessions, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		visited++
		if visited > 100000 {
			return errors.New("Codex rollout search exceeds bound")
		}
		if entry.Type().IsRegular() && strings.HasSuffix(entry.Name(), "-"+threadID+".jsonl") {
			if found != "" {
				return errors.New("ambiguous Codex rollout")
			}
			found = path
		}
		return nil
	})
	if err != nil {
		return CodexStartSettings{}, err
	}
	if found == "" {
		return CodexStartSettings{}, errors.New("source rollout unavailable")
	}
	settings, err := readCodexStartSettings(found, threadID)
	if err != nil {
		return CodexStartSettings{}, err
	}
	if err := VerifyProcess(snapshot); err != nil {
		return CodexStartSettings{}, err
	}
	return settings, nil
}

func readCodexStartSettings(path, threadID string) (CodexStartSettings, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 64<<20 {
		return CodexStartSettings{}, errors.New("Codex rollout unavailable or too large")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return CodexStartSettings{}, errors.New("Codex rollout owner changed")
	}
	file, err := os.Open(path)
	if err != nil {
		return CodexStartSettings{}, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 2<<20)
	var metaSeen, active, abortedAfterComplete bool
	var latest map[string]json.RawMessage
	var latestTurn string
	contexts := map[string]map[string]json.RawMessage{}
	var settingsAfter map[string]json.RawMessage
	for scanner.Scan() {
		var item struct {
			Type    string                     `json:"type"`
			Payload map[string]json.RawMessage `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &item) != nil {
			return CodexStartSettings{}, errors.New("invalid Codex rollout entry")
		}
		switch item.Type {
		case "session_meta":
			var id string
			_ = json.Unmarshal(item.Payload["id"], &id)
			if id != threadID || metaSeen {
				return CodexStartSettings{}, errors.New("Codex rollout identity mismatch")
			}
			metaSeen = true
		case "turn_context":
			var id string
			_ = json.Unmarshal(item.Payload["turn_id"], &id)
			if id != "" {
				contexts[id] = item.Payload
				settingsAfter = nil
			}
		case "event_msg":
			var kind, id string
			_ = json.Unmarshal(item.Payload["type"], &kind)
			_ = json.Unmarshal(item.Payload["turn_id"], &id)
			switch kind {
			case "task_started":
				active = true
			case "task_complete":
				if context := contexts[id]; context != nil {
					latest, latestTurn = context, id
					abortedAfterComplete = false
				}
				active = false
			case "turn_aborted":
				active = false
				abortedAfterComplete = true
			case "thread_settings_applied":
				if latest != nil {
					_ = json.Unmarshal(item.Payload["thread_settings"], &settingsAfter)
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return CodexStartSettings{}, err
	}
	if !metaSeen || active || abortedAfterComplete || latest == nil {
		return CodexStartSettings{}, errors.New("source has no completed stable turn")
	}
	var model, cwd, approval, effort, personality string
	var sandbox struct {
		Type string `json:"type"`
	}
	for _, field := range []struct {
		key    string
		target *string
	}{{"model", &model}, {"cwd", &cwd}, {"approval_policy", &approval}, {"effort", &effort}, {"personality", &personality}} {
		if json.Unmarshal(latest[field.key], field.target) != nil {
			return CodexStartSettings{}, errors.New("source turn settings are incomplete")
		}
	}
	if json.Unmarshal(latest["sandbox_policy"], &sandbox) != nil || model == "" || !filepath.IsAbs(cwd) || approval == "" {
		return CodexStartSettings{}, errors.New("source turn policy is incomplete")
	}
	// thread/start's legacy sandbox is a mode, not the full turn-level policy.
	// Refuse custom policy details rather than silently relaxing them.
	var policy map[string]any
	if json.Unmarshal(latest["sandbox_policy"], &policy) != nil || len(policy) != 1 {
		return CodexStartSettings{}, errors.New("custom Codex sandbox policy needs exact profile capture")
	}
	sandboxMode := map[string]string{"danger-full-access": "dangerFullAccess", "read-only": "readOnly", "workspace-write": "workspaceWrite"}[sandbox.Type]
	if sandboxMode == "" {
		return CodexStartSettings{}, errors.New("unsupported Codex sandbox mode")
	}
	if settingsAfter != nil {
		for source, applied := range map[string]string{"model": "model", "approval_policy": "approval_policy", "cwd": "cwd", "effort": "reasoning_effort", "personality": "personality"} {
			if value, exists := settingsAfter[applied]; exists && string(value) != string(latest[source]) {
				return CodexStartSettings{}, errors.New("Codex settings changed after completed turn")
			}
		}
		if raw, exists := settingsAfter["permission_profile"]; exists {
			var profile struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(raw, &profile) != nil || (profile.Type == "disabled") != (sandbox.Type == "danger-full-access") {
				return CodexStartSettings{}, errors.New("Codex permission profile changed after completed turn")
			}
		}
	}
	params := map[string]any{"model": model, "cwd": cwd, "approvalPolicy": approval, "sandbox": sandboxMode}
	if personality != "" {
		params["personality"] = personality
	}
	return CodexStartSettings{SourceThreadID: threadID, SourceTurnID: latestTurn,
		StartParameters: params, Effort: effort, RolloutPath: path}, nil
}
