package daemon

import (
	"context"
	"encoding/json"
	"errors"
)

// HandleNodeHostRotationRequest forwards the app's ephemeral control request
// directly from the installed node client to its exact existing worker. It is
// independent of the retained supervisor's host RPC vocabulary. Credentials
// never become host jobs, files, logs or replayable node requests.
func HandleNodeHostRotationRequest(ctx context.Context, data []byte) ([]byte, error) {
	return handleNodeHostRotationRequest(ctx, data, CallHostRotation)
}

func handleNodeHostRotationRequest(ctx context.Context, data []byte,
	call func(string, string, json.RawMessage) (json.RawMessage, error)) ([]byte, error) {
	if len(data) > 66<<10 {
		return nil, errors.New("bounded host rotation envelope required")
	}
	var request struct {
		RequestID string                  `json:"request_id"`
		Operation string                  `json:"operation"`
		Forward   *hostRotationRPCRequest `json:"host_rotation"`
	}
	if json.Unmarshal(data, &request) != nil || !validSessionID.MatchString(request.RequestID) ||
		request.Operation != "host_rotation" || request.Forward == nil ||
		!validSessionID.MatchString(request.Forward.PaneID) ||
		!validSessionID.MatchString(request.Forward.ClientID) ||
		len(request.Forward.Request) == 0 || len(request.Forward.Request) > 65536 {
		return nil, errors.New("invalid host rotation envelope")
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(request.Forward.Request, &body) != nil || body == nil {
		return nil, errors.New("invalid worker request object")
	}
	if err := ctx.Err(); err != nil {
		return nil, errors.New("node request disconnected")
	}
	result, err := call(request.Forward.PaneID, request.Forward.ClientID, request.Forward.Request)
	response := map[string]any{"request_id": request.RequestID, "result": result}
	if err != nil {
		response["error"] = err.Error()
	}
	return json.Marshal(response)
}
