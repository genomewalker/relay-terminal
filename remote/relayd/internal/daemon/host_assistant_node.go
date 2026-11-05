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

// Relay assistant model steps share the host account, reservation journal and
// settlement path with pane-health steps. This route has no terminal or pane
// authority: the app executes admitted read/navigation tools in-process and
// sends their results back for the next journaled step. Tool definitions and
// the system prompt are fixed by the text adapter, never supplied here.
type hostAssistantRequest struct {
	Version     int             `json:"v"`
	Operation   string          `json:"operation"`
	OperationID string          `json:"operation_id"`
	RequestID   string          `json:"request_id"`
	HostID      string          `json:"host_id"`
	Context     string          `json:"context"`
	Messages    json.RawMessage `json:"messages"`
}

var hostAssistantHostID = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)

func nodeAssistantEnvelope(data []byte) bool {
	var envelope struct {
		Forward *struct {
			Request struct {
				Operation string `json:"operation"`
			} `json:"request"`
		} `json:"host_accounts"`
	}
	return len(data) <= 262144 && json.Unmarshal(data, &envelope) == nil && envelope.Forward != nil &&
		strings.HasPrefix(envelope.Forward.Request.Operation, "assistant_")
}

func handleNodeAssistantRequest(ctx context.Context, data []byte, root string,
	service func(context.Context, string, string, any) (json.RawMessage, error)) ([]byte, error) {
	var envelope struct {
		RequestID string `json:"request_id"`
		Operation string `json:"operation"`
		Forward   *struct {
			Request hostAssistantRequest `json:"request"`
		} `json:"host_accounts"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if len(data) > 262144 || !rotationSourceJSONUnambiguous(data) || decoder.Decode(&envelope) != nil ||
		!validSessionID.MatchString(envelope.RequestID) || envelope.Operation != "host_accounts" || envelope.Forward == nil {
		return nil, errors.New("invalid assistant envelope")
	}
	request := envelope.Forward.Request
	if request.Version != 1 || request.Operation != "assistant_step" || !validPromptEditorID(request.OperationID) ||
		!validPromptEditorID(request.RequestID) ||
		!hostAssistantHostID.MatchString(request.HostID) || request.Context == "" || len(request.Context) > 16384 {
		return nil, errors.New("invalid assistant request")
	}
	var messages []json.RawMessage
	if json.Unmarshal(request.Messages, &messages) != nil || len(messages) < 1 || len(messages) > 48 || len(messages)%2 != 1 {
		return nil, errors.New("invalid assistant conversation")
	}
	if err := ctx.Err(); err != nil {
		return nil, errors.New("assistant connection disconnected")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("assistant state unavailable")
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, errors.New("assistant state unavailable")
	}
	// The adapter's API deadline is 20 s; this bound only reaps a stuck adapter.
	ctx, cancel := context.WithTimeout(ctx, 35*time.Second)
	defer cancel()
	result, err := service(ctx, root, "assist", map[string]any{"v": 1, "operation_id": request.OperationID,
		"request_id": request.RequestID, "host_id": request.HostID, "context": request.Context, "messages": request.Messages})
	if err == nil {
		var rejected struct {
			Version     int    `json:"v"`
			Status      string `json:"status"`
			Code        string `json:"code"`
			OperationID string `json:"operation_id"`
		}
		// Pre-submission refusals have no journal row; bind them to this request.
		if json.Unmarshal(result, &rejected) == nil && rejected.Version == 1 && rejected.Status == "failed" && rejected.OperationID == "" {
			switch rejected.Code {
			case "spending_limit", "assistant_daily_limit", "assistant_health_reserve", "assistant_request_step_limit", "text_backend_disabled", "reconciliation_required",
				"health_api_account_required", "no_ready_account":
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
