package nativemsg

import (
	"fmt"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
)

// The adapter's JSON is Python's json module: json.loads accepts NaN and
// Infinity, keeps int and float apart, and names the failing character in
// its errors; json.dumps escapes every non-ASCII character.

const jsonMaxDepth = 900

// loadsBytes is json.loads(bytes): the encoding is detected and decoded with
// 'surrogatepass' first.
func loadsBytes(data []byte) (any, error) {
	switch {
	case hasPrefix(data, "\x00\x00\xfe\xff"), hasPrefix(data, "\xff\xfe\x00\x00"),
		hasPrefix(data, "\xfe\xff"), hasPrefix(data, "\xff\xfe"):
		return nil, valueError("UTF-16 and UTF-32 JSON are not supported")
	case hasPrefix(data, "\xef\xbb\xbf"):
		data = data[3:]
	case len(data) >= 4 && (data[0] == 0 || data[1] == 0), len(data) == 2 && (data[0] == 0 || data[1] == 0):
		return nil, valueError("UTF-16 and UTF-32 JSON are not supported")
	}
	runes, err := decodeUTF8(data, true)
	if err != nil {
		return nil, err
	}
	return loadsRunes(runes)
}

// loadsText is json.loads(str) of bytes decoded with .decode() (strict UTF-8).
func loadsText(data []byte) (any, error) {
	runes, err := decodeUTF8(data, false)
	if err != nil {
		return nil, err
	}
	if len(runes) > 0 && runes[0] == 0xFEFF {
		return nil, jsonError("Unexpected UTF-8 BOM (decode using utf-8-sig)", runes, 0)
	}
	return loadsRunes(runes)
}

func hasPrefix(data []byte, prefix string) bool { return strings.HasPrefix(string(data), prefix) }

func loadsRunes(s []rune) (any, error) {
	d := &jsonDecoder{s: s}
	idx := d.skip(0)
	value, end, err := d.scan(idx, 0)
	if err != nil {
		return nil, err
	}
	end = d.skip(end)
	if end != len(s) {
		return nil, jsonError("Extra data", s, end)
	}
	return value, nil
}

// jsonError is str(json.JSONDecodeError(msg, doc, pos)).
func jsonError(msg string, doc []rune, pos int) error {
	line, column := 1, pos+1
	for i := 0; i < pos && i < len(doc); i++ {
		if doc[i] == '\n' {
			line++
			column = pos - i
		}
	}
	return &pyErr{class: classJSON, msg: fmt.Sprintf("%s: line %d column %d (char %d)", msg, line, column, pos)}
}

type jsonDecoder struct{ s []rune }

type stopIteration struct{ pos int }

func (stopIteration) Error() string { return "StopIteration" }

func (d *jsonDecoder) skip(i int) int {
	for i < len(d.s) && (d.s[i] == ' ' || d.s[i] == '\t' || d.s[i] == '\n' || d.s[i] == '\r') {
		i++
	}
	return i
}

func (d *jsonDecoder) word(i int, word string) bool {
	runes := []rune(word)
	if i+len(runes) > len(d.s) {
		return false
	}
	for j, r := range runes {
		if d.s[i+j] != r {
			return false
		}
	}
	return true
}

// scan is the C scanner's scan_once; a value that does not start at idx is
// "Expecting value" at idx.
func (d *jsonDecoder) scan(idx, depth int) (any, int, error) {
	value, end, err := d.scanOnce(idx, depth)
	if stop, ok := err.(stopIteration); ok {
		return nil, 0, jsonError("Expecting value", d.s, stop.pos)
	}
	return value, end, err
}

func (d *jsonDecoder) scanOnce(idx, depth int) (any, int, error) {
	if idx >= len(d.s) {
		return nil, 0, stopIteration{idx}
	}
	if depth > jsonMaxDepth {
		return nil, 0, &pyErr{class: classRuntime, msg: "maximum recursion depth exceeded while decoding a JSON document"}
	}
	switch d.s[idx] {
	case '"':
		return d.scanString(idx + 1)
	case '{':
		return d.parseObject(idx+1, depth+1)
	case '[':
		return d.parseArray(idx+1, depth+1)
	case 'n':
		if d.word(idx, "null") {
			return nil, idx + 4, nil
		}
	case 't':
		if d.word(idx, "true") {
			return true, idx + 4, nil
		}
	case 'f':
		if d.word(idx, "false") {
			return false, idx + 5, nil
		}
	case 'N':
		if d.word(idx, "NaN") {
			return math.NaN(), idx + 3, nil
		}
	case 'I':
		if d.word(idx, "Infinity") {
			return math.Inf(1), idx + 8, nil
		}
	case '-':
		if d.word(idx, "-Infinity") {
			return math.Inf(-1), idx + 9, nil
		}
	}
	return d.number(idx)
}

func digit(r rune) bool { return r >= '0' && r <= '9' }

func (d *jsonDecoder) number(start int) (any, int, error) {
	s, idx, end := d.s, start, len(d.s)-1
	if s[idx] == '-' {
		idx++
		if idx > end {
			return nil, 0, stopIteration{start}
		}
	}
	switch {
	case s[idx] >= '1' && s[idx] <= '9':
		idx++
		for idx <= end && digit(s[idx]) {
			idx++
		}
	case s[idx] == '0':
		idx++
	default:
		return nil, 0, stopIteration{start}
	}
	isFloat := false
	if idx < end && s[idx] == '.' && digit(s[idx+1]) {
		isFloat = true
		idx += 2
		for idx <= end && digit(s[idx]) {
			idx++
		}
	}
	if idx < end && (s[idx] == 'e' || s[idx] == 'E') {
		eStart := idx
		idx++
		if idx < end && (s[idx] == '-' || s[idx] == '+') {
			idx++
		}
		for idx <= end && digit(s[idx]) {
			idx++
		}
		if digit(s[idx-1]) {
			isFloat = true
		} else {
			idx = eStart
		}
	}
	text := string(s[start:idx])
	if isFloat {
		f, err := strconv.ParseFloat(text, 64)
		if err != nil && !math.IsInf(f, 0) {
			return nil, 0, valueError("could not convert string to float: " + reprString(text))
		}
		return f, idx, nil
	}
	if n, err := strconv.ParseInt(text, 10, 64); err == nil {
		return n, idx, nil
	}
	n, _ := new(big.Int).SetString(text, 10)
	return n, idx, nil
}

func (d *jsonDecoder) parseObject(idx, depth int) (any, int, error) {
	s, end := d.s, len(d.s)-1
	result := map[string]any{}
	idx = d.skip(idx)
	if idx > end || s[idx] != '}' {
		for {
			if idx > end || s[idx] != '"' {
				return nil, 0, jsonError("Expecting property name enclosed in double quotes", s, idx)
			}
			key, next, err := d.scanString(idx + 1)
			if err != nil {
				return nil, 0, err
			}
			idx = d.skip(next)
			if idx > end || s[idx] != ':' {
				return nil, 0, jsonError("Expecting ':' delimiter", s, idx)
			}
			idx = d.skip(idx + 1)
			value, next, err := d.scanOnce(idx, depth)
			if err != nil {
				return nil, 0, err
			}
			result[key.(string)] = value
			idx = d.skip(next)
			if idx <= end && s[idx] == '}' {
				break
			}
			if idx > end || s[idx] != ',' {
				return nil, 0, jsonError("Expecting ',' delimiter", s, idx)
			}
			idx = d.skip(idx + 1)
		}
	}
	return result, idx + 1, nil
}

func (d *jsonDecoder) parseArray(idx, depth int) (any, int, error) {
	s, end := d.s, len(d.s)-1
	result := []any{}
	idx = d.skip(idx)
	if idx > end || s[idx] != ']' {
		for {
			value, next, err := d.scanOnce(idx, depth)
			if err != nil {
				return nil, 0, err
			}
			result = append(result, value)
			idx = d.skip(next)
			if idx <= end && s[idx] == ']' {
				break
			}
			if idx > end || s[idx] != ',' {
				return nil, 0, jsonError("Expecting ',' delimiter", s, idx)
			}
			idx = d.skip(idx + 1)
		}
	}
	return result, idx + 1, nil
}

func hexValue(r rune) (rune, bool) {
	switch {
	case r >= '0' && r <= '9':
		return r - '0', true
	case r >= 'a' && r <= 'f':
		return r - 'a' + 10, true
	case r >= 'A' && r <= 'F':
		return r - 'A' + 10, true
	}
	return 0, false
}

// scanString is the C scanstring with strict=True; end is just after the
// opening quote.
func (d *jsonDecoder) scanString(end int) (any, int, error) {
	s, length := d.s, len(d.s)
	begin := end - 1
	var out []rune
	for {
		var c rune
		next := end
		for ; next < length; next++ {
			c = s[next]
			if c == '"' || c == '\\' {
				break
			}
			if c <= 0x1f {
				return nil, 0, jsonError("Invalid control character at", s, next)
			}
		}
		if next >= length || !(c == '"' || c == '\\') {
			return nil, 0, jsonError("Unterminated string starting at", s, begin)
		}
		out = append(out, s[end:next]...)
		next++
		if c == '"' {
			end = next
			break
		}
		if next == length {
			return nil, 0, jsonError("Unterminated string starting at", s, begin)
		}
		c = s[next]
		if c != 'u' {
			end = next + 1
			switch c {
			case '"', '\\', '/':
			case 'b':
				c = '\b'
			case 'f':
				c = '\f'
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 't':
				c = '\t'
			default:
				return nil, 0, jsonError("Invalid \\escape", s, end-2)
			}
		} else {
			c = 0
			next++
			end = next + 4
			if end >= length {
				return nil, 0, jsonError("Invalid \\uXXXX escape", s, next-1)
			}
			for ; next < end; next++ {
				v, ok := hexValue(s[next])
				if !ok {
					return nil, 0, jsonError("Invalid \\uXXXX escape", s, end-5)
				}
				c = c<<4 | v
			}
			if c >= 0xD800 && c <= 0xDBFF && end+6 < length && s[next] == '\\' && s[next+1] == 'u' {
				next += 2
				var c2 rune
				end += 6
				for ; next < end; next++ {
					v, ok := hexValue(s[next])
					if !ok {
						return nil, 0, jsonError("Invalid \\uXXXX escape", s, end-5)
					}
					c2 = c2<<4 | v
				}
				if c2 >= 0xDC00 && c2 <= 0xDFFF {
					c = 0x10000 + (c-0xD800)<<10 + (c2 - 0xDC00)
				} else {
					end -= 6
				}
			}
		}
		out = append(out, c)
	}
	return pyString(out), end, nil
}

// decodeUTF8 is bytes.decode('utf-8'), with 'surrogatepass' when allowed.
func decodeUTF8(data []byte, surrogatePass bool) ([]rune, error) {
	var out []rune
	cont := func(b byte) bool { return b&0xC0 == 0x80 }
	for i := 0; i < len(data); {
		b := data[i]
		if b < 0x80 {
			out = append(out, rune(b))
			i++
			continue
		}
		var need int
		switch {
		case b >= 0xC2 && b <= 0xDF:
			need = 2
		case b >= 0xE0 && b <= 0xEF:
			need = 3
		case b >= 0xF0 && b <= 0xF4:
			need = 4
		default:
			return nil, utf8Error(data, i, i+1, "invalid start byte")
		}
		valid := 1
		for valid < need && i+valid < len(data) {
			c := data[i+valid]
			ok := cont(c)
			if valid == 1 {
				switch b {
				case 0xE0:
					ok = c >= 0xA0 && c <= 0xBF
				case 0xED:
					ok = c >= 0x80 && c <= 0x9F
				case 0xF0:
					ok = c >= 0x90 && c <= 0xBF
				case 0xF4:
					ok = c >= 0x80 && c <= 0x8F
				}
			}
			if !ok {
				break
			}
			valid++
		}
		if valid < need {
			if surrogatePass && b == 0xED && i+2 < len(data) && data[i+1] >= 0xA0 && data[i+1] <= 0xBF && cont(data[i+2]) {
				out = append(out, rune(0xD000|rune(data[i+1]&0x3F)<<6|rune(data[i+2]&0x3F)))
				i += 3
				continue
			}
			if i+valid >= len(data) {
				return nil, utf8Error(data, i, len(data), "unexpected end of data")
			}
			return nil, utf8Error(data, i, i+valid, "invalid continuation byte")
		}
		r := rune(b) & (0xFF >> (need + 1))
		for j := 1; j < need; j++ {
			r = r<<6 | rune(data[i+j]&0x3F)
		}
		out = append(out, r)
		i += need
	}
	return out, nil
}

func utf8Error(data []byte, start, end int, reason string) error {
	if end-start == 1 {
		return &pyErr{class: classUnicode, msg: fmt.Sprintf("'utf-8' codec can't decode byte 0x%02x in position %d: %s", data[start], start, reason)}
	}
	return &pyErr{class: classUnicode, msg: fmt.Sprintf("'utf-8' codec can't decode bytes in position %d-%d: %s", start, end-1, reason)}
}

// dumps is json.dumps(value) with ensure_ascii; sortKeys orders every dict,
// otherwise an obj keeps its insertion order.
func dumps(value any, sortKeys bool) string {
	var b strings.Builder
	writeJSON(&b, value, sortKeys)
	return b.String()
}

func writeJSON(b *strings.Builder, value any, sortKeys bool) {
	switch v := value.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if v {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int:
		b.WriteString(strconv.Itoa(v))
	case int64:
		b.WriteString(strconv.FormatInt(v, 10))
	case *big.Int:
		b.WriteString(v.String())
	case float64:
		switch {
		case math.IsNaN(v):
			b.WriteString("NaN")
		case math.IsInf(v, 1):
			b.WriteString("Infinity")
		case math.IsInf(v, -1):
			b.WriteString("-Infinity")
		default:
			b.WriteString(pyFloatRepr(v))
		}
	case string:
		writeJSONString(b, v)
	case []any:
		b.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				b.WriteString(", ")
			}
			writeJSON(b, item, sortKeys)
		}
		b.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteString(", ")
			}
			writeJSONString(b, key)
			b.WriteString(": ")
			writeJSON(b, v[key], sortKeys)
		}
		b.WriteByte('}')
	case obj:
		items := v
		if sortKeys {
			items = append(obj(nil), v...)
			sort.SliceStable(items, func(i, j int) bool { return items[i].k < items[j].k })
		}
		b.WriteByte('{')
		for i, item := range items {
			if i > 0 {
				b.WriteString(", ")
			}
			writeJSONString(b, item.k)
			b.WriteString(": ")
			writeJSON(b, item.v, sortKeys)
		}
		b.WriteByte('}')
	default:
		panic(fmt.Sprintf("nativemsg: no JSON form for %T", value))
	}
}

func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range pyRunes(s) {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r >= ' ' && r <= '~':
			b.WriteRune(r)
		case r > 0xFFFF:
			r -= 0x10000
			fmt.Fprintf(b, `\u%04x\u%04x`, 0xD800|(r>>10)&0x3FF, 0xDC00|r&0x3FF)
		default:
			fmt.Fprintf(b, `\u%04x`, r)
		}
	}
	b.WriteByte('"')
}
