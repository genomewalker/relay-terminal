package main

// The CLI's output was json.dumps of values read with json.loads, so values
// keep Python's model: objects keep insertion order, integer lexemes stay
// integers of any size, floats print as float.__repr__, and output uses the
// default separators with ensure_ascii.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode/utf16"
)

// object is a Python dict: replacing a value keeps its position.
type object struct {
	keys   []string
	values map[string]any
}

func newObject(pairs ...any) *object {
	o := &object{values: map[string]any{}}
	for i := 0; i+1 < len(pairs); i += 2 {
		o.set(pairs[i].(string), pairs[i+1])
	}
	return o
}

func (o *object) set(key string, value any) {
	if _, ok := o.values[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.values[key] = value
}

func (o *object) lookup(key string) (any, bool) { v, ok := o.values[key]; return v, ok }

// get is dict.get(key): nil when absent.
func (o *object) get(key string) any { return o.values[key] }

// index is o[key], raising KeyError when absent.
func (o *object) index(key string) (any, error) {
	if v, ok := o.values[key]; ok {
		return v, nil
	}
	return nil, errors.New(pyStringRepr(key))
}

func (o *object) copy() *object {
	c := newObject()
	for _, k := range o.keys {
		c.set(k, o.values[k])
	}
	return c
}

// decodeJSON is json.loads. Integer lexemes stay *big.Int; other numbers
// are float64.
func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	value, err := decodeValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("Extra data")
	}
	return value, nil
}

func decodeValue(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	switch t := token.(type) {
	case json.Delim:
		switch t {
		case '{':
			o := newObject()
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return nil, err
				}
				value, err := decodeValue(decoder)
				if err != nil {
					return nil, err
				}
				o.set(key.(string), value)
			}
			_, err := decoder.Token()
			return o, err
		case '[':
			items := []any{}
			for decoder.More() {
				value, err := decodeValue(decoder)
				if err != nil {
					return nil, err
				}
				items = append(items, value)
			}
			_, err := decoder.Token()
			return items, err
		}
		return nil, errors.New("unexpected delimiter")
	case json.Number:
		lexeme := string(t)
		if !strings.ContainsAny(lexeme, ".eE") {
			value, ok := new(big.Int).SetString(lexeme, 10)
			if !ok {
				return nil, errors.New("invalid integer")
			}
			return value, nil
		}
		value, err := strconv.ParseFloat(lexeme, 64)
		if err != nil && !math.IsInf(value, 0) {
			return nil, err
		}
		return value, nil // overflow is infinity, as float() is
	default:
		return t, nil // string, bool or nil
	}
}

// encodeJSON is json.dumps(value) with its defaults.
func encodeJSON(v any) []byte {
	var buffer bytes.Buffer
	encodeValue(&buffer, v)
	return buffer.Bytes()
}

func encodeValue(buffer *bytes.Buffer, v any) {
	switch t := v.(type) {
	case nil:
		buffer.WriteString("null")
	case bool:
		buffer.WriteString(strconv.FormatBool(t))
	case int:
		buffer.WriteString(strconv.Itoa(t))
	case *big.Int:
		buffer.WriteString(t.String())
	case float64:
		switch {
		case math.IsNaN(t):
			buffer.WriteString("NaN")
		case math.IsInf(t, 1):
			buffer.WriteString("Infinity")
		case math.IsInf(t, -1):
			buffer.WriteString("-Infinity")
		default:
			buffer.WriteString(pyFloatRepr(t))
		}
	case string:
		encodeString(buffer, t)
	case []any:
		buffer.WriteByte('[')
		for i, item := range t {
			if i > 0 {
				buffer.WriteString(", ")
			}
			encodeValue(buffer, item)
		}
		buffer.WriteByte(']')
	case *object:
		buffer.WriteByte('{')
		for i, key := range t.keys {
			if i > 0 {
				buffer.WriteString(", ")
			}
			encodeString(buffer, key)
			buffer.WriteString(": ")
			encodeValue(buffer, t.values[key])
		}
		buffer.WriteByte('}')
	default:
		panic("value is not JSON serializable")
	}
}

// encodeString escapes as json.dumps with ensure_ascii=True.
func encodeString(buffer *bytes.Buffer, s string) {
	buffer.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			buffer.WriteString(`\"`)
		case '\\':
			buffer.WriteString(`\\`)
		case '\n':
			buffer.WriteString(`\n`)
		case '\r':
			buffer.WriteString(`\r`)
		case '\t':
			buffer.WriteString(`\t`)
		case '\b':
			buffer.WriteString(`\b`)
		case '\f':
			buffer.WriteString(`\f`)
		default:
			switch {
			case r < 0x20 || r > 0x7e && r <= 0xffff:
				writeUnicodeEscape(buffer, r)
			case r > 0xffff:
				high, low := utf16.EncodeRune(r)
				writeUnicodeEscape(buffer, high)
				writeUnicodeEscape(buffer, low)
			default:
				buffer.WriteRune(r)
			}
		}
	}
	buffer.WriteByte('"')
}

func writeUnicodeEscape(buffer *bytes.Buffer, r rune) {
	const hex = "0123456789abcdef"
	buffer.WriteString(`\u`)
	for shift := 12; shift >= 0; shift -= 4 {
		buffer.WriteByte(hex[(r>>shift)&0xf])
	}
}

// pyFloatRepr is float.__repr__ for finite values: shortest round-trip
// digits, positional for 1e-4 <= |x| < 1e16, else exponent notation with at
// least two exponent digits; integral values keep ".0".
func pyFloatRepr(f float64) string {
	sign := ""
	if math.Signbit(f) {
		sign, f = "-", -f
	}
	if f == 0 {
		return sign + "0.0"
	}
	mantissa, exponent, _ := strings.Cut(strconv.FormatFloat(f, 'e', -1, 64), "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	exp, _ := strconv.Atoi(exponent)
	decpt := exp + 1
	if decpt > -4 && decpt <= 16 {
		switch {
		case decpt <= 0:
			return sign + "0." + strings.Repeat("0", -decpt) + digits
		case decpt >= len(digits):
			return sign + digits + strings.Repeat("0", decpt-len(digits)) + ".0"
		default:
			return sign + digits[:decpt] + "." + digits[decpt:]
		}
	}
	out := digits[:1]
	if len(digits) > 1 {
		out += "." + digits[1:]
	}
	expSign := "+"
	if exp < 0 {
		expSign, exp = "-", -exp
	}
	expText := strconv.Itoa(exp)
	if len(expText) < 2 {
		expText = "0" + expText
	}
	return sign + out + "e" + expSign + expText
}

// truthy is Python truth testing for JSON values.
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case *big.Int:
		return t.Sign() != 0
	case float64:
		return t != 0
	case string:
		return t != ""
	case []any:
		return len(t) > 0
	case *object:
		return len(t.keys) > 0
	}
	return true
}

// pyStr is str(value) for the JSON values an error can carry.
func pyStr(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return "None"
	case bool:
		if t {
			return "True"
		}
		return "False"
	case *big.Int:
		return t.String()
	case float64:
		switch {
		case math.IsNaN(t):
			return "nan"
		case math.IsInf(t, 1):
			return "inf"
		case math.IsInf(t, -1):
			return "-inf"
		}
		return pyFloatRepr(t)
	}
	return string(encodeJSON(v))
}

// pyStringRepr is repr(str) for the printable keys used here.
func pyStringRepr(s string) string {
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		return `"` + s + `"`
	}
	return "'" + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), "'", `\'`) + "'"
}

func pyTypeName(v any) string {
	switch v.(type) {
	case nil:
		return "NoneType"
	case bool:
		return "bool"
	case *big.Int:
		return "int"
	case float64:
		return "float"
	case string:
		return "str"
	case []any:
		return "list"
	case *object:
		return "dict"
	}
	return "object"
}
