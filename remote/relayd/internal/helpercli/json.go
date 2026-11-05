// Package helpercli contains the native successors to maintained Relay developer helpers.
package helpercli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"unicode/utf8"
)

const maxDocument = 1 << 20

// decodeJSON bounds allocation and rejects duplicate keys and incomplete documents.
// Unknown object members are retained: these helpers do not own the server schema.
func decodeJSON(data []byte, limit int) (any, error) {
	if len(data) > limit {
		return nil, errors.New("JSON exceeds size limit")
	}
	if !jsonUnicode(data) {
		return nil, errors.New("JSON contains invalid Unicode")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) (any, error)
	value = func(depth int) (any, error) {
		if depth > 64 {
			return nil, errors.New("JSON exceeds nesting limit")
		}
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		switch t := t.(type) {
		case json.Delim:
			if t == '{' {
				m := map[string]any{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return nil, e
					}
					s, ok := k.(string)
					if !ok {
						return nil, errors.New("invalid JSON key")
					}
					if _, ok = m[s]; ok {
						return nil, errors.New("duplicate JSON key")
					}
					v, e := value(depth + 1)
					if e != nil {
						return nil, e
					}
					m[s] = v
				}
				end, e := d.Token()
				if e != nil || end != json.Delim('}') {
					return nil, errors.New("incomplete JSON object")
				}
				return m, nil
			}
			if t == '[' {
				a := []any{}
				for d.More() {
					v, e := value(depth + 1)
					if e != nil {
						return nil, e
					}
					a = append(a, v)
				}
				end, e := d.Token()
				if e != nil || end != json.Delim(']') {
					return nil, errors.New("incomplete JSON array")
				}
				return a, nil
			}
			return nil, errors.New("unexpected JSON delimiter")
		default:
			return t, nil
		}
	}
	v, e := value(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, errors.New("trailing JSON data")
	}
	return v, nil
}
func jsonObject(data []byte, limit int) (map[string]any, error) {
	v, e := decodeJSON(data, limit)
	if e != nil {
		return nil, e
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("expected JSON object")
	}
	return m, nil
}
func printJSON(w io.Writer, v any) error {
	e := json.NewEncoder(w)
	e.SetIndent("", "  ")
	e.SetEscapeHTML(false)
	return e.Encode(v)
}
func required(m map[string]any, k string) (any, error) {
	v, ok := m[k]
	if !ok {
		return nil, fmt.Errorf("missing field: %s", k)
	}
	return v, nil
}

// encoding/json replaces invalid UTF-8 and lone surrogates. Reject them instead
// of silently changing a setting key, value, or credential during migration.
func jsonUnicode(data []byte) bool {
	if !utf8.Valid(data) {
		return false
	}
	inside := false
	for i := 0; i < len(data); i++ {
		if data[i] == '"' {
			inside = !inside
			continue
		}
		if !inside || data[i] != '\\' {
			continue
		}
		if i+1 >= len(data) {
			return false
		}
		if data[i+1] != 'u' {
			i++
			continue
		}
		if i+6 > len(data) {
			return false
		}
		n, e := strconv.ParseUint(string(data[i+2:i+6]), 16, 16)
		if e != nil {
			return false
		}
		if n >= 0xdc00 && n <= 0xdfff {
			return false
		}
		if n >= 0xd800 && n <= 0xdbff {
			if i+12 > len(data) || data[i+6] != '\\' || data[i+7] != 'u' {
				return false
			}
			low, e := strconv.ParseUint(string(data[i+8:i+12]), 16, 16)
			if e != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			i += 11
		} else {
			i += 5
		}
	}
	return true
}
