package daemon

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestNodeAssistantStepRoutesOnlyBoundedRequests(t *testing.T) {
	root := filepath.Join(t.TempDir(), "workers")
	var seenOperation string
	var seenArgs map[string]any
	service := func(_ context.Context, _ string, operation string, args any) (json.RawMessage, error) {
		seenOperation = operation
		seenArgs = args.(map[string]any)
		return json.RawMessage(`{"v":1,"status":"failed","code":"assistant_daily_limit"}`), nil
	}
	envelope := func(request map[string]any) []byte {
		data, _ := json.Marshal(map[string]any{"request_id": "rpc-1", "operation": "host_accounts",
			"host_accounts": map[string]any{"request": request}})
		return data
	}
	valid := map[string]any{"v": 1, "operation": "assistant_step", "operation_id": "0123456789abcdef0123456789abcdef",
		"request_id": "fedcba9876543210fedcba9876543210",
		"host_id":    "host-1", "context": `{"panes":[]}`, "messages": []any{map[string]any{"role": "user", "content": "hi"}}}
	data := envelope(valid)
	if !nodeAssistantEnvelope(data) || nodePaneHealthEnvelope(data) {
		t.Fatal("assistant envelope was not routed separately from pane health")
	}
	raw, err := handleNodeAssistantRequest(context.Background(), data, root, service)
	if err != nil || seenOperation != "assist" || seenArgs["host_id"] != "host-1" ||
		seenArgs["request_id"] != "fedcba9876543210fedcba9876543210" {
		t.Fatalf("assistant step was not forwarded: %v %s", err, seenOperation)
	}
	var response struct {
		Result map[string]any `json:"result"`
	}
	if json.Unmarshal(raw, &response) != nil || response.Result["status"] != "refused" ||
		response.Result["code"] != "assistant_daily_limit" {
		t.Fatalf("pre-submission refusal was not bound to the request: %s", raw)
	}
	for _, mutate := range []func(map[string]any){
		func(r map[string]any) { r["operation"] = "assistant_change" },
		func(r map[string]any) { r["operation_id"] = "not-an-id" },
		func(r map[string]any) { delete(r, "request_id") },
		func(r map[string]any) { r["messages"] = []any{} },
		func(r map[string]any) { r["tools"] = []any{map[string]any{"name": "send_command"}} },
	} {
		bad := map[string]any{}
		for k, v := range valid {
			bad[k] = v
		}
		mutate(bad)
		seenOperation = ""
		if _, err := handleNodeAssistantRequest(context.Background(), envelope(bad), root, service); err == nil || seenOperation != "" {
			t.Fatalf("invalid assistant request was forwarded: %v", bad)
		}
	}
}
