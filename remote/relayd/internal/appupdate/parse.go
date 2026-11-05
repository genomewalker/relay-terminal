package appupdate

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode/utf8"
)

const maxState = 32 << 20

func parseJSON(raw []byte) (any, error) {
	if len(raw) > maxState || !utf8.Valid(raw) {
		return nil, errors.New("state encoding/size invalid")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var read func(int) (any, error)
	read = func(depth int) (any, error) {
		if depth > 64 {
			return nil, errors.New("state depth exceeded")
		}
		v, e := d.Token()
		if e != nil {
			return nil, e
		}
		if n, ok := v.(json.Number); ok {
			f, e := strconv.ParseFloat(string(n), 64)
			if len(n) > 128 || e != nil || math.IsInf(f, 0) || math.IsNaN(f) {
				return nil, errors.New("state number exceeds bounds")
			}
		}
		x, ok := v.(json.Delim)
		if !ok {
			return v, nil
		}
		switch x {
		case '{':
			m := map[string]any{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return nil, e
				}
				key, ok := k.(string)
				if !ok {
					return nil, errors.New("object key required")
				}
				if _, ok := m[key]; ok {
					return nil, errors.New("duplicate state key")
				}
				v, e := read(depth + 1)
				if e != nil {
					return nil, e
				}
				m[key] = v
			}
			_, e = d.Token()
			return m, e
		case '[':
			a := []any{}
			for d.More() {
				v, e := read(depth + 1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
			_, e = d.Token()
			return a, e
		}
		return nil, errors.New("unexpected JSON delimiter")
	}
	v, e := read(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, errors.New("trailing state")
	}
	return v, nil
}
func object(raw []byte) (map[string]any, error) {
	v, e := parseJSON(raw)
	if e != nil {
		return nil, e
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("object required")
	}
	return m, nil
}
func equal(a, b any) bool {
	if an, ok := a.(json.Number); ok {
		bn, ok := b.(json.Number)
		if !ok {
			return false
		}
		x, ok := new(big.Rat).SetString(string(an))
		if !ok {
			return false
		}
		y, ok := new(big.Rat).SetString(string(bn))
		return ok && x.Cmp(y) == 0
	}
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			z, ok := y[k]
			if !ok || !equal(v, z) {
				return false
			}
		}
		return true
	}
	return false
}
func jsonData(v any) []byte { b, _ := json.MarshalIndent(v, "", "  "); return append(b, '\n') }
func decodeRecord(raw []byte, v any) error {
	if _, e := object(raw); e != nil {
		return e
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	return d.Decode(v)
}

func parsePlist(raw []byte) (map[string]any, error) {
	if len(raw) > maxState || !utf8.Valid(raw) {
		return nil, errors.New("plist encoding/size invalid")
	}
	d := xml.NewDecoder(bytes.NewReader(raw))
	var read func(xml.StartElement, int) (any, error)
	read = func(start xml.StartElement, depth int) (any, error) {
		if depth > 64 {
			return nil, errors.New("plist depth exceeded")
		}
		switch start.Name.Local {
		case "string", "key", "integer", "real", "date", "data", "true", "false":
			var text string
			if e := d.DecodeElement(&text, &start); e != nil {
				return nil, e
			}
			switch start.Name.Local {
			case "true", "false":
				if strings.TrimSpace(text) != "" {
					return nil, errors.New("invalid plist boolean")
				}
				return start.Name.Local == "true", nil
			case "data":
				return base64.StdEncoding.DecodeString(strings.Join(strings.Fields(text), ""))
			case "integer", "real":
				v, e := parseJSON([]byte(strings.TrimSpace(text)))
				if e != nil {
					return nil, e
				}
				if _, ok := v.(json.Number); !ok {
					return nil, errors.New("invalid plist number")
				}
				return v, nil
			}
			return text, nil
		case "dict", "array":
			m := map[string]any{}
			a := []any{}
			key := ""
			expect := true
			for {
				token, e := d.Token()
				if e != nil {
					return nil, e
				}
				switch t := token.(type) {
				case xml.CharData:
					if strings.TrimSpace(string(t)) != "" {
						return nil, errors.New("invalid plist text")
					}
				case xml.EndElement:
					if t.Name != start.Name || !expect {
						return nil, errors.New("truncated plist")
					}
					if start.Name.Local == "dict" {
						return m, nil
					}
					return a, nil
				case xml.StartElement:
					if start.Name.Local == "dict" && expect && t.Name.Local != "key" {
						return nil, errors.New("plist key required")
					}
					v, e := read(t, depth+1)
					if e != nil {
						return nil, e
					}
					if start.Name.Local == "array" {
						a = append(a, v)
					} else if expect {
						key = v.(string)
						if _, ok := m[key]; ok {
							return nil, errors.New("duplicate plist key")
						}
						expect = false
					} else {
						m[key] = v
						expect = true
					}
				}
			}
		}
		return nil, errors.New("unsupported plist type")
	}
	opened, closed := false, false
	var result map[string]any
	for {
		token, e := d.Token()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, e
		}
		switch t := token.(type) {
		case xml.StartElement:
			if !opened {
				if t.Name.Local != "plist" {
					return nil, errors.New("plist root required")
				}
				opened = true
			} else {
				if closed || result != nil || t.Name.Local != "dict" {
					return nil, errors.New("unexpected plist root")
				}
				v, e := read(t, 0)
				if e != nil {
					return nil, e
				}
				result = v.(map[string]any)
			}
		case xml.EndElement:
			if t.Name.Local != "plist" || result == nil {
				return nil, errors.New("invalid plist end")
			}
			closed = true
		case xml.CharData:
			if strings.TrimSpace(string(t)) != "" {
				return nil, errors.New("invalid plist text")
			}
		}
	}
	if !closed {
		return nil, errors.New("truncated plist")
	}
	return result, nil
}
