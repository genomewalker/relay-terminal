package nativechat

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"
)

// DecodeObject bounds work before decoding and rejects duplicate keys at every
// depth. Silently choosing one duplicate would give the UI and worker different
// interpretations of an approval or session identity.
func DecodeObject(data []byte, limit int) (map[string]json.RawMessage, error) {
	if len(data) == 0 || len(data) > limit || !utf8.Valid(data) {
		return nil, errors.New("invalid JSON size or encoding")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	nodes := 0
	var consume func(int) error
	consume = func(depth int) error {
		nodes++
		if depth > 64 || nodes > 65536 {
			return errors.New("JSON structure limit exceeded")
		}
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			keys := map[string]bool{}
			for decoder.More() {
				keyToken, e := decoder.Token()
				if e != nil {
					return e
				}
				key, ok := keyToken.(string)
				if !ok || keys[key] {
					return errors.New("duplicate JSON key")
				}
				keys[key] = true
				if e = consume(depth + 1); e != nil {
					return e
				}
			}
			end, e := decoder.Token()
			if e != nil || end != json.Delim('}') {
				return errors.New("invalid JSON object")
			}
		case '[':
			for decoder.More() {
				if e := consume(depth + 1); e != nil {
					return e
				}
			}
			end, e := decoder.Token()
			if e != nil || end != json.Delim(']') {
				return errors.New("invalid JSON array")
			}
		default:
			return errors.New("unexpected JSON delimiter")
		}
		return nil
	}
	if err := consume(0); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("trailing JSON data")
	}
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil || object == nil {
		return nil, errors.New("JSON object required")
	}
	return object, nil
}
func DecodeAction(data []byte) (Action, error) {
	var action Action
	if _, err := DecodeObject(data, MaxActionBytes); err != nil {
		return action, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&action); err != nil {
		return action, err
	}
	return action, nil
}
