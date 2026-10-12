package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func accountEnvelope(t *testing.T, request map[string]any) []byte {
	t.Helper()
	forward := map[string]any{"request": request}
	if request["operation"] == "text_configure" {
		forward["expected_configuration_id"] = ""
	}
	data, err := json.Marshal(map[string]any{"request_id": "account-test", "operation": "host_accounts", "host_accounts": forward})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestHostAccountsSupportsOnlyBoundedSettingsOperations(t *testing.T) {
	id := strings.Repeat("a", 32)
	requests := []map[string]any{
		{"v": 1, "operation": "text_status"},
		{"v": 1, "operation": "text_status", "text_operation_id": id},
		{"v": 1, "operation": "text_configure", "id": id, "text_settings": map[string]any{"enabled": false}},
		{"v": 1, "operation": "text_abandon", "text_operation_id": id},
		{"v": 1, "operation": "text_credential_list"},
		{"v": 1, "operation": "text_credential_save", "credential_reference": id, "credential_account_id": id, "credential_secret": "DISPOSABLE_TEST_KEY"},
		{"v": 1, "operation": "text_credential_status", "credential_reference": id},
		{"v": 1, "operation": "text_credential_delete", "credential_reference": id},
	}
	for _, request := range requests {
		t.Run(request["operation"].(string), func(t *testing.T) {
			calls := 0
			response, err := handleNodeHostAccountsRequest(context.Background(), accountEnvelope(t, request),
				func(_ context.Context, got hostRotationRequest, _ *string) (json.RawMessage, error) {
					calls++
					if got.Operation != request["operation"] || got.SessionID != "" || got.Client != "" || got.AgentPID != 0 {
						t.Fatal("wrong host scope")
					}
					return json.RawMessage(`{"v":1,"generation":18446744073709551614}`), nil
				})
			if err != nil || calls != 1 {
				t.Fatal("host operation did not dispatch", err, calls)
			}
			var result map[string]json.RawMessage
			if json.Unmarshal(response, &result) != nil || string(result["request_id"]) != "\"account-test\"" || !strings.Contains(string(result["result"]), "18446744073709551614") {
				t.Fatal("response identity or precision changed")
			}
		})
	}
}
func TestHostAccountsRejectsSessionAuthorityAndAmbiguousInputs(t *testing.T) {
	id := strings.Repeat("b", 32)
	requests := []map[string]any{
		{"v": 1, "operation": "status"},
		{"v": 1, "operation": "enroll", "id": id, "session_id": "pane", "client": "codex", "cwd": "/tmp", "agent_pid": 99, "agent_start": 1},
		{"v": 1, "operation": "disable", "id": id},
		{"v": 1, "operation": "text_submit"},
		{"v": 1, "operation": "text_status", "session_id": "pane"},
		{"v": 1, "operation": "text_credential_read", "credential_reference": id},
		{"v": 1, "operation": "text_credential_save", "credential_reference": id, "credential_account_id": id, "credential_secret": "short"},
		{"v": 1, "operation": "text_credential_save", "credential_reference": id, "credential_account_id": id, "credential_secret": "invalid key contains spaces"},
	}
	calls := 0
	service := func(context.Context, hostRotationRequest, *string) (json.RawMessage, error) { calls++; return nil, nil }
	for _, request := range requests {
		if _, err := handleNodeHostAccountsRequest(context.Background(), accountEnvelope(t, request), service); err == nil {
			t.Fatal("invalid request dispatched", request["operation"])
		}
	}
	extras := [][]byte{
		[]byte(`{"request_id":"x","operation":"host_accounts","pane_id":"pane","host_accounts":{"request":{"v":1,"operation":"text_status"}}}`),
		[]byte(`{"request_id":"x","operation":"host_accounts","host_accounts":{"client_id":"caller","request":{"v":1,"operation":"text_status"}}}`),
		[]byte(`{"request_id":"x","operation":"host_accounts","host_accounts":{"request":{"v":1,"v":1,"operation":"text_status"}}}`),
		[]byte(strings.Repeat("x", 67<<10)),
	}
	for _, data := range extras {
		if _, err := handleNodeHostAccountsRequest(context.Background(), data, service); err == nil {
			t.Fatal("invalid envelope dispatched")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := handleNodeHostAccountsRequest(ctx, accountEnvelope(t, map[string]any{"v": 1, "operation": "text_status"}), service); err == nil {
		t.Fatal("disconnected request dispatched")
	}
	if calls != 0 {
		t.Fatal("invalid request called service")
	}
}
func TestHostAccountsFailureKeepsRequestIdentity(t *testing.T) {
	data := accountEnvelope(t, map[string]any{"v": 1, "operation": "text_status"})
	response, err := handleNodeHostAccountsRequest(context.Background(), data, func(context.Context, hostRotationRequest, *string) (json.RawMessage, error) {
		return nil, errors.New("owned fixture failure")
	})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if json.Unmarshal(response, &value) != nil || value["request_id"] != "account-test" || value["error"] != "owned fixture failure" || value["result"] != nil {
		t.Fatal("failure receipt changed")
	}
}

func TestHostAccountsRequiresCurrentConfigurationIdentityForSaves(t *testing.T) {
	id := strings.Repeat("c", 32)
	request := map[string]any{"v": 1, "operation": "text_configure", "id": id, "text_settings": map[string]any{"enabled": false}}
	encode := func(expected any, include bool, request map[string]any) []byte {
		forward := map[string]any{"request": request}
		if include {
			forward["expected_configuration_id"] = expected
		}
		data, err := json.Marshal(map[string]any{"request_id": "account-cas", "operation": "host_accounts", "host_accounts": forward})
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	calls := 0
	service := func(_ context.Context, got hostRotationRequest, expected *string) (json.RawMessage, error) {
		calls++
		if got.Operation != "text_configure" || expected == nil || (*expected != "" && *expected != id) {
			t.Fatal("configuration identity changed")
		}
		return json.RawMessage(`{"v":1}`), nil
	}
	for _, expected := range []any{"", id} {
		if _, err := handleNodeHostAccountsRequest(context.Background(), encode(expected, true, request), service); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 2 {
		t.Fatal("valid save did not dispatch")
	}
	invalid := [][]byte{
		encode(nil, false, request), encode(nil, true, request), encode("invalid", true, request), encode(17, true, request),
		encode(id, true, map[string]any{"v": 1, "operation": "text_status"}),
	}
	for _, data := range invalid {
		if _, err := handleNodeHostAccountsRequest(context.Background(), data, service); err == nil {
			t.Fatal("stale or malformed save admitted")
		}
	}
	if calls != 2 {
		t.Fatal("invalid configuration identity reached service")
	}
}

func TestHostAccountsBootstrapsPrivateStateWithoutTerminalWorker(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := defaultWorkerStateDir()
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("fixture state already exists", err)
	}
	result, err := serveHostAccountSettings(context.Background(), hostRotationRequest{Version: 1, Operation: "text_credential_list"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var receipt struct {
		Status  string            `json:"status"`
		Entries []json.RawMessage `json:"entries"`
	}
	if json.Unmarshal(result, &receipt) != nil || receipt.Status != "ready" || len(receipt.Entries) != 0 {
		t.Fatal("fresh host credential list unavailable")
	}
	info, err := os.Stat(root)
	if err != nil || info.Mode().Perm() != 0700 {
		t.Fatal("host state is not private", err)
	}
	workers, err := filepath.Glob(filepath.Join(root, "*.json"))
	if err != nil || len(workers) != 0 {
		t.Fatal("Settings created a terminal worker record")
	}
}
func TestHostAccountsRefusesNonPrivateExistingState(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := defaultWorkerStateDir()
	if err := os.MkdirAll(root, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := serveHostAccountSettings(context.Background(), hostRotationRequest{Version: 1, Operation: "text_credential_list"}, nil); err == nil {
		t.Fatal("unsafe existing state accepted")
	}
	info, err := os.Stat(root)
	if err != nil || info.Mode().Perm() != 0755 {
		t.Fatal("existing directory permissions changed")
	}
}
