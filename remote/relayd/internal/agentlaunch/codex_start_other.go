//go:build !linux

package agentlaunch

import "errors"

type CodexStartSettings struct {
	SourceThreadID  string         `json:"source_thread_id"`
	SourceTurnID    string         `json:"source_turn_id"`
	StartParameters map[string]any `json:"start_parameters"`
	Effort          string         `json:"effort,omitempty"`
	RolloutPath     string         `json:"rollout_path"`
}

func DiscoverCodexStartSettings(snapshot Snapshot, threadID string) (CodexStartSettings, error) {
	return CodexStartSettings{}, errors.New("Codex rollout discovery requires Linux")
}
