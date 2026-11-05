package agentaccounts

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestQuotaFailoverWindowStrict(t *testing.T) {
	for _, reset := range []string{`"2026-10-23T17:00:00Z"`, `"2026-10-23T19:00:00.123456+02:00"`, `1792774800`, `"1792774800.5"`} {
		for _, field := range []string{"utilization", "used_percentage"} {
			data := `{"` + field + `":90,"resets_at":` + reset + `}`
			window, err := parseClaudeQuotaWindow([]byte(data))
			if err != nil || window.UsedPercent != 90 || window.ResetsAt == "" {
				t.Fatalf("%s: %+v %v", data, window, err)
			}
		}
	}
	for _, data := range []string{
		`{"used_percentage":101,"resets_at":"2026-10-23T17:00:00Z"}`,
		`{"used_percentage":-1,"resets_at":"2026-10-23T17:00:00Z"}`,
		`{"used_percentage":90,"resets_at":"garbage"}`,
		`{"used_percentage":90,"resets_at":null}`,
		`{"used_percentage":90,"resets_at":true}`,
		`{"used_percentage":90,"resets_at":-1}`,
		`{"used_percentage":90,"resets_at":253402300800}`,
		`{"used_percentage":90,"resets_at":"2026-10-23T17:00:00Z","unknown":1}`,
		`{"utilization":90,"used_percentage":80,"resets_at":"2026-10-23T17:00:00Z"}`,
	} {
		if _, err := parseClaudeQuotaWindow([]byte(data)); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}

func FuzzClaudeQuotaWindow(f *testing.F) {
	for _, seed := range []string{
		`{"used_percentage":90,"resets_at":"2026-10-23T17:00:00Z"}`,
		`{"utilization":100,"resets_at":"2026-10-23T19:00:00.123456+02:00","used_dollars":12}`,
		`{"used_percentage":0,"resets_at":1792774800}`,
		`{"used_percentage":101,"resets_at":"bad"}`, `{}`, `null`, `{"used_percentage":90`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		window, err := parseClaudeQuotaWindow(data)
		if err != nil {
			return
		}
		if math.IsNaN(window.UsedPercent) || window.UsedPercent < 0 || window.UsedPercent > 100 {
			t.Fatal("out of range accepted")
		}
		reset, err := time.Parse(time.RFC3339, window.ResetsAt)
		if err != nil || reset.Unix() <= 0 {
			t.Fatal("unparsable reset accepted")
		}
		canonical, _ := json.Marshal(map[string]any{"used_percentage": window.UsedPercent, "resets_at": window.ResetsAt})
		again, err := parseClaudeQuotaWindow(canonical)
		if err != nil || again != window {
			t.Fatal("canonical round trip failed")
		}
		// Every successful input loses its closing delimiter when truncated.
		trimmed := strings.TrimSpace(string(data))
		if _, err := parseClaudeQuotaWindow([]byte(trimmed[:len(trimmed)-1])); err == nil {
			t.Fatal("truncated quota accepted")
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal(data, &fields) != nil {
			t.Fatal("accepted invalid JSON")
		}
		fields["unknown"] = json.RawMessage(`1`)
		unknown, _ := json.Marshal(fields)
		if _, err := parseClaudeQuotaWindow(unknown); err == nil {
			t.Fatal("unknown field accepted")
		}
	})
}

func FuzzClaudeQuotaEnvelope(f *testing.F) {
	for _, name := range []string{"seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette"} {
		f.Add([]byte(`{"response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1792774800},"` + name + `":{"utilization":98,"resets_at":"2026-10-30T17:00:00.123Z"}}}}}`))
	}

	f.Add([]byte(`{"response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":"2026-10-23T17:00:00Z"}}}}}`))
	f.Add([]byte(`{"response":{}}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		windows, _ := parseClaudeUsage(data)
		for _, window := range windows {
			if window.UsedPercent < 0 || window.UsedPercent > 100 || window.ResetsAt == "" {
				t.Fatal("invalid actionable window")
			}
			if _, err := time.Parse(time.RFC3339, window.ResetsAt); err != nil {
				t.Fatal("bad reset")
			}
		}
		if len(windows) > 0 {
			trimmed := strings.TrimSpace(string(data))
			if next, _ := parseClaudeUsage([]byte(trimmed[:len(trimmed)-1])); len(next) > 0 {
				t.Fatal("truncated envelope accepted")
			}
			var fields map[string]json.RawMessage
			if json.Unmarshal(data, &fields) != nil {
				t.Fatal("accepted invalid JSON")
			}
			fields["unknown"] = json.RawMessage(`true`)
			unknown, _ := json.Marshal(fields)
			if next, _ := parseClaudeUsage(unknown); len(next) > 0 {
				t.Fatal("unknown envelope field accepted")
			}
		}
	})
}

// Private homes and a fake executable only: no provider login or real config.
func TestQuotaFailoverReadUsageFakeCLI(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude-team"), 0700); err != nil {
		t.Fatal(err)
	}
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	for _, percent := range []int{90, 101} {
		body := fmt.Sprintf(`{"type":"control_response","response":{"subtype":"success","request_id":"u2","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"used_percentage":%d,"resets_at":"2026-10-23T17:00:00Z"}}}}}`, percent)
		program := filepath.Join(home, "fake-claude")
		if err := os.WriteFile(program, []byte("#!/bin/sh\nprintf '%s\\n' '"+body+"'\n"), 0700); err != nil {
			t.Fatal(err)
		}
		result := ReadUsage(home, []Account{account}, func(ctx context.Context, provider, override string) ([]byte, error) {
			if provider != "claude" || override != filepath.Join(home, ".claude-team") {
				return nil, fmt.Errorf("wrong provider account")
			}
			cmd := exec.CommandContext(ctx, program)
			cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + override}
			return cmd.Output()
		}, time.Date(2026, 10, 23, 16, 0, 0, 0, time.UTC))
		if percent == 90 {
			if result[0].Status != UsageOK || len(result[0].Windows) != 1 {
				t.Fatalf("valid fake CLI refused: %+v", result)
			}
		} else if result[0].Status == UsageOK || len(result[0].Windows) != 0 {
			t.Fatalf("invalid CLI quota admitted: %+v", result)
		}
	}
}

func TestQuotaWeeklyNamesAndFormats(t *testing.T) {
	for _, name := range []string{"seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette"} {
		for _, field := range []string{"used_percentage", "utilization"} {
			for _, reset := range []string{`"2026-10-30T17:00:00Z"`, `"2026-10-30T19:00:00.123456+02:00"`, `1793379600`, `"1793379600.5"`} {
				weekly := `{"` + field + `":98,"resets_at":` + reset + `}`
				body := `{"response":{"subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1792774800},"` + name + `":` + weekly + `}}}}`
				windows, reason := parseClaudeUsage([]byte(body))
				if reason != "" || len(windows) != 2 || windows[1].Name != name || windows[1].UsedPercent != 98 || windows[1].WindowMinutes != 10080 {
					t.Fatalf("weekly refused %s: %+v %s", body, windows, reason)
				}
				invalid := strings.Replace(body, weekly, strings.TrimSuffix(weekly, "}")+`,"unknown":1}`, 1)
				if windows, _ := parseClaudeUsage([]byte(invalid)); len(windows) != 0 {
					t.Fatal("unknown weekly authoritative field accepted")
				}
			}
		}
	}
}
