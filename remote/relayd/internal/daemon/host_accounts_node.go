package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"time"
)

// Host accounts are user settings shared by all workers on this execution host.
// The authenticated node connection owns this route; no pane, PTY controller,
// input lease or supervisor upgrade is needed. Native session controls retain
// their separate worker admission checks.
func HandleNodeHostAccountsRequest(ctx context.Context, data []byte) ([]byte, error) {
	return handleNodeHostAccountsRequest(ctx, data, serveHostAccountSettings)
}

func handleNodeHostAccountsRequest(ctx context.Context, data []byte,
	service func(context.Context, hostRotationRequest, *string) (json.RawMessage, error)) ([]byte, error) {
	if len(data) > 66<<10 || !rotationSourceJSONUnambiguous(data) {
		return nil, errors.New("bounded host account envelope required")
	}
	var envelope struct {
		RequestID string `json:"request_id"`
		Operation string `json:"operation"`
		Forward   *struct {
			Request                 json.RawMessage `json:"request"`
			ExpectedConfigurationID *string         `json:"expected_configuration_id,omitempty"`
		} `json:"host_accounts"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&envelope) != nil || !validSessionID.MatchString(envelope.RequestID) ||
		envelope.Operation != "host_accounts" || envelope.Forward == nil {
		return nil, errors.New("invalid host account envelope")
	}
	request, err := decodeHostRotationRequest(envelope.Forward.Request)
	if err != nil || !strings.HasPrefix(request.Operation, "text_") {
		return nil, errors.New("invalid host account request")
	}
	expected := envelope.Forward.ExpectedConfigurationID
	if request.Operation == "text_configure" {
		if expected == nil || (*expected != "" && !validPromptEditorID(*expected)) {
			return nil, errors.New("read host settings before saving")
		}
	} else if expected != nil {
		return nil, errors.New("configuration identity is only valid for settings saves")
	}
	if request.Operation == "text_credential_save" {
		if len(request.CredentialSecret) < 16 || len(request.CredentialSecret) > 512 {
			return nil, errors.New("invalid API credential")
		}
		for _, c := range []byte(request.CredentialSecret) {
			if c <= 32 || c >= 127 {
				return nil, errors.New("invalid API credential")
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, errors.New("account connection disconnected")
	}
	result, err := service(ctx, request, expected)
	response := map[string]any{"request_id": envelope.RequestID, "result": result}
	if err != nil {
		response["error"] = err.Error()
	}
	return json.Marshal(response)
}

func serveHostAccountSettings(ctx context.Context, request hostRotationRequest, expected *string) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, errors.New("account connection disconnected")
	}
	root := defaultWorkerStateDir()
	// Settings may be the first client on a host; creating account state must
	// not depend on ever opening a terminal worker.
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("host account state directory unavailable")
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, errors.New("host account state directory unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if strings.HasPrefix(request.Operation, "text_credential_") {
		operation := strings.TrimPrefix(request.Operation, "text_credential_")
		return hostRotationCredentialIndexService(ctx, root, operation,
			request.CredentialReference, request.CredentialAccountID, request.CredentialSecret)
	}
	operation := strings.TrimPrefix(request.Operation, "text_")
	arguments := map[string]any{"operation_id": request.TextOperationID}
	if operation == "configure" {
		if expected == nil {
			return nil, errors.New("read host settings before saving")
		}
		arguments = map[string]any{"operation_id": request.ID, "settings": request.TextSettings, "expected_configuration_id": *expected}
	}
	result, err := hostRotationTextService(ctx, root, operation, arguments)
	if err != nil {
		return nil, err
	}
	if operation == "status" || operation == "configure" {
		var status map[string]json.RawMessage
		if json.Unmarshal(result, &status) != nil || status == nil {
			return nil, errors.New("invalid host account status")
		}
		status["credential_support"] = json.RawMessage(`"v1"`)
		return json.Marshal(status)
	}
	return result, nil
}
