package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func paneHealthEnvelope(request map[string]any) []byte {
	data, _ := json.Marshal(map[string]any{"request_id": "health-check", "operation": "host_accounts",
		"host_accounts": map[string]any{"request": request}})
	return data
}

func TestPaneHealthNodeUsesJournaledServiceWithoutTerminalAuthority(t *testing.T) {
	request := map[string]any{"v": 1, "operation": "pane_health_step", "operation_id": strings.Repeat("1", 32),
		"host_id": "config:host", "snapshot_id": strings.Repeat("a", 64),
		"panes": []any{map[string]any{"pane_id": "test"}}, "messages": []any{}}
	called := 0
	service := func(ctx context.Context, root, operation string, args any) (json.RawMessage, error) {
		called++
		if operation != "assess" || ctx.Err() != nil {
			t.Fatalf("wrong service: %s", operation)
		}
		value := args.(map[string]any)
		if value["host_id"] != "config:host" || value["operation_id"] != strings.Repeat("1", 32) {
			t.Fatalf("lost captured identity: %#v", value)
		}
		return json.RawMessage(`{"v":1,"status":"complete"}`), nil
	}
	data := paneHealthEnvelope(request)
	if !nodePaneHealthEnvelope(data) {
		t.Fatal("health capability was not recognized")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := handleNodePaneHealthRequest(context.Background(), data, root, service); err != nil {
		t.Fatal(err)
	}
	if called != 1 {
		t.Fatalf("service called %d times", called)
	}
}

func TestPaneHealthNodeRejectsAmbiguousAndActionBearingEnvelopesBeforeService(t *testing.T) {
	base := map[string]any{"v": 1, "operation": "pane_health_status", "operation_id": strings.Repeat("1", 32)}
	cases := [][]byte{[]byte(`{"request_id":"health-check","request_id":"other","operation":"host_accounts","host_accounts":{"request":{"v":1,"operation":"pane_health_status","operation_id":"11111111111111111111111111111111"}}}`)}
	for key, value := range map[string]any{"command": "arbitrary", "credential_secret": "never", "host_id": "another-host", "panes": []any{}} {
		r := map[string]any{}
		for k, v := range base {
			r[k] = v
		}
		r[key] = value
		cases = append(cases, paneHealthEnvelope(r))
	}
	for _, data := range cases {
		called := false
		_, err := handleNodePaneHealthRequest(context.Background(), data, t.TempDir(),
			func(context.Context, string, string, any) (json.RawMessage, error) { called = true; return nil, nil })
		if err == nil || called {
			t.Fatalf("invalid envelope reached service: %s", data)
		}
	}
}

func TestPaneHealthNodeCancellationCannotStartARequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	data := paneHealthEnvelope(map[string]any{"v": 1, "operation": "pane_health_status", "operation_id": strings.Repeat("1", 32)})
	called := false
	_, err := handleNodePaneHealthRequest(ctx, data, t.TempDir(),
		func(context.Context, string, string, any) (json.RawMessage, error) { called = true; return nil, nil })
	if err == nil || called {
		t.Fatal("cancelled operation reached service")
	}
}

func TestPaneHealthSerialInspectionsFitNativePassButRemainBounded(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	for _, count := range []int{24, 25, 26} {
		messages := make([]any, count)
		for i := range messages {
			messages[i] = map[string]any{"role": "unit-test"}
		}
		request := map[string]any{"v": 1, "operation": "pane_health_step", "operation_id": strings.Repeat("1", 32),
			"host_id": "config:host", "snapshot_id": strings.Repeat("a", 64),
			"panes": []any{map[string]any{"pane_id": "test"}}, "messages": messages}
		called := false
		_, err := handleNodePaneHealthRequest(context.Background(), paneHealthEnvelope(request), root,
			func(context.Context, string, string, any) (json.RawMessage, error) {
				called = true
				return json.RawMessage(`{"v":1,"status":"complete"}`), nil
			})
		if count == 24 && (err != nil || !called) {
			t.Fatalf("serial pass was rejected: %v", err)
		}
		if count != 24 && (err == nil || called) {
			t.Fatalf("unbounded conversation was admitted: %d", count)
		}
	}
}

func TestPaneHealthPreflightBudgetRefusalKeepsRequestIdentityWithoutInventingAReceipt(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	request := map[string]any{"v": 1, "operation": "pane_health_step", "operation_id": strings.Repeat("1", 32),
		"host_id": "config:host", "snapshot_id": strings.Repeat("a", 64), "panes": []any{map[string]any{"pane_id": "test"}}, "messages": []any{}}
	for _, code := range []string{"spending_limit", "reconciliation_required", "no_ready_account", "journal_or_backend_unavailable"} {
		data, err := handleNodePaneHealthRequest(context.Background(), paneHealthEnvelope(request), root,
			func(context.Context, string, string, any) (json.RawMessage, error) {
				result, _ := json.Marshal(map[string]any{"v": 1, "status": "failed", "code": code})
				return result, nil
			})
		if err != nil {
			t.Fatal(err)
		}
		var envelope struct {
			Result map[string]any `json:"result"`
		}
		if json.Unmarshal(data, &envelope) != nil {
			t.Fatal("invalid response")
		}
		if code == "journal_or_backend_unavailable" {
			if envelope.Result["status"] != "failed" || envelope.Result["operation_id"] != nil {
				t.Fatal("unknown outcome was declared unsubmitted")
			}
		} else if envelope.Result["status"] != "refused" || envelope.Result["operation_id"] != request["operation_id"] || envelope.Result["code"] != code {
			t.Fatalf("preflight refusal lost request identity: %#v", envelope.Result)
		}
	}
}
