// Package programstatus implements OSC 7501 revision 0.3. Reports are untrusted
// display metadata, never provider identity, command input, or authorization.
package programstatus

import (
	"bytes"
	"encoding/base64"
	"errors"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	MaxSequence = 4096
	MaxRecords  = 256
)

const DetectionReply = "\x1b]7501;?\x1b\\"

// Record is the complete latest report for an ID. Missing fields never inherit
// from an older report. Only App inherits from a nearest ancestor at display.
type Record struct {
	ID       string `json:"id,omitempty"`
	State    string `json:"state"`
	Kind     string `json:"kind,omitempty"`
	App      string `json:"app,omitempty"`
	Title    string `json:"title,omitempty"`
	Message  string `json:"message,omitempty"`
	Progress *int   `json:"progress,omitempty"`
	Revision uint64 `json:"revision"`
}

func valueByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_.,+/=-", rune(c))
}
func atom(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_.+-", rune(c))) {
			return false
		}
	}
	return true
}
func validID(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	parts := strings.Split(s, "/")
	if len(parts) > 8 {
		return false
	}
	for _, part := range parts {
		if !atom(part, 32) {
			return false
		}
	}
	return true
}
func decodeText(s string, encoded, decoded int) (string, error) {
	if len(s) > encoded {
		return "", errors.New("encoded text limit")
	}
	var data []byte
	var err error
	if len(s)%4 == 0 {
		data, err = base64.StdEncoding.DecodeString(s)
	} else {
		data, err = base64.RawStdEncoding.DecodeString(s)
	}
	if err != nil || len(data) > decoded || !utf8.Valid(data) {
		return "", errors.New("invalid text")
	}
	for _, c := range string(data) {
		if c < 32 || c >= 127 && c <= 159 {
			return "", errors.New("text control character")
		}
	}
	return string(data), nil
}

// DisplayText removes invisible formatting controls before presenting metadata
// outside the terminal grid. Emoji joiners remain intact; text is never markup.
func DisplayText(s string) string {
	return strings.Map(func(c rune) rune {
		if c == '\u2028' || c == '\u2029' {
			return ' '
		}
		if unicode.Is(unicode.Cf, c) && c != '\u200c' && c != '\u200d' {
			return -1
		}
		return c
	}, s)
}

// Parse validates every pair before any record is touched. Syntactically bad
// pairs are skipped; excessive limits or invalid encoded text reject the whole
// report. Unknown keys are ignored and the last valid repeated value wins.
func Parse(body string) (Record, error) {
	var record Record
	if len(body)+len("\x1b]7501;")+2 > MaxSequence {
		return record, errors.New("sequence limit")
	}
	pairs := map[string]string{}
	decoded := map[string]string{}
	for _, part := range strings.Split(body, ":") {
		halves := strings.SplitN(part, "=", 2)
		if len(halves) != 2 {
			continue
		}
		key, value := strings.TrimSpace(halves[0]), strings.TrimSpace(halves[1])
		if len(key) > 16 {
			return record, errors.New("key limit")
		}
		valid := key != ""
		for _, c := range []byte(key) {
			if c < 'a' || c > 'z' {
				valid = false
			}
		}
		for _, c := range []byte(value) {
			if !valueByte(c) {
				valid = false
			}
		}
		if !valid {
			continue
		}
		switch key {
		case "msg", "title":
			encoded, size := 2732, 2048
			if key == "title" {
				encoded, size = 256, 192
			}
			text, err := decodeText(value, encoded, size)
			if err != nil {
				return record, err
			}
			decoded[key] = text
		case "app":
			if len(value) > 32 {
				return record, errors.New("app limit")
			}
		case "id":
			if len(value) > 128 {
				return record, errors.New("id limit")
			}
			for _, segment := range strings.Split(value, "/") {
				if len(segment) > 32 {
					return record, errors.New("id segment limit")
				}
			}
			if len(strings.Split(value, "/")) > 8 {
				return record, errors.New("id depth limit")
			}
		}
		pairs[key] = value
	}
	switch pairs["state"] {
	case "idle", "working", "done", "blocked", "error", "clear":
		record.State = pairs["state"]
	default:
		return record, errors.New("unrecognized state")
	}
	if id, exists := pairs["id"]; exists {
		if !validID(id) {
			return Record{}, errors.New("invalid id")
		}
		record.ID = id
	}
	if app := pairs["app"]; atom(app, 32) {
		record.App = app
	}
	record.Title, record.Message = decoded["title"], decoded["msg"]
	if record.State == "blocked" {
		switch pairs["kind"] {
		case "permission", "question", "auth":
			record.Kind = pairs["kind"]
		}
	}
	if record.State == "working" || record.State == "blocked" {
		if n, err := strconv.Atoi(pairs["progress"]); err == nil && n >= 0 && n <= 100 {
			record.Progress = &n
		}
	}
	return record, nil
}

// Tracker belongs to a single live PTY owner. The owner supplies synchronization
// and treats Changed only as a presentation event; it grants no capabilities.
type Tracker struct {
	passthrough          []byte
	passthroughPrefix    int
	passthroughOversized bool
	passthroughDepth     int
	records              map[string]Record
	revision             uint64
	state                byte
	body                 []byte
	oversized            bool
}

type Events struct {
	Changed          bool
	DetectionQueries int
}

const (
	ground byte = iota
	escape
	osc
	oscEscape
	otherString
	otherStringEscape
	dcsPrefix
	dcsPayload
	dcsPayloadEscape
)

func (t *Tracker) Feed(data []byte) Events {
	var result Events
	for index := 0; index < len(data); index++ {
		if t.state == ground {
			skip := bytes.IndexByte(data[index:], 0x1b)
			if skip < 0 {
				break
			}
			index += skip
		}
		b := data[index]
		switch t.state {
		case ground:
			if b == 0x1b {
				t.state = escape
			}
		case escape:
			switch b {
			case ']':
				t.state = osc
				t.body = t.body[:0]
				t.oversized = false
			case 'P':
				t.state = dcsPrefix
				t.passthroughPrefix = 0
				t.passthrough = t.passthrough[:0]
				t.passthroughOversized = false
			case '_', '^', 'X':
				t.state = otherString
			case 'c':
				if len(t.records) > 0 {
					t.records = nil
					result.Changed = true
				}
				t.state = ground
			case 0x1b: // A fresh escape supersedes the previous one.
			default:
				t.state = ground
			}

		case dcsPrefix:
			if b == "tmux;"[t.passthroughPrefix] {
				t.passthroughPrefix++
				if t.passthroughPrefix == len("tmux;") {
					t.state = dcsPayload
				}
			} else {
				t.state = otherString
				if b == 0x1b {
					t.state = otherStringEscape
				}
			}
		case dcsPayload:
			if b == 0x1b {
				t.state = dcsPayloadEscape
			} else {
				t.appendPassthrough(b)
			}
		case dcsPayloadEscape:
			switch b {
			case 0x1b:
				t.appendPassthrough(0x1b)
				t.state = dcsPayload
			case '\\':
				t.finishPassthrough(&result)
				t.state = ground
			default:
				// Every payload ESC must be doubled. Reject the entire
				// envelope before it can mutate status or cause a reply.
				t.passthroughOversized = true
				t.passthrough = t.passthrough[:0]
				t.state = dcsPayload
			}
		case otherString:
			if b == 0x1b {
				t.state = otherStringEscape
			}
		case otherStringEscape:
			if b == '\\' {
				t.state = ground
			} else if b != 0x1b {
				t.state = otherString
			}
		case osc:
			if b == 7 {
				t.finish(&result)
				t.state = ground
			} else if b == 0x1b {
				t.state = oscEscape
			} else {
				t.append(b)
			}
		case oscEscape:
			if b == '\\' {
				t.finish(&result)
				t.state = ground
			} else {
				t.append(0x1b)
				t.append(b)
				t.state = osc
			}
		}
	}
	return result
}

const MaxPassthrough = 2 * MaxSequence
const MaxPassthroughDepth = 4

func (t *Tracker) appendPassthrough(b byte) {
	if t.passthroughOversized {
		return
	}
	if len(t.passthrough) >= MaxPassthrough {
		t.passthroughOversized = true
		t.passthrough = t.passthrough[:0]
		return
	}
	t.passthrough = append(t.passthrough, b)
}
func (t *Tracker) finishPassthrough(events *Events) {
	defer func() { t.passthrough = t.passthrough[:0] }()
	if t.passthroughOversized || t.passthroughDepth >= MaxPassthroughDepth {
		return
	}
	// The owner serializes parsing; nested decoders share the bounded records,
	// while retaining separate escape state and a fixed depth limit.
	inner := Tracker{records: t.records, revision: t.revision,
		passthroughDepth: t.passthroughDepth + 1}
	next := inner.Feed(t.passthrough)
	t.records, t.revision = inner.records, inner.revision
	events.Changed = events.Changed || next.Changed
	events.DetectionQueries += next.DetectionQueries
}

func (t *Tracker) append(b byte) {
	if t.oversized {
		return
	}
	// Reserve OSC introducer and ST terminator; never grow an unbounded buffer.
	if len(t.body)+2+2 >= MaxSequence {
		t.oversized = true
		t.body = t.body[:0]
		return
	}
	t.body = append(t.body, b)
}
func (t *Tracker) finish(events *Events) {
	if t.oversized {
		return
	}
	body := string(t.body)
	if body == "7501;?" {
		events.DetectionQueries++
		return
	}
	if body == "133;A" || strings.HasPrefix(body, "133;A;") {
		events.Changed = t.DropRunning() || events.Changed
		return
	}
	if !strings.HasPrefix(body, "7501;") {
		return
	}
	record, err := Parse(strings.TrimPrefix(body, "7501;"))
	if err != nil {
		return
	}
	events.Changed = t.apply(record) || events.Changed
}
func (t *Tracker) apply(record Record) bool {
	if record.State == "clear" {
		changed := false
		for id := range t.records {
			if record.ID == "" || id == record.ID || strings.HasPrefix(id, record.ID+"/") {
				delete(t.records, id)
				changed = true
			}
		}
		return changed
	}
	if t.records == nil {
		t.records = map[string]Record{}
	}
	if _, exists := t.records[record.ID]; !exists && len(t.records) >= MaxRecords {
		oldest, revision := "", ^uint64(0)
		for id, value := range t.records {
			if value.Revision < revision {
				oldest, revision = id, value.Revision
			}
		}
		delete(t.records, oldest)
	}
	t.revision++
	record.Revision = t.revision
	t.records[record.ID] = record
	return true
}
func (t *Tracker) DropRunning() bool {
	changed := false
	for id, record := range t.records {
		if record.State == "working" || record.State == "blocked" {
			delete(t.records, id)
			changed = true
		}
	}
	return changed
}

// Snapshot returns detached values. Consumers must use the pane's verified
// identity independently; a declared App name is not authenticated ownership.
func (t *Tracker) Snapshot() []Record {
	result := make([]Record, 0, len(t.records))
	for _, record := range t.records {
		if record.Progress != nil {
			p := *record.Progress
			record.Progress = &p
		}
		if record.App == "" {
			id := record.ID
			for {
				cut := strings.LastIndexByte(id, '/')
				if cut < 0 {
					id = ""
				} else {
					id = id[:cut]
				}
				if ancestor, found := t.records[id]; found && ancestor.App != "" {
					record.App = ancestor.App
					break
				}
				if id == "" {
					break
				}
			}
		}
		record.Message, record.Title = DisplayText(record.Message), DisplayText(record.Title)
		result = append(result, record)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}
