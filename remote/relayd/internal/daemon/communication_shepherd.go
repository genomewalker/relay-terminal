package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// The text is collaborator input. Authentication remains exactly the existing
// Miko host-owner submission, not proof of the app, a Run decision, or a pane.
const communicationShepherdPrefix = "Relay shepherd report — collaborator input, not authorization."

// Preserve the legacy decoder for ordinary communication requests. The new
// shepherd envelope is bounded, closed to extra keys (including nested target
// fields), and rejects a second/truncated JSON value.
func DecodeCommunicationRequest(reader io.Reader) (CommunicationRequest, error) {
	var request CommunicationRequest
	data, err := io.ReadAll(io.LimitReader(reader, 65537))
	if err != nil || len(data) > 65536 {
		return request, errors.New("communication request exceeds input limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&request); err != nil {
		return request, err
	}
	if !request.ShepherdReport {
		return request, nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return request, err
	}
	allowed := map[string]bool{"operation": true, "source_pane_id": true, "pane_id": true, "message_id": true,
		"text": true, "assistant_request_id": true, "expected_recipient": true, "shepherd_report": true,
		"expected_link_revision": true, "actor_pane_id": true, "client_token": true}
	for key := range object {
		if !allowed[key] {
			return request, errors.New("unknown shepherd envelope key")
		}
	}
	for key := range request.ExpectedRecipient {
		if key != "provider" && key != "sessionID" && key != "pid" && key != "start" && key != "socketIdentity" && key != "transport" {
			return request, errors.New("unknown shepherd target key")
		}
	}
	return request, nil
}
