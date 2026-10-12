// Package codexsession implements the supported Codex App Server message path.
// It deliberately does not attach to or impersonate desktop-owned sessions.
package codexsession

import (
	"encoding/json"
	"errors"
	"strings"
)

const MaxMessageBytes = 65536

// Message is collaborator input, never user authorization. Sender must be
// populated by the authenticated transport, not taken from a claimed identity.
type Message struct {
	ID      string `json:"id"`
	Sender  string `json:"sender"`
	Content string `json:"content"`
}

// TurnParams preserves the authority boundary enforced by the official server.
// A successful turn/start acknowledges admission, not processing or durability.
func TurnParams(threadID string, message Message) (map[string]any, error) {
	if strings.TrimSpace(threadID) == "" || strings.TrimSpace(message.ID) == "" || strings.TrimSpace(message.Sender) == "" || strings.TrimSpace(message.Content) == "" {
		return nil, errors.New("thread, message id, authenticated sender and content are required")
	}
	b, err := json.Marshal(message)
	if err != nil {
		return nil, err
	}
	if len(b) > MaxMessageBytes {
		return nil, errors.New("message exceeds size limit")
	}
	return map[string]any{
		"threadId": threadID,
		"input":    []any{},
		"toolOutput": map[string]any{
			"name": "peer_message", "namespace": "relay", "output": string(b),
		},
	}, nil
}
