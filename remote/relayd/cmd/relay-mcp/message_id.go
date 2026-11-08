package main

import "encoding/json"

// generatedMessageIDTools send one message under a message_id the caller may
// omit, each mapped to the receipt tool that reads that ID back.
var generatedMessageIDTools = map[string]string{
	"relay_message_pane":         "relay_pane_message_receipt",
	"relay_send_desktop_message": "relay_message_read_receipt",
}

// messageIDOptionalNote is appended to the message_id property descriptions.
const messageIDOptionalNote = "omit to let Relay generate one; reuse only to retry the same message"

// callWithGeneratedMessageID sends a message whose message_id was omitted
// under a fresh crypto/rand UUIDv4, then returns that ID in the result so
// the caller can read receipts. A supplied ID is left to the ordinary path
// and its validation (handled is false).
func (s *server) callWithGeneratedMessageID(name string, arguments map[string]json.RawMessage) (any, int, string, bool) {
	receipt, ok := generatedMessageIDTools[name]
	if !ok {
		return nil, 0, "", false
	}
	if _, supplied := arguments["message_id"]; supplied {
		return nil, 0, "", false
	}
	id, err := newRequestUUID()
	if err != nil {
		return nil, -32603, "Could not generate a message ID", true
	}
	withID := make(map[string]json.RawMessage, len(arguments)+1)
	for key, value := range arguments {
		withID[key] = value
	}
	withID["message_id"], _ = json.Marshal(id)
	params, _ := json.Marshal(map[string]any{"name": name, "arguments": withID})
	result, code, detail := s.handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/call", Params: params})
	return withGeneratedMessageID(result, id, receipt), code, detail, true
}

func withGeneratedMessageID(result any, id, receipt string) any {
	value, ok := result.(map[string]any)
	if !ok {
		return result
	}
	text := "Relay generated message_id " + id + " for this message. Read its outcome with " + receipt +
		" and this ID; retry only under the same ID, never a new one."
	switch content := value["content"].(type) {
	case []any:
		value["content"] = append(content, map[string]string{"type": "text", "text": text})
	case []map[string]any:
		value["content"] = append(content, map[string]any{"type": "text", "text": text})
	case []map[string]string:
		value["content"] = append(content, map[string]string{"type": "text", "text": text})
	}
	value["message_id"] = id
	return value
}
