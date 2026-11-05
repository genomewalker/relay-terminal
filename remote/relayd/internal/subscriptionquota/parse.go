// Package subscriptionquota reads existing subscription observations. It never
// launches a provider, signs in, refreshes tokens, resumes or submits inference.
package subscriptionquota

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

const Limit = 65536

var errUnavailable = errors.New("private quota observation unavailable")
var windowKeys = []string{"five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet", "seven_day_cowork", "seven_day_omelette"}

// decodeObject bounds every external JSON source and preserves integer/float
// spelling for the Python-compatible scoped-limit identity encoding.
func decodeObject(data []byte, maximum int) (map[string]any, error) {
	if len(data) > maximum || !utf8.Valid(data) {
		return nil, errUnavailable
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value map[string]any
	if err := d.Decode(&value); err != nil || value == nil {
		return nil, errUnavailable
	}
	if d.Decode(new(any)) == nil || !json.Valid(data) {
		return nil, errUnavailable
	}
	return value, nil
}

func object(v any) map[string]any { m, _ := v.(map[string]any); return m }
func text(v any) string           { s, _ := v.(string); return s }
func validID(s string) bool {
	if len(s) == 0 || len(s) > 110 {
		return false
	}
	for _, c := range s {
		if !strings.ContainsRune("0123456789abcdefABCDEF-", c) {
			return false
		}
	}
	return true
}
func percentage(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	return f, err == nil && !math.IsNaN(f) && !math.IsInf(f, 0) && f >= 0 && f <= 100
}
func resetNumber(v any) bool {
	n, ok := v.(json.Number)
	if !ok {
		return false
	}
	f, err := n.Float64()
	return err == nil && f > 0 && f < 253402300800 && !math.IsInf(f, 0) && !math.IsNaN(f)
}

var resetPattern = regexp.MustCompile(`^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:?\d{2}(?::?\d{2}(?:\.\d{1,6})?)?)$`)

// resetTimestamp accepts the timezone-bearing strptime forms used by the
// observation helper, including compact offsets and microseconds.
func resetTimestamp(s string) (float64, error) {
	if len(s) > 80 {
		return 0, errUnavailable
	}
	m := resetPattern.FindStringSubmatch(s)
	if m == nil {
		return 0, errUnavailable
	}
	n := make([]int, 6)
	for i := range n {
		n[i], _ = strconv.Atoi(m[i+1])
	}
	if n[0] < 1 || n[0] > 9999 || n[1] < 1 || n[1] > 12 || n[2] < 1 || n[2] > 31 || n[3] > 23 || n[4] > 59 || n[5] > 59 {
		return 0, errUnavailable
	}
	nanos := 0
	if m[7] != "" {
		nanos, _ = strconv.Atoi(m[7] + strings.Repeat("0", 9-len(m[7])))
	}
	stamp := time.Date(n[0], time.Month(n[1]), n[2], n[3], n[4], n[5], nanos, time.UTC)
	if stamp.Year() != n[0] || int(stamp.Month()) != n[1] || stamp.Day() != n[2] {
		return 0, errUnavailable
	}
	offset := 0.0
	if m[8] != "Z" {
		if raw := m[8][1:]; strings.Contains(raw, ":") {
			parts := strings.Split(raw, ":")
			if len(parts) < 2 || len(parts) > 3 || len(parts[0]) != 2 || len(parts[1]) != 2 {
				return 0, errUnavailable
			}
		}
		zone := strings.ReplaceAll(m[8][1:], ":", "")
		h, _ := strconv.Atoi(zone[:2])
		minute, _ := strconv.Atoi(zone[2:4])
		seconds := 0.0
		if len(zone) > 4 {
			seconds, _ = strconv.ParseFloat(zone[4:], 64)
		}
		if h > 23 || minute > 59 || seconds >= 60 {
			return 0, errUnavailable
		}
		offset = float64(h*3600+minute*60) + seconds
		if m[8][0] == '-' {
			offset = -offset
		}
	}
	return float64(stamp.Unix()) + float64(nanos)/1e9 - offset, nil
}

// pythonJSON reproduces json.dumps(ensure_ascii=True, sort_keys=True), with
// default spacing for scoped-limit hashes and compact spacing for accounts.
// No provider identifiers are returned to the caller, only the digest.
func pythonJSON(value any, compact bool) ([]byte, error) {
	var out bytes.Buffer
	comma, colon := ", ", ": "
	if compact {
		comma, colon = ",", ":"
	}
	var write func(any) error
	writeString := func(s string) {
		var b bytes.Buffer
		e := json.NewEncoder(&b)
		e.SetEscapeHTML(false)
		_ = e.Encode(s)
		for _, r := range strings.TrimSuffix(b.String(), "\n") {
			if r >= 127 {
				if r > 0xffff {
					a, z := utf16.EncodeRune(r)
					fmt.Fprintf(&out, `\u%04x\u%04x`, a, z)
				} else {
					fmt.Fprintf(&out, `\u%04x`, r)
				}
			} else {
				out.WriteRune(r)
			}
		}
	}
	write = func(v any) error {
		switch v := v.(type) {
		case nil:
			out.WriteString("null")
		case bool:
			if v {
				out.WriteString("true")
			} else {
				out.WriteString("false")
			}
		case string:
			writeString(v)
		case json.Number:
			s := string(v)
			if s == "-0" {
				s = "0"
			}
			if strings.ContainsAny(s, ".eE") {
				f, err := v.Float64()
				if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
					return errUnavailable
				}
				format := byte('f')
				a := math.Abs(f)
				if a != 0 && (a < 1e-4 || a >= 1e16) {
					format = 'e'
				}
				s = strconv.FormatFloat(f, format, -1, 64)
				if !strings.ContainsAny(s, ".eE") {
					s += ".0"
				}
			}
			out.WriteString(s)
		case []any:
			out.WriteByte('[')
			for i, x := range v {
				if i > 0 {
					out.WriteString(comma)
				}
				if err := write(x); err != nil {
					return err
				}
			}
			out.WriteByte(']')
		case map[string]any:
			keys := make([]string, 0, len(v))
			for k := range v {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			out.WriteByte('{')
			for i, k := range keys {
				if i > 0 {
					out.WriteString(comma)
				}
				writeString(k)
				out.WriteString(colon)
				if err := write(v[k]); err != nil {
					return err
				}
			}
			out.WriteByte('}')
		default:
			return errUnavailable
		}
		return nil
	}
	if err := write(value); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func identityDigest(value []any) string {
	b, _ := pythonJSON(value, true)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func parseUsage(data []byte, plan any, scope any, now time.Time) (map[string]any, error) {
	value, err := decodeObject(data, Limit)
	if err != nil {
		return nil, err
	}
	limits := map[string]any{}
	for _, key := range windowKeys {
		window := object(value[key])
		used, ok := percentage(window["utilization"])
		if !ok {
			continue
		}
		var reset any
		if raw, ok := window["resets_at"].(string); ok {
			stamp, err := resetTimestamp(raw)
			if err != nil {
				return nil, err
			}
			if stamp <= 0 || stamp >= 253402300800 {
				continue
			}
			reset = stamp
		}
		limits[key] = map[string]any{"used_percentage": used, "resets_at": reset}
	}
	additional := []any{}
	reported, _ := value["limits"].([]any)
	if len(reported) > 32 {
		reported = reported[:32]
	}
	for _, raw := range reported {
		item := object(raw)
		kind := text(item["kind"])
		if item == nil || kind == "session" || kind == "weekly_all" {
			continue
		}
		used, ok := percentage(item["percent"])
		if !ok {
			continue
		}
		scope := object(item["scope"])
		label, ok := object(scope["model"])["display_name"].(string)
		if !ok || strings.TrimSpace(label) == "" || utf8.RuneCountInString(label) > 80 {
			continue
		}
		stamp, err := resetTimestamp(text(item["resets_at"]))
		if err != nil || stamp <= 0 || stamp >= 253402300800 {
			continue
		}
		encoded, err := pythonJSON(scope, false)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(encoded)
		var duration any
		if text(item["group"]) == "weekly" {
			duration = 10080
		}
		additional = append(additional, map[string]any{"id": "scoped-" + hex.EncodeToString(sum[:])[:16], "label": label, "used_percentage": used, "resets_at": stamp, "duration_minutes": duration})
	}
	if len(limits) == 0 && len(additional) == 0 {
		return nil, nil
	}
	var spend any
	if s := object(value["spend"]); s != nil {
		spend = s
	}
	return map[string]any{"provider": "claude", "account_scope": scope, "observation": map[string]any{"session_id": "account-usage", "rate_limits": limits, "plan_type": plan, "additional_limits": additional, "spend": spend, "captured_at": captureTime(now)}}, nil
}

func captureTime(now time.Time) string {
	if now.Nanosecond()/1000 == 0 {
		return now.UTC().Format("2006-01-02T15:04:05Z")
	}
	return now.UTC().Format("2006-01-02T15:04:05.000000Z")
}

func statusRecord(raw []byte, scope any, now time.Time) (map[string]any, error) {
	value, err := decodeObject(raw, Limit)
	if err != nil {
		return nil, err
	}
	ident := text(value["session_id"])
	if !validID(ident) {
		return nil, nil
	}
	if raw, exists := value["rate_limits"]; exists && object(raw) == nil {
		return nil, errUnavailable
	}
	limits := map[string]any{}
	for _, key := range windowKeys {
		if raw, exists := object(value["rate_limits"])[key]; exists && object(raw) == nil {
			return nil, errUnavailable
		}
		window := object(object(value["rate_limits"])[key])
		used, ok := percentage(window["used_percentage"])
		if !ok {
			continue
		}
		reset := window["resets_at"]
		if reset != nil && !resetNumber(reset) {
			continue
		}
		limits[key] = map[string]any{"used_percentage": used, "resets_at": reset}
	}
	return map[string]any{"session_id": ident, "rate_limits": limits, "account_scope": scope, "captured_at": captureTime(now)}, nil
}
func projection(value map[string]any, keys ...string) map[string]any {
	out := map[string]any{}
	for _, k := range keys {
		if v, ok := value[k]; ok {
			out[k] = v
		}
	}
	return out
}
