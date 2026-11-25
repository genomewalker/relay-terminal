// Package seatlimit finds a Claude seat/usage-limit refusal (HTTP 429) in the
// tail of a Claude Code transcript. Claude records each refusal as a synthetic
// assistant row with "isApiErrorMessage":true and "apiErrorStatus":429; the
// row carries apiErrorParams.rate_limit_info with the window and its reset.
// Claude fires no Stop hook for such a turn, so the transcript is the only
// signal that names the window and the reset.
package seatlimit

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

// Event is one refusal. Text is Claude's own short message, bounded.
type Event struct {
	ID        string    `json:"id"`
	At        time.Time `json:"at"`
	Kind      string    `json:"kind"`
	Model     string    `json:"model,omitempty"`
	ResetsAt  int64     `json:"resets_at,omitempty"`
	Text      string    `json:"text"`
	SessionID string    `json:"session_id,omitempty"`
}

// TailBytes bounds how much of a transcript is read per status update.
const TailBytes = 256 << 10

var validKind = regexp.MustCompile(`^[a-z0-9_]{1,40}$`)

type row struct {
	Type           string `json:"type"`
	UUID           string `json:"uuid"`
	Timestamp      string `json:"timestamp"`
	SessionID      string `json:"sessionId"`
	IsSidechain    bool   `json:"isSidechain"`
	IsAPIError     bool   `json:"isApiErrorMessage"`
	APIErrorStatus int    `json:"apiErrorStatus"`
	APIError       string `json:"apiError"`
	Error          string `json:"error"`
	APIErrorParams struct {
		RateLimitInfo *rateLimitInfo `json:"rate_limit_info"`
	} `json:"apiErrorParams"`
	QuotaLimits *rateLimitInfo `json:"quotaLimits"`
	Message     struct {
		StopReason string          `json:"stop_reason"`
		Content    json.RawMessage `json:"content"`
	} `json:"message"`
}

type rateLimitInfo struct {
	Status        string `json:"status"`
	ResetsAt      int64  `json:"resetsAt"`
	RateLimitType string `json:"rateLimitType"`
}

func text(content json.RawMessage) string {
	var plain string
	if json.Unmarshal(content, &plain) == nil {
		return plain
	}
	var blocks []struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(content, &blocks)
	parts := make([]string, 0, len(blocks))
	for _, block := range blocks {
		if block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	return strings.Join(parts, " ")
}

var (
	limitText = regexp.MustCompile(`(?i)you'?ve (hit|reached) your (.{1,40}?) limit`)
	resetText = regexp.MustCompile(`(?i)resets (?:([A-Z][a-z]{2}) (\d{1,2})(?:,| at) )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?: \(([A-Za-z_]+(?:/[A-Za-z_+\-]+)*)\))?`)
	months    = map[string]time.Month{"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
)

// Parse classifies one transcript line. It returns nil for anything but a
// main-conversation 429 usage-limit refusal.
func Parse(line []byte) *Event {
	if !bytes.Contains(line, []byte(`"apiErrorStatus":429`)) && !bytes.Contains(line, []byte(`"apiErrorStatus": 429`)) {
		return nil
	}
	var r row
	if json.Unmarshal(line, &r) != nil || r.Type != "assistant" || r.IsSidechain || !r.IsAPIError || r.APIErrorStatus != 429 {
		return nil
	}
	message := strings.Join(strings.Fields(text(r.Message.Content)), " ")
	info := r.APIErrorParams.RateLimitInfo
	if info == nil {
		info = r.QuotaLimits
	}
	words := limitText.FindStringSubmatch(message)
	// A transient 429 (overload, request rate) is not a seat limit.
	if r.APIError != "usage_limit_reached" && (info == nil || info.Status != "rejected") && words == nil {
		return nil
	}
	at, err := time.Parse(time.RFC3339Nano, r.Timestamp)
	if err != nil || r.UUID == "" || len(r.UUID) > 80 {
		return nil
	}
	event := &Event{ID: r.UUID, At: at.UTC(), Kind: "unknown", SessionID: r.SessionID}
	if len(event.SessionID) > 110 {
		event.SessionID = ""
	}
	if len(message) > 300 {
		message = message[:300]
	}
	event.Text = message
	if info != nil && validKind.MatchString(info.RateLimitType) {
		event.Kind = info.RateLimitType
	}
	if info != nil && info.ResetsAt > 0 && info.ResetsAt < 253402300800 {
		event.ResetsAt = info.ResetsAt
	}
	if words != nil {
		name := strings.TrimSpace(words[2])
		lower := strings.ToLower(name)
		switch lower {
		case "session", "5-hour", "five-hour":
			if event.Kind == "unknown" {
				event.Kind = "five_hour"
			}
		case "weekly":
			if event.Kind == "unknown" {
				event.Kind = "seven_day"
			}
		default:
			// "You've reached your Fable limit": a model-specific limit.
			// Its window type, when Claude reports one, is kept.
			if len(name) <= 40 {
				event.Model = name
			}
			if event.Kind == "unknown" {
				event.Kind = "model"
			}
		}
	}
	if event.ResetsAt == 0 {
		event.ResetsAt = ResetFromText(message, event.At)
	}
	return event
}

// ResetFromText reads "resets 3:10pm (Europe/Copenhagen)", "resets 9am (…)",
// "resets Nov 22, 9am (…)" or "resets Nov 5 at 1am (…)" as the first such
// time after `after`. 0 when the text names no usable reset.
func ResetFromText(message string, after time.Time) int64 {
	m := resetText.FindStringSubmatch(message)
	if m == nil {
		return 0
	}
	location := time.UTC
	if m[6] != "" {
		loaded, err := time.LoadLocation(m[6])
		if err != nil {
			return 0
		}
		location = loaded
	}
	hour := atoi(m[3])
	minute := atoi(m[4])
	if hour < 1 || hour > 12 || minute > 59 {
		return 0
	}
	hour %= 12
	if strings.EqualFold(m[5], "pm") {
		hour += 12
	}
	local := after.In(location)
	if m[1] != "" {
		month, ok := months[strings.ToLower(m[1])]
		day := atoi(m[2])
		if !ok || day < 1 || day > 31 {
			return 0
		}
		candidate := time.Date(local.Year(), month, day, hour, minute, 0, 0, location)
		if !candidate.After(after) {
			candidate = candidate.AddDate(1, 0, 0)
		}
		return candidate.Unix()
	}
	candidate := time.Date(local.Year(), local.Month(), local.Day(), hour, minute, 0, 0, location)
	if !candidate.After(after) {
		candidate = candidate.AddDate(0, 0, 1)
	}
	return candidate.Unix()
}

func atoi(value string) int {
	result := 0
	for _, c := range value {
		if c < '0' || c > '9' {
			return -1
		}
		result = result*10 + int(c-'0')
	}
	return result
}

// Latest returns the newest refusal in a transcript tail that is still the
// conversation's current state: no successful main-conversation assistant
// row follows it. A refusal the agent has since recovered from is not a
// current limit.
func Latest(tail []byte) *Event {
	var latest *Event
	for _, line := range bytes.Split(tail, []byte("\n")) {
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		if event := Parse(line); event != nil {
			latest = event
			continue
		}
		if latest == nil || !bytes.Contains(line, []byte(`"assistant"`)) {
			continue
		}
		var r row
		if json.Unmarshal(line, &r) == nil && r.Type == "assistant" && !r.IsSidechain && !r.IsAPIError {
			latest = nil
		}
	}
	return latest
}

// ReadTail reads at most max bytes from the end of a regular file. The first,
// possibly partial, line is dropped when the file was cut.
func ReadTail(path string, max int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, os.ErrInvalid
	}
	start := info.Size() - max
	if start < 0 {
		start = 0
	}
	data, err := io.ReadAll(io.NewSectionReader(file, start, info.Size()-start))
	if err != nil {
		return nil, err
	}
	if start > 0 {
		if index := bytes.IndexByte(data, '\n'); index >= 0 {
			data = data[index+1:]
		} else {
			data = nil
		}
	}
	return data, nil
}
