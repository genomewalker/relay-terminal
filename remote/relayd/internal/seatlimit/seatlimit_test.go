package seatlimit

import (
	"strings"
	"testing"
	"time"
)

// Rows shaped like real Claude Code 2.1.3xx transcripts (2026-10-27,
// 2026-11-03), trimmed to the fields Claude writes for a 429 refusal.
func refusal(uuid, at, text, info string) string {
	params := ""
	if info != "" {
		params = `"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":` + info + `},`
	}
	return `{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"` + uuid + `","timestamp":"` + at +
		`","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"` + text +
		`"}]},` + params + `"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"sessionId":"s1"}`
}

const ok = `{"type":"assistant","isSidechain":false,"uuid":"a2","timestamp":"2026-11-20T10:00:00Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}`

func TestFiveHourText(t *testing.T) {
	// No rate_limit_info: the text alone classifies the window and its reset.
	event := Parse([]byte(refusal("u1", "2026-11-20T12:00:00.000Z", "You've hit your 5-hour limit · resets 3:10pm (Europe/Copenhagen)", "")))
	if event == nil || event.Kind != "five_hour" || event.Model != "" {
		t.Fatalf("five-hour: %+v", event)
	}
	want := time.Date(2026, 11, 20, 15, 10, 0, 0, mustZone(t)).Unix()
	if event.ResetsAt != want {
		t.Fatalf("reset %d, want %d", event.ResetsAt, want)
	}
	if session := Parse([]byte(refusal("u1", "2026-11-20T12:00:00.000Z", "You've hit your session limit · resets 12:30pm (Europe/Copenhagen)", ""))); session == nil || session.Kind != "five_hour" {
		t.Fatalf("session limit text: %+v", session)
	}
}

func TestWeeklyTextBothDateForms(t *testing.T) {
	for _, text := range []string{
		"You've hit your weekly limit · resets Nov 22, 9am (Europe/Copenhagen)",
		"You've hit your weekly limit · resets Nov 22 at 9am (Europe/Copenhagen)",
	} {
		event := Parse([]byte(refusal("u2", "2026-11-18T08:00:00Z", text, "")))
		if event == nil || event.Kind != "seven_day" {
			t.Fatalf("%q: %+v", text, event)
		}
		if want := time.Date(2026, 11, 22, 9, 0, 0, 0, mustZone(t)).Unix(); event.ResetsAt != want {
			t.Fatalf("%q reset %d, want %d", text, event.ResetsAt, want)
		}
	}
}

func TestModelLimitText(t *testing.T) {
	event := Parse([]byte(refusal("u3", "2026-11-20T12:00:00Z", "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model.", "")))
	if event == nil || event.Kind != "model" || event.Model != "Fable" || event.ResetsAt != 0 {
		t.Fatalf("model limit: %+v", event)
	}
}

func TestRateLimitInfoWins(t *testing.T) {
	info := `{"status":"rejected","resetsAt":1793836800,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"org_level_disabled"}`
	event := Parse([]byte(refusal("u4", "2026-11-03T21:05:15.651Z", "You've hit your weekly limit · resets Nov 5 at 1am (Europe/Copenhagen)", info)))
	if event == nil || event.Kind != "seven_day" || event.ResetsAt != 1793836800 || event.ID != "u4" || event.SessionID != "s1" {
		t.Fatalf("rate_limit_info: %+v", event)
	}
	// rate_limit_info alone (unrecognised text) still classifies.
	event = Parse([]byte(refusal("u5", "2026-11-03T21:05:15Z", "Limit reached", `{"status":"rejected","resetsAt":1793100600,"rateLimitType":"five_hour"}`)))
	if event == nil || event.Kind != "five_hour" || event.ResetsAt != 1793100600 {
		t.Fatalf("info only: %+v", event)
	}
}

func TestTransientAndOther429Ignored(t *testing.T) {
	if Parse([]byte(refusal("u6", "2026-11-20T12:00:00Z", "Too many requests, retrying", ""))) != nil {
		t.Fatal("a transient 429 is not a seat limit")
	}
	side := strings.Replace(refusal("u7", "2026-11-20T12:00:00Z", "You've hit your weekly limit · resets 9am (Europe/Copenhagen)", ""), `"isSidechain":false`, `"isSidechain":true`, 1)
	if Parse([]byte(side)) != nil {
		t.Fatal("a subagent's refusal is not the pane's")
	}
}

func TestLatestOnlyWhileCurrent(t *testing.T) {
	limited := refusal("u8", "2026-11-20T09:00:00Z", "You've hit your weekly limit · resets 9am (Europe/Copenhagen)", "")
	user := `{"type":"user","uuid":"q","message":{"content":"continue"}}`
	if event := Latest([]byte(limited + "\n" + user + "\n")); event == nil || event.ID != "u8" {
		t.Fatalf("current refusal: %+v", event)
	}
	if event := Latest([]byte(limited + "\n" + ok + "\n")); event != nil {
		t.Fatalf("a recovered conversation is not limited: %+v", event)
	}
}

func mustZone(t *testing.T) *time.Location {
	zone, err := time.LoadLocation("Europe/Copenhagen")
	if err != nil {
		t.Skip("no tz database")
	}
	return zone
}
