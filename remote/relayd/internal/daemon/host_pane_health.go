package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"regexp"
	"strings"
	"time"
)

// The model can request a native tool, but this host service has no terminal
// authority. Relay executes admitted tools against the captured pane and then
// sends their actual results back for the next journaled model step.
type hostPaneHealthRequest struct {
	Version     int             `json:"v"`
	Operation   string          `json:"operation"`
	OperationID string          `json:"operation_id"`
	HostID      string          `json:"host_id,omitempty"`
	SnapshotID  string          `json:"snapshot_id,omitempty"`
	Panes       json.RawMessage `json:"panes,omitempty"`
	Messages    json.RawMessage `json:"messages,omitempty"`
}

func nodePaneHealthEnvelope(data []byte) bool {
	var envelope struct {
		Forward *struct {
			Request struct {
				Operation string `json:"operation"`
			} `json:"request"`
		} `json:"host_accounts"`
	}
	return len(data) <= 262144 && json.Unmarshal(data, &envelope) == nil && envelope.Forward != nil &&
		strings.HasPrefix(envelope.Forward.Request.Operation, "pane_health_")
}

func handleNodePaneHealthRequest(ctx context.Context, data []byte, root string,
	service func(context.Context, string, string, any) (json.RawMessage, error)) ([]byte, error) {
	var envelope struct {
		RequestID string `json:"request_id"`
		Operation string `json:"operation"`
		Forward   *struct {
			Request hostPaneHealthRequest `json:"request"`
		} `json:"host_accounts"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if len(data) > 262144 || !rotationSourceJSONUnambiguous(data) || decoder.Decode(&envelope) != nil ||
		!validSessionID.MatchString(envelope.RequestID) || envelope.Operation != "host_accounts" || envelope.Forward == nil {
		return nil, errors.New("invalid pane health envelope")
	}
	request := envelope.Forward.Request
	if request.Version != 1 || !validPromptEditorID(request.OperationID) {
		return nil, errors.New("invalid pane health operation")
	}
	operation := "status"
	var arguments any = map[string]any{"operation_id": request.OperationID}
	switch request.Operation {
	case "pane_health_status":
		if request.HostID != "" || request.SnapshotID != "" || len(request.Panes) != 0 || len(request.Messages) != 0 {
			return nil, errors.New("invalid pane health status")
		}
	case "pane_health_step":
		if !regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`).MatchString(request.HostID) ||
			!regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(request.SnapshotID) {
			return nil, errors.New("invalid pane health snapshot")
		}
		var panes []json.RawMessage
		var messages []json.RawMessage
		if json.Unmarshal(request.Panes, &panes) != nil || len(panes) < 1 || len(panes) > 64 ||
			json.Unmarshal(request.Messages, &messages) != nil || len(messages) > 24 || len(messages)%2 != 0 {
			return nil, errors.New("invalid pane health conversation")
		}
		operation = "assess"
		arguments = map[string]any{"v": 1, "operation_id": request.OperationID, "host_id": request.HostID,
			"snapshot_id": request.SnapshotID, "panes": request.Panes, "messages": request.Messages}
	default:
		return nil, errors.New("unsupported pane health operation")
	}
	if err := ctx.Err(); err != nil {
		return nil, errors.New("pane health connection disconnected")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("pane health state unavailable")
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, errors.New("pane health state unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 75*time.Second)
	defer cancel()
	result, err := service(ctx, root, operation, arguments)
	// These failures occur before submission and have no journal row. Bind
	// them to this authenticated request so the app does not treat a budget
	// refusal as an unknown API outcome followed by endless not-found reads.
	if err == nil && operation == "assess" {
		var rejected struct {
			Version     int    `json:"v"`
			Status      string `json:"status"`
			Code        string `json:"code"`
			OperationID string `json:"operation_id"`
		}
		if json.Unmarshal(result, &rejected) == nil && rejected.Version == 1 && rejected.Status == "failed" && rejected.OperationID == "" {
			switch rejected.Code {
			case "spending_limit", "text_backend_disabled", "reconciliation_required", "health_api_account_required", "no_ready_account":
				result, _ = json.Marshal(map[string]any{"v": 1, "operation_id": request.OperationID, "status": "refused", "code": rejected.Code})
			}
		}
	}
	response := map[string]any{"request_id": envelope.RequestID, "result": result}
	if err != nil {
		response["error"] = err.Error()
	}
	return json.Marshal(response)
}
