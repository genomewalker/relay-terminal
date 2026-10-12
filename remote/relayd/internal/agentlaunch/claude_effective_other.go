//go:build !linux

package agentlaunch

import (
	"errors"
	"time"
)

type ClaudeEffectiveSettings struct {
	SessionID      string    `json:"session_id"`
	PaneID         string    `json:"pane_id"`
	SourcePID      int       `json:"source_pid"`
	SourceStart    string    `json:"source_start"`
	Model          string    `json:"model"`
	Effort         string    `json:"effort,omitempty"`
	PermissionMode string    `json:"permission_mode"`
	CWD            string    `json:"cwd"`
	FreshArguments []string  `json:"fresh_args"`
	CapturedAt     time.Time `json:"captured_at"`
}

func DiscoverClaudeEffectiveSettings(snapshot Snapshot, sessionID string) (ClaudeEffectiveSettings, error) {
	return ClaudeEffectiveSettings{}, errors.New("Claude live settings discovery requires Linux")
}
