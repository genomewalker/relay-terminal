package agentaccounts

import (
	"fmt"
	"os"
	"reflect"
	"strings"
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
		{Name: "seven_day_scoped", UsedPercent: 5, ResetsAt: "2026-11-14T09:00:00Z", WindowMinutes: 10080},
	}
	if reason != "" || !reflect.DeepEqual(windows, want) {
		t.Fatalf("windows %+v, reason %q; want %+v", windows, reason, want)
	}
}

// model_scoped becomes one seven_day_scoped window: the most-used entry
// (later reset on a tie); entries without a percentage are skipped; an
// invalid entry or shape refuses the answer.
func TestClaudeUsageModelScopedWindow(t *testing.T) {
	base := `{"type":"control_response","response":{"subtype":"success","request_id":"u","response":{"rate_limits_available":true,` +
		`"rate_limits":{"five_hour":{"utilization":1,"resets_at":"2026-11-09T12:00:00Z"},"seven_day":{"utilization":2,"resets_at":"2026-11-14T09:00:00Z"}`
	answer := func(scoped string) string {
		if scoped == "" {
			return base + `}}}}`
		}
		return base + `,"model_scoped":` + scoped + `}}}}`
	}
	entry := func(name string, used any, reset string) string {
		return fmt.Sprintf(`{"display_name":%q,"utilization":%v,"resets_at":%q}`, name, used, reset)
	}
	for _, c := range []struct {
		scoped string
		want   *UsageWindow
	}{
		{"", nil},
		{"null", nil},
		{"[]", nil},
		{"[" + entry("Fable", "null", "2026-11-14T09:00:00Z") + "]", nil},
		{"[" + entry("Fable", 97, "2026-11-14T09:00:00Z") + "," + entry("Other", 40, "2026-11-15T09:00:00Z") + "]",
			&UsageWindow{Name: "seven_day_scoped", UsedPercent: 97, ResetsAt: "2026-11-14T09:00:00Z", WindowMinutes: 10080}},
		{"[" + entry("A", 50, "2026-11-14T09:00:00Z") + "," + entry("B", 50, "2026-11-16T09:00:00Z") + "," + entry("C", "null", "x") + "]",
			&UsageWindow{Name: "seven_day_scoped", UsedPercent: 50, ResetsAt: "2026-11-16T09:00:00Z", WindowMinutes: 10080}},
	} {
		windows, reason := parseClaudeUsage([]byte(answer(c.scoped)))
		if reason != "" || len(windows) < 2 {
			t.Fatalf("%s: refused: %q", c.scoped, reason)
		}
		var got *UsageWindow
		if len(windows) == 3 {
			got = &windows[2]
		}
		if !reflect.DeepEqual(got, c.want) || len(windows) > 3 {
			t.Fatalf("%s: windows %+v, want scoped %+v", c.scoped, windows, c.want)
		}
	}
	many := make([]string, 33)
	for i := range many {
		many[i] = entry("M", 1, "2026-11-14T09:00:00Z")
	}
	for _, scoped := range []string{
		`{}`, `"x"`, `[1]`, "[" + strings.Join(many, ",") + "]",
		"[" + entry("Fable", 101, "2026-11-14T09:00:00Z") + "]",
		"[" + entry("Fable", 5, "not a time") + "]",
		`[{"utilization":5,"used_percentage":6,"resets_at":"2026-11-14T09:00:00Z"}]`,
	} {
		if windows, reason := parseClaudeUsage([]byte(answer(scoped))); len(windows) != 0 || reason == "" {
			t.Fatalf("%s accepted: %+v", scoped, windows)
		}
	}
}
