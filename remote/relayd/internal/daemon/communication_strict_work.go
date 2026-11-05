package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

// Work protocol objects are bounded and reject ambiguous JSON fields before
// decoding. This does not change the existing pane protocol's decoder.
func communicationStrictWorkJSON(raw []byte, value any) error {
	return communicationStrictWorkJSONLimit(raw, value, communicationEnvelopeLimit)
}
func communicationStrictWorkJSONLimit(raw []byte, value any, limit int) error {
	if len(raw) == 0 || limit <= 0 || len(raw) > limit {
		return errors.New("invalid Work JSON size")
	}
	scan := json.NewDecoder(bytes.NewReader(raw))
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 16 {
			return errors.New("Work JSON too deep")
		}
		token, err := scan.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for scan.More() {
				key, err := scan.Token()
				if err != nil {
					return err
				}
				s, ok := key.(string)
				if !ok || s != strings.ToLower(s) || seen[s] {
					return errors.New("ambiguous Work JSON field")
				}
				seen[s] = true
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			end, err := scan.Token()
			if err != nil || end != json.Delim('}') {
				return errors.New("invalid Work object")
			}
		case '[':
			for scan.More() {
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			end, err := scan.Token()
			if err != nil || end != json.Delim(']') {
				return errors.New("invalid Work array")
			}
		default:
			return errors.New("invalid Work delimiter")
		}
		return nil
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := scan.Token(); err != io.EOF {
		return errors.New("trailing Work JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	return decoder.Decode(value)
}
