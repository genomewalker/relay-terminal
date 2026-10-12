package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestNodeHostRotationEnvelopeForwardsExactWorkerRequest(t *testing.T) {
	input := []byte(`{"request_id":"rpc-native-api","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":{"v":1,"operation":"text_status"}}}`)
	calls := 0
	output, err := handleNodeHostRotationRequest(context.Background(), input,
		func(pane, client string, request json.RawMessage) (json.RawMessage, error) {
			calls++
			if pane != "pane" || client != "client" || string(request) != `{"v":1,"operation":"text_status"}` {
				t.Fatal("worker identity or request changed")
			}
			return json.RawMessage(`{"v":1,"status":"not_configured","credential_support":"v1"}`), nil
		})
	if err != nil || calls != 1 {
		t.Fatalf("forward: %s, %v, calls %d", output, err, calls)
	}
	var value struct {
		RequestID string         `json:"request_id"`
		Result    map[string]any `json:"result"`
	}
	if json.Unmarshal(output, &value) != nil || value.RequestID != "rpc-native-api" || value.Result["credential_support"] != "v1" {
		t.Fatal("app envelope changed", string(output))
	}
}

func TestNodeHostRotationInvalidAndDisconnectedRequestsNeverDispatch(t *testing.T) {
	cases := []string{
		`{}`,
		`{"request_id":"rpc","operation":"exec","host_rotation":{"pane_id":"pane","client_id":"client","request":{}}}`,
		`{"request_id":"bad id","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":{}}}`,
		`{"request_id":"rpc","operation":"host_rotation","host_rotation":{"pane_id":"../pane","client_id":"client","request":{}}}`,
		`{"request_id":"rpc","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"","request":{}}}`,
		`{"request_id":"rpc","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":null}}`,
		strings.Repeat("x", 67<<10),
	}
	call := func(string, string, json.RawMessage) (json.RawMessage, error) {
		t.Fatal("invalid request dispatched")
		return nil, nil
	}
	for _, input := range cases {
		if _, err := handleNodeHostRotationRequest(context.Background(), []byte(input), call); err == nil {
			t.Fatal("invalid request accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	good := []byte(`{"request_id":"rpc","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":{}}}`)
	if _, err := handleNodeHostRotationRequest(ctx, good, call); err == nil {
		t.Fatal("disconnected request accepted")
	}
}

func TestNodeHostRotationWorkerFailureKeepsRequestIdentity(t *testing.T) {
	input := []byte(`{"request_id":"rpc","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":{}}}`)
	output, err := handleNodeHostRotationRequest(context.Background(), input, func(string, string, json.RawMessage) (json.RawMessage, error) {
		return nil, errors.New("worker unavailable")
	})
	if err != nil || !strings.Contains(string(output), `"request_id":"rpc"`) || !strings.Contains(string(output), `"error":"worker unavailable"`) {
		t.Fatal("failure envelope", string(output), err)
	}
}
