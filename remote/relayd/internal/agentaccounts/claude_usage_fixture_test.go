package agentaccounts

import (
	"os"
	"reflect"
	"testing"
)

// testdata/claude_get_usage_2_1_319.json is Claude Code 2.1.319's real
// get_usage control_response (2026-11-09) with the exact structure and key
// set, and synthetic values for anything about the account or its use.
func TestClaudeUsageReadsTheCurrentCLIAnswer(t *testing.T) {
	line, err := os.ReadFile("testdata/claude_get_usage_2_1_319.json")
	if err != nil {
		t.Fatal(err)
	}
	windows, reason := parseClaudeUsage(line)
	want := []UsageWindow{
		{Name: "five_hour", UsedPercent: 42, ResetsAt: "2026-11-09T12:00:00Z", WindowMinutes: 300},
		{Name: "seven_day", UsedPercent: 63, ResetsAt: "2026-11-14T09:00:00Z", WindowMinutes: 10080},
	}
	if reason != "" || !reflect.DeepEqual(windows, want) {
		t.Fatalf("windows %+v, reason %q; want %+v", windows, reason, want)
	}
}
