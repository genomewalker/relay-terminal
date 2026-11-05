package daemon

import (
	"errors"
	"unicode/utf8"
)

// Native JSON values contain Unicode scalars. Reject malformed Unicode before
// encoding/json can replace it with U+FFFD and conflate distinct identities.
// A former Python reader could retain lone surrogates internally, but could
// not encode such a conversation body to its UTF-8 reply. Native readers reject
// that input explicitly, including surrogates in otherwise ignored fields.
func nativeJSONUnicode(data []byte) error {
	invalid := func() error { return errors.New("JSON must contain Unicode scalar values") }
	if !utf8.Valid(data) {
		return invalid()
	}
	quoted := false
	for i := 0; i < len(data); {
		if data[i] == '"' {
			quoted = !quoted
			i++
			continue
		}
		if !quoted || data[i] != '\\' {
			i++
			continue
		}
		if i+1 >= len(data) || data[i+1] != 'u' {
			i += 2 // The JSON decoder checks escape syntax and truncation.
			continue
		}
		unit, ok := nativeJSONHexUnit(data, i+2)
		if !ok {
			return nil // Preserve the decoder's malformed JSON error.
		}
		if unit >= 0xdc00 && unit <= 0xdfff {
			return invalid()
		}
		if unit >= 0xd800 && unit <= 0xdbff {
			if i+7 >= len(data) || data[i+6] != '\\' || data[i+7] != 'u' {
				return invalid()
			}
			low, ok := nativeJSONHexUnit(data, i+8)
			if !ok || low < 0xdc00 || low > 0xdfff {
				return invalid()
			}
			i += 12
			continue
		}
		i += 6
	}
	return nil
}

func nativeJSONHexUnit(data []byte, offset int) (uint16, bool) {
	if offset < 0 || offset+4 > len(data) {
		return 0, false
	}
	var result uint16
	for _, b := range data[offset : offset+4] {
		result <<= 4
		switch {
		case b >= '0' && b <= '9':
			result += uint16(b - '0')
		case b >= 'a' && b <= 'f':
			result += uint16(b-'a') + 10
		case b >= 'A' && b <= 'F':
			result += uint16(b-'A') + 10
		default:
			return 0, false
		}
	}
	return result, true
}
