package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudeStatusCaptureRecordsOnlyCurrentRestartFields(t *testing.T) {
	const pane = "12345678-1234-4234-8234-123456789abc"
	t.Setenv("RELAY_SESSION", pane)
	home := t.TempDir()
	input := []byte(`{"session_id":"aaaaaaaa-1234-4234-8234-123456789abc","model":{"id":"claude-opus-5","display_name":"Opus"},"effort":{"level":"high"},"cwd":"/work/sub","workspace":{"project_dir":"/work"},"cost":{"total_cost_usd":4.2}}`)
	if err := captureClaudeStatus(pane, input, home); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, ".local", "share", "relay", "claude-status", pane+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got claudeLiveStatus
	if json.Unmarshal(data, &got) != nil || got.Model != "claude-opus-5" || got.Effort != "high" || got.CWD != "/work/sub" || got.Project != "/work" {
		t.Fatalf("wrong status metadata: %+v", got)
	}
	if strings.Contains(string(data), "cost") {
		t.Fatal("unrelated status data was persisted")
	}
	if err := captureClaudeStatus("other-pane", input, home); err == nil {
		t.Fatal("forged pane accepted")
	}
}

func TestClaudeQuotaWindowsAllowlistAndMissingData(t *testing.T) {
	got := claudeQuotaWindows([]byte(`{"five_hour":{"used_percentage":37.5,"resets_at":2000,"secret":"discard"},"seven_day":{"used_percentage":100},"spend_limit":{"used_percentage":45},"credentials":"discard"}`))
	if len(got) != 2 || got["five_hour"].UsedPercentage != 37.5 || got["five_hour"].ResetsAt == nil || *got["five_hour"].ResetsAt != 2000 {
		t.Fatalf("wrong quota windows: %+v", got)
	}
	data, _ := json.Marshal(got)
	if strings.Contains(string(data), "secret") || strings.Contains(string(data), "spend_limit") {
		t.Fatal("unrelated data retained")
	}
	for _, raw := range []string{`null`, `{}`, `{"five_hour":{}}`, `{"five_hour":{"used_percentage":true}}`, `{"five_hour":{"used_percentage":-1}}`, `{"five_hour":{"used_percentage":101}}`, `{"five_hour":{"used_percentage":30,"resets_at":-1}}`} {
		if len(claudeQuotaWindows([]byte(raw))) != 0 {
			t.Fatalf("invalid quota accepted: %s", raw)
		}
	}
}
