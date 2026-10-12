package daemon

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
)

type rotationCodexMessage struct {
	Type     string          `json:"type"`
	ID       string          `json:"id"`
	Role     string          `json:"role"`
	Channel  string          `json:"channel"`
	Content  json.RawMessage `json:"content"`
	Metadata json.RawMessage `json:"internal_chat_message_metadata_passthrough"`
}

type rotationCodexMetadata struct {
	TurnID string          `json:"turn_id"`
	Kinds  json.RawMessage `json:"content_item_kinds"`
}

type rotationCodexMessageKey struct{ turn, id string }
type rotationCodexPendingMessage struct {
	slot   int
	digest [32]byte
}

// The native public completion stream supplies evidence for modern Responses
// messages whose raw schema has no channel. Keep response order, join on exact
// thread/turn/message identity and text, and never promote an explicit hidden
// channel. Completion events alone cannot contribute source text.
type rotationCodexPublicSource struct {
	session    string
	identified bool
	slots      []rotationSourceMessage
	pending    map[rotationCodexMessageKey]rotationCodexPendingMessage
	completed  map[rotationCodexMessageKey][32]byte
	responses  map[rotationCodexMessageKey]bool
	textBytes  int
}

func rotationCodexIdentity(value string) bool {
	return value != "" && len(value) <= 256 && strings.TrimSpace(value) == value && !strings.ContainsAny(value, "\x00\r\n")
}

func rotationCodexReadMetadata(raw json.RawMessage) (rotationCodexMetadata, bool, error) {
	var metadata rotationCodexMetadata
	if len(raw) == 0 || string(raw) == "null" {
		return metadata, false, nil
	}
	if json.Unmarshal(raw, &metadata) != nil {
		return metadata, true, errors.New("invalid source message metadata")
	}
	if metadata.TurnID != "" && !rotationCodexIdentity(metadata.TurnID) {
		return metadata, true, errors.New("invalid source message turn")
	}
	return metadata, true, nil
}

func rotationCodexUserText(raw json.RawMessage, metadata rotationCodexMetadata, present bool) (string, error) {
	// Older transcripts have no classifications. Modern harness metadata is
	// authoritative and aligned one-for-one with content entries.
	if !present {
		return rotationPublicText(raw, "user", false)
	}
	if len(metadata.Kinds) == 0 || string(metadata.Kinds) == "null" {
		return "", nil
	}
	var kinds []string
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(metadata.Kinds, &kinds) != nil || json.Unmarshal(raw, &blocks) != nil || len(kinds) != len(blocks) {
		return "", errors.New("source content classifications mismatch")
	}
	text := []string{}
	for i, block := range blocks {
		if kinds[i] != "user.text" {
			continue
		}
		if block.Type != "input_text" {
			return "", errors.New("source user text classification mismatch")
		}
		if block.Text != "" {
			text = append(text, block.Text)
		}
	}
	return strings.Join(text, "\n"), nil
}

func (source *rotationCodexPublicSource) add(role, text string) (int, error) {
	source.textBytes += len(text)
	if source.textBytes > rotationSourceTextLimit {
		return 0, errors.New("source text limit exceeded")
	}
	slot := len(source.slots)
	source.slots = append(source.slots, rotationSourceMessage{role, text})
	return slot, nil
}

func (source *rotationCodexPublicSource) response(raw json.RawMessage) error {
	var message rotationCodexMessage
	if json.Unmarshal(raw, &message) != nil {
		return errors.New("invalid public message")
	}
	if message.Type != "message" || (message.Role != "user" && message.Role != "assistant") {
		return nil
	}
	metadata, present, err := rotationCodexReadMetadata(message.Metadata)
	if err != nil {
		return err
	}
	if message.ID != "" && !rotationCodexIdentity(message.ID) {
		return errors.New("invalid source message identity")
	}
	key := rotationCodexMessageKey{metadata.TurnID, message.ID}
	identified := rotationCodexIdentity(key.turn) && rotationCodexIdentity(key.id)
	if identified {
		if source.responses == nil {
			source.responses = map[rotationCodexMessageKey]bool{}
		}
		if source.responses[key] {
			return errors.New("duplicate source message identity")
		}
		source.responses[key] = true
	}
	if message.Role == "user" && message.Channel != "" {
		return nil
	}
	if message.Role == "assistant" && message.Channel != "" && message.Channel != "final" && message.Channel != "commentary" {
		return nil
	}
	text := ""
	if message.Role == "user" {
		text, err = rotationCodexUserText(message.Content, metadata, present)
	} else {
		text, err = rotationPublicText(message.Content, "assistant", false)
	}
	if err != nil {
		return err
	}
	if text == "" {
		return nil
	}
	if message.Role == "assistant" && message.Channel == "" {
		if !identified {
			return nil
		}
		slot, err := source.add("", text)
		if err != nil {
			return err
		}
		digest := sha256.Sum256([]byte(text))
		if completed, ok := source.completed[key]; ok {
			if completed != digest {
				return errors.New("source public completion text mismatch")
			}
			source.slots[slot].Role = "assistant"
		} else {
			if source.pending == nil {
				source.pending = map[rotationCodexMessageKey]rotationCodexPendingMessage{}
			}
			source.pending[key] = rotationCodexPendingMessage{slot, digest}
		}
		return nil
	}
	slot, err := source.add(message.Role, text)
	if err != nil {
		return err
	}
	if message.Role == "assistant" && identified {
		digest := sha256.Sum256([]byte(text))
		if completed, ok := source.completed[key]; ok {
			if completed != digest {
				return errors.New("source public completion text mismatch")
			}
		} else {
			if source.pending == nil {
				source.pending = map[rotationCodexMessageKey]rotationCodexPendingMessage{}
			}
			source.pending[key] = rotationCodexPendingMessage{slot, digest}
		}
	}
	return nil
}

func (source *rotationCodexPublicSource) event(raw json.RawMessage) error {
	var event struct {
		Type     string `json:"type"`
		ThreadID string `json:"thread_id"`
		TurnID   string `json:"turn_id"`
		Item     struct {
			Type    string          `json:"type"`
			ID      string          `json:"id"`
			Content json.RawMessage `json:"content"`
		} `json:"item"`
	}
	if json.Unmarshal(raw, &event) != nil {
		return errors.New("invalid source event")
	}
	if event.Type == "thread_rolled_back" {
		return errors.New("source rollback requires explicit branch reconstruction")
	}
	if event.Type != "item_completed" || event.Item.Type != "AgentMessage" {
		return nil
	}
	if !source.identified || event.ThreadID != source.session || !rotationCodexIdentity(event.TurnID) || !rotationCodexIdentity(event.Item.ID) {
		return errors.New("source public completion identity mismatch")
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(event.Item.Content, &blocks) != nil {
		return errors.New("invalid source public completion")
	}
	parts := []string{}
	for _, block := range blocks {
		if block.Type != "Text" {
			return errors.New("unsupported source public completion content")
		}
		if block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	text := strings.Join(parts, "\n")
	if len(text) > rotationSourceTextLimit {
		return errors.New("source text limit exceeded")
	}
	key := rotationCodexMessageKey{event.TurnID, event.Item.ID}
	if source.completed == nil {
		source.completed = map[rotationCodexMessageKey][32]byte{}
	}
	if _, exists := source.completed[key]; exists {
		return errors.New("duplicate source public completion")
	}
	digest := sha256.Sum256([]byte(text))
	source.completed[key] = digest
	if pending, ok := source.pending[key]; ok {
		if pending.digest != digest {
			return errors.New("source public completion text mismatch")
		}
		source.slots[pending.slot].Role = "assistant"
		delete(source.pending, key)
	}
	return nil
}

func (source *rotationCodexPublicSource) messages() []rotationSourceMessage {
	messages := []rotationSourceMessage{}
	for _, message := range source.slots {
		if message.Role != "" {
			messages = append(messages, message)
		}
	}
	return messages
}
