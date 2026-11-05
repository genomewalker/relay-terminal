package helpercli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestHostSettingsPreserveMoneyAndUseNativeCAS(t *testing.T) {
	var calls []map[string]any
	settings := map[string]any{"enabled": true, "max_requests_per_day": json.Number("100"), "daily_limit_microusd": json.Number("100000000"), "monthly_limit_microusd": json.Number("100000000")}
	deps := SettingsDependencies{
		UUID:     func() (string, error) { return "ca611104-0000-4000-8000-000000003999", nil },
		ReadFile: func(string) ([]byte, error) { return nil, errors.New("unexpected read") },
		NativeRequest: func(_ context.Context, host string, request map[string]any) (map[string]any, error) {
			if host != "This Mac" {
				t.Fatal(host)
			}
			calls = append(calls, request)
			if len(calls) == 1 {
				return map[string]any{"configuration_id": "before", "settings": settings}, nil
			}
			forward := request["host_accounts"].(map[string]any)
			if forward["expected_configuration_id"] != "before" {
				t.Fatal(forward)
			}
			body := forward["request"].(map[string]any)
			if body["id"] != "ca611104000040008000000000003999" {
				t.Fatal(body)
			}
			after := body["text_settings"].(map[string]any)
			if after["max_requests_per_day"] != json.Number("300") || after["daily_limit_microusd"] != settings["daily_limit_microusd"] || after["monthly_limit_microusd"] != settings["monthly_limit_microusd"] {
				t.Fatal(after)
			}
			return map[string]any{"configuration_id": body["id"], "settings": after}, nil
		}}
	var out, errout bytes.Buffer
	if err := RunHostSettings(context.Background(), []string{"This Mac", "text", "set", "max_requests_per_day", "300"}, &out, &errout, deps); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || !strings.Contains(errout.String(), "ca611104000040008000000000003999") {
		t.Fatal(calls, errout.String())
	}
	if settings["max_requests_per_day"] != json.Number("100") {
		t.Fatal("read snapshot mutated")
	}
}

func TestHostSettingsRejectsUnsafeHostStaleRevisionAndDuplicateJSON(t *testing.T) {
	for _, args := range [][]string{
		{"-oProxyCommand=bad", "text", "get"},
		{"This Mac", "text", "set", "enabled", "false", "--expected-revision", "stale"},
		{"This Mac", "text", "update", "--file", "duplicate"},
	} {
		mutations := 0
		deps := SettingsDependencies{UUID: func() (string, error) { return "ca611104-0000-4000-8000-000000003999", nil },
			ReadFile: func(string) ([]byte, error) { return []byte(`{"enabled":true,"enabled":false}`), nil },
			NativeRequest: func(_ context.Context, _ string, r map[string]any) (map[string]any, error) {
				f := r["host_accounts"].(map[string]any)
				q := f["request"].(map[string]any)
				if q["operation"] != "text_status" {
					mutations++
				}
				return map[string]any{"configuration_id": "current", "settings": map[string]any{"enabled": true}}, nil
			}}
		if err := RunHostSettings(context.Background(), args, &bytes.Buffer{}, &bytes.Buffer{}, deps); err == nil {
			t.Fatal(args)
		}
		if mutations != 0 {
			t.Fatal("rejected input dispatched mutation", args)
		}
	}
}

func TestHostCapacitySettingsUseNativeRevision(t *testing.T) {
	calls := 0
	deps := SettingsDependencies{UUID: func() (string, error) { return "ca611104-0000-4000-8000-000000003999", nil },
		ReadFile: func(string) ([]byte, error) { return nil, errors.New("unexpected file") },
		NativeRequest: func(_ context.Context, _ string, r map[string]any) (map[string]any, error) {
			calls++
			f := r["host_accounts"].(map[string]any)
			q := f["request"].(map[string]any)
			if calls == 1 {
				if q["operation"] != "capacity_status" {
					t.Fatal(q)
				}
				return map[string]any{"revision": json.Number("3"), "settings": map[string]any{"context_enabled": false}}, nil
			}
			if _, ok := f["expected_configuration_id"]; ok {
				t.Fatal("text identity sent to capacity")
			}
			if q["operation"] != "capacity_configure" || q["expected_revision"] != json.Number("3") || q["settings"].(map[string]any)["context_enabled"] != true {
				t.Fatal(q)
			}
			return map[string]any{"revision": json.Number("4")}, nil
		}}
	if err := RunHostSettings(context.Background(), []string{"local", "capacity", "set", "context_enabled", "true"}, &bytes.Buffer{}, &bytes.Buffer{}, deps); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatal(calls)
	}
}

func TestHostAccountConfigurationKeepsNativeAdmission(t *testing.T) {
	for _, action := range []string{"set_defaults", "remove"} {
		calls := 0
		deps := SettingsDependencies{UUID: func() (string, error) { return "ca611104-0000-4000-8000-000000003999", nil },
			ReadFile: func(string) ([]byte, error) {
				return []byte("{\"action\":\"" + action + "\",\"provider\":\"claude\",\"label\":\"business\"}"), nil
			},
			NativeRequest: func(_ context.Context, _ string, r map[string]any) (map[string]any, error) {
				calls++
				if r["operation"] != "agent_accounts" || r["agent_accounts"].(map[string]any)["action"] != action {
					t.Fatal(r)
				}
				return map[string]any{"accounts": []any{}}, nil
			}}
		err := RunHostSettings(context.Background(), []string{"local", "accounts", "request", "--file", "account.json"}, &bytes.Buffer{}, &bytes.Buffer{}, deps)
		if (err == nil) != (action == "set_defaults") {
			t.Fatal(action, err)
		}
		if (calls == 1) != (action == "set_defaults") {
			t.Fatal(action, calls)
		}
	}
}
