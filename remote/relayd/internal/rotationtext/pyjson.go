package rotationtext

// The text backend hashes, compares and journals JSON exactly as CPython's
// json module does: duplicate keys and NaN/Infinity are refused, integers keep
// arbitrary precision and stay distinct from floats, and compact() output is
// sorted, unescaped UTF-8 with Python float spelling. Every fingerprint,
// evidence_id and snapshot_id depends on these bytes, so encoding/json (which
// HTML-escapes, folds lone surrogates and loses int/float identity) is not used.
//
// Values: nil, bool, string, int64, *big.Int (only outside int64), float64,
// []any and map[string]any. A string holds WTF-8: a lone UTF-16 surrogate,
// which Python's json admits, is kept as its 3-byte generalized encoding so it
// can fail exactly where Python's str.encode() fails.

import (
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// draftError is text_backend's DraftError. unavailable marks a preflight
// failure that permits another provider; apiUsage is retained billing metadata.
type draftError struct {
	code        string
	unavailable bool
	apiUsage    map[string]any
}

func (e *draftError) Error() string { return e.code }

// Code lets an open error carry its DraftError code through RunOperation.
func (e *draftError) Code() string { return e.code }

func fail(code string)            { panic(&draftError{code: code}) }
func failUnavailable(code string) { panic(&draftError{code: code, unavailable: true}) }

// pyException stands for any other Python exception (ValueError, TypeError,
// UnicodeError, OverflowError, RecursionError). Python catches these only at
// "except Exception/BaseException" boundaries, which recoverPy mirrors.
type pyException struct{ kind string }

func raise(kind string) { panic(pyException{kind}) }

// recoverPy converts a panic raised by this package into its Python outcome.
// Foreign panics (programming errors) are re-raised.
func recoverPy(value any) (*draftError, *pyException) {
	switch e := value.(type) {
	case nil:
		return nil, nil
	case *draftError:
		return e, nil
	case pyException:
		return nil, &e
	}
	panic(value)
}

// maxJSONDepth approximates CPython's C-stack guard in the json scanner
// (about 116000 levels on a default 8 MiB stack; platform dependent).
const maxJSONDepth = 100000

// maxIntDigits is CPython's default int_max_str_digits.
const maxIntDigits = 4300

// parseJSON is text_backend.parse_json: a str or bytes document; anything else,
// and any decode/parse failure, is invalid_json.
func parseJSON(raw any) any {
	var text string
	switch value := raw.(type) {
	case string:
		if strings.HasPrefix(value, "\ufeff") {
			fail("invalid_json")
		}
		text = value
	case []byte:
		decoded, ok := decodeJSONBytes(value)
		if !ok {
			fail("invalid_json")
		}
		text = decoded
	default:
		fail("invalid_json")
	}
	parser := jsonParser{s: text}
	parser.ws()
	value, ok := parser.value(0)
	if !ok {
		fail("invalid_json")
	}
	parser.ws()
	if parser.i != len(parser.s) {
		fail("invalid_json")
	}
	return value
}

// decodeJSONBytes is json.detect_encoding plus bytes.decode(..., "surrogatepass").
func decodeJSONBytes(b []byte) (string, bool) {
	has := func(prefix ...byte) bool { return len(b) >= len(prefix) && string(b[:len(prefix)]) == string(prefix) }
	switch {
	case has(0x00, 0x00, 0xfe, 0xff):
		return decodeUTF32(b[4:], true)
	case has(0xff, 0xfe, 0x00, 0x00):
		return decodeUTF32(b[4:], false)
	case has(0xfe, 0xff):
		return decodeUTF16(b[2:], true)
	case has(0xff, 0xfe):
		return decodeUTF16(b[2:], false)
	case has(0xef, 0xbb, 0xbf):
		return decodeUTF8(b[3:])
	}
	if len(b) >= 4 {
		if b[0] == 0 {
			if b[1] != 0 {
				return decodeUTF16(b, true)
			}
			return decodeUTF32(b, true)
		}
		if b[1] == 0 {
			if b[2] != 0 || b[3] != 0 {
				return decodeUTF16(b, false)
			}
			return decodeUTF32(b, false)
		}
	} else if len(b) == 2 {
		if b[0] == 0 {
			return decodeUTF16(b, true)
		}
		if b[1] == 0 {
			return decodeUTF16(b, false)
		}
	}
	return decodeUTF8(b)
}

func decodeUTF8(b []byte) (string, bool) {
	for i := 0; i < len(b); {
		r, size := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && size == 1 {
			// surrogatepass admits an encoded UTF-16 surrogate.
			if i+2 < len(b) && b[i] == 0xed && b[i+1] >= 0xa0 && b[i+1] <= 0xbf && b[i+2] >= 0x80 && b[i+2] <= 0xbf {
				i += 3
				continue
			}
			return "", false
		}
		i += size
	}
	return string(b), true
}

func decodeUTF16(b []byte, bigEndian bool) (string, bool) {
	if len(b)%2 != 0 {
		return "", false
	}
	units := make([]uint16, len(b)/2)
	for i := range units {
		if bigEndian {
			units[i] = uint16(b[2*i])<<8 | uint16(b[2*i+1])
		} else {
			units[i] = uint16(b[2*i+1])<<8 | uint16(b[2*i])
		}
	}
	var out strings.Builder
	for i := 0; i < len(units); i++ {
		u := rune(units[i])
		if utf16.IsSurrogate(u) && u < 0xdc00 && i+1 < len(units) && units[i+1] >= 0xdc00 && units[i+1] <= 0xdfff {
			writeWTF8(&out, utf16.DecodeRune(u, rune(units[i+1])))
			i++
			continue
		}
		writeWTF8(&out, u)
	}
	return out.String(), true
}

func decodeUTF32(b []byte, bigEndian bool) (string, bool) {
	if len(b)%4 != 0 {
		return "", false
	}
	var out strings.Builder
	for i := 0; i < len(b); i += 4 {
		var u uint32
		if bigEndian {
			u = uint32(b[i])<<24 | uint32(b[i+1])<<16 | uint32(b[i+2])<<8 | uint32(b[i+3])
		} else {
			u = uint32(b[i+3])<<24 | uint32(b[i+2])<<16 | uint32(b[i+1])<<8 | uint32(b[i])
		}
		if u > unicode.MaxRune {
			return "", false
		}
		writeWTF8(&out, rune(u))
	}
	return out.String(), true
}

// writeWTF8 appends r, encoding a surrogate code point as its 3-byte form.
func writeWTF8(out *strings.Builder, r rune) {
	if r >= 0xd800 && r <= 0xdfff {
		out.WriteByte(byte(0xe0 | r>>12))
		out.WriteByte(byte(0x80 | (r>>6)&0x3f))
		out.WriteByte(byte(0x80 | r&0x3f))
		return
	}
	out.WriteRune(r)
}

// decodeWTF8 returns the code point at s[i:], including a lone surrogate.
func decodeWTF8(s string, i int) (rune, int) {
	if i+2 < len(s) && s[i] == 0xed && s[i+1] >= 0xa0 && s[i+1] <= 0xbf {
		return rune(s[i]&0x0f)<<12 | rune(s[i+1]&0x3f)<<6 | rune(s[i+2]&0x3f), 3
	}
	return utf8.DecodeRuneInString(s[i:])
}

type jsonParser struct {
	s string
	i int
}

func (p *jsonParser) ws() {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *jsonParser) value(depth int) (any, bool) {
	if p.i >= len(p.s) {
		return nil, false
	}
	switch c := p.s[p.i]; {
	case c == '{':
		return p.object(depth + 1)
	case c == '[':
		return p.array(depth + 1)
	case c == '"':
		return p.str()
	case c == 'n':
		return nil, p.literal("null")
	case c == 't':
		return true, p.literal("true")
	case c == 'f':
		return false, p.literal("false")
	case c == '-' || c >= '0' && c <= '9':
		return p.number()
	}
	// NaN and Infinity reach parse_constant, which text_backend refuses.
	return nil, false
}

func (p *jsonParser) literal(word string) bool {
	if strings.HasPrefix(p.s[p.i:], word) {
		p.i += len(word)
		return true
	}
	return false
}

func (p *jsonParser) object(depth int) (any, bool) {
	if depth > maxJSONDepth {
		return nil, false
	}
	p.i++
	out := map[string]any{}
	p.ws()
	if p.i < len(p.s) && p.s[p.i] == '}' {
		p.i++
		return out, true
	}
	for {
		if p.i >= len(p.s) || p.s[p.i] != '"' {
			return nil, false
		}
		key, ok := p.str()
		if !ok {
			return nil, false
		}
		p.ws()
		if p.i >= len(p.s) || p.s[p.i] != ':' {
			return nil, false
		}
		p.i++
		p.ws()
		value, ok := p.value(depth)
		if !ok {
			return nil, false
		}
		name := key.(string)
		if _, duplicate := out[name]; duplicate {
			return nil, false
		}
		out[name] = value
		p.ws()
		if p.i >= len(p.s) {
			return nil, false
		}
		if p.s[p.i] == '}' {
			p.i++
			return out, true
		}
		if p.s[p.i] != ',' {
			return nil, false
		}
		p.i++
		p.ws()
	}
}

func (p *jsonParser) array(depth int) (any, bool) {
	if depth > maxJSONDepth {
		return nil, false
	}
	p.i++
	out := []any{}
	p.ws()
	if p.i < len(p.s) && p.s[p.i] == ']' {
		p.i++
		return out, true
	}
	for {
		value, ok := p.value(depth)
		if !ok {
			return nil, false
		}
		out = append(out, value)
		p.ws()
		if p.i >= len(p.s) {
			return nil, false
		}
		if p.s[p.i] == ']' {
			p.i++
			return out, true
		}
		if p.s[p.i] != ',' {
			return nil, false
		}
		p.i++
		p.ws()
	}
}

func (p *jsonParser) hex4(at int) (rune, bool) {
	if at+4 > len(p.s) {
		return 0, false
	}
	value, err := strconv.ParseUint(p.s[at:at+4], 16, 32)
	if err != nil || strings.ContainsAny(p.s[at:at+4], "+-_xX") {
		return 0, false
	}
	return rune(value), true
}

func (p *jsonParser) str() (any, bool) {
	p.i++
	var out strings.Builder
	for {
		if p.i >= len(p.s) {
			return nil, false
		}
		c := p.s[p.i]
		switch {
		case c == '"':
			p.i++
			return out.String(), true
		case c < 0x20:
			return nil, false
		case c != '\\':
			start := p.i
			for p.i < len(p.s) && p.s[p.i] != '"' && p.s[p.i] != '\\' && p.s[p.i] >= 0x20 {
				p.i++
			}
			out.WriteString(p.s[start:p.i])
			continue
		}
		if p.i+1 >= len(p.s) {
			return nil, false
		}
		escape := p.s[p.i+1]
		p.i += 2
		switch escape {
		case '"', '\\', '/':
			out.WriteByte(escape)
		case 'b':
			out.WriteByte('\b')
		case 'f':
			out.WriteByte('\f')
		case 'n':
			out.WriteByte('\n')
		case 'r':
			out.WriteByte('\r')
		case 't':
			out.WriteByte('\t')
		case 'u':
			r, ok := p.hex4(p.i)
			if !ok {
				return nil, false
			}
			p.i += 4
			if r >= 0xd800 && r <= 0xdbff && p.i+6 < len(p.s) && p.s[p.i] == '\\' && p.s[p.i+1] == 'u' {
				low, ok := p.hex4(p.i + 2)
				if !ok {
					return nil, false
				}
				if low >= 0xdc00 && low <= 0xdfff {
					r = utf16.DecodeRune(r, low)
					p.i += 6
				}
			}
			writeWTF8(&out, r)
		default:
			return nil, false
		}
	}
}

func (p *jsonParser) number() (any, bool) {
	start := p.i
	if p.s[p.i] == '-' {
		p.i++
	}
	digits := p.i
	if p.i >= len(p.s) || p.s[p.i] < '0' || p.s[p.i] > '9' {
		return nil, false // "-" alone, or -Infinity
	}
	if p.s[p.i] == '0' {
		p.i++
	} else {
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i++
		}
	}
	integerEnd := p.i
	float := false
	if p.i+1 < len(p.s) && p.s[p.i] == '.' && p.s[p.i+1] >= '0' && p.s[p.i+1] <= '9' {
		float = true
		p.i += 2
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i++
		}
	}
	if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
		j := p.i + 1
		if j < len(p.s) && (p.s[j] == '+' || p.s[j] == '-') {
			j++
		}
		if j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' {
			for j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' {
				j++
			}
			float = true
			p.i = j
		}
	}
	text := p.s[start:p.i]
	if float {
		value, err := strconv.ParseFloat(text, 64)
		if err != nil && !isRangeError(err) {
			return nil, false
		}
		return value, true
	}
	if integerEnd-digits > maxIntDigits {
		return nil, false
	}
	if value, err := strconv.ParseInt(text, 10, 64); err == nil {
		return value, true
	}
	value, ok := new(big.Int).SetString(text, 10)
	return value, ok
}

func isRangeError(err error) bool {
	numErr, ok := err.(*strconv.NumError)
	return ok && numErr.Err == strconv.ErrRange
}

// compact is json.dumps(value, ensure_ascii=False, sort_keys=True,
// separators=(",", ":"), allow_nan=False). The result may contain a lone
// surrogate; callers that need bytes use encodeUTF8 as Python's .encode() does.
func compact(value any) string {
	var out strings.Builder
	writeCompact(&out, value)
	return out.String()
}

func writeCompact(out *strings.Builder, value any) {
	switch v := value.(type) {
	case nil:
		out.WriteString("null")
	case bool:
		if v {
			out.WriteString("true")
		} else {
			out.WriteString("false")
		}
	case string:
		writeCompactString(out, v)
	case int64:
		out.WriteString(strconv.FormatInt(v, 10))
	case *big.Int:
		text := v.String()
		if len(strings.TrimPrefix(text, "-")) > maxIntDigits {
			raise("ValueError")
		}
		out.WriteString(text)
	case float64:
		if math.IsInf(v, 0) || math.IsNaN(v) {
			raise("ValueError")
		}
		out.WriteString(pyFloatRepr(v))
	case []any:
		out.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				out.WriteByte(',')
			}
			writeCompact(out, item)
		}
		out.WriteByte(']')
	case []string:
		items := make([]any, len(v))
		for i, item := range v {
			items[i] = item
		}
		writeCompact(out, items)
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		// WTF-8 byte order is code point order, as Python sorts str keys.
		sort.Strings(keys)
		out.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				out.WriteByte(',')
			}
			writeCompactString(out, key)
			out.WriteByte(':')
			writeCompact(out, v[key])
		}
		out.WriteByte('}')
	default:
		raise("TypeError")
	}
}

func writeCompactString(out *strings.Builder, s string) {
	const hexDigits = "0123456789abcdef"
	out.WriteByte('"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		out.WriteString(s[start:i])
		switch c {
		case '"':
			out.WriteString(`\"`)
		case '\\':
			out.WriteString(`\\`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		default:
			out.WriteString(`\u00`)
			out.WriteByte(hexDigits[c>>4])
			out.WriteByte(hexDigits[c&0xf])
		}
		start = i + 1
	}
	out.WriteString(s[start:])
	out.WriteByte('"')
}

// pyFloatRepr is float.__repr__: shortest round-trip digits, positional for
// decimal exponents in (-4, 16], otherwise d.ddde±XX.
func pyFloatRepr(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	sign := ""
	if f < 0 {
		sign, f = "-", -f
	}
	text := strconv.FormatFloat(f, 'e', -1, 64)
	mantissa, exponent, _ := strings.Cut(text, "e")
	exp, _ := strconv.Atoi(exponent)
	digits := strings.Replace(mantissa, ".", "", 1)
	decpt := exp + 1
	switch {
	case decpt <= -4 || decpt > 16:
		body := digits[:1]
		if len(digits) > 1 {
			body += "." + digits[1:]
		}
		expSign := "+"
		if exp < 0 {
			expSign, exp = "-", -exp
		}
		expText := strconv.Itoa(exp)
		if len(expText) < 2 {
			expText = "0" + expText
		}
		return sign + body + "e" + expSign + expText
	case decpt <= 0:
		return sign + "0." + strings.Repeat("0", -decpt) + digits
	case decpt >= len(digits):
		return sign + digits + strings.Repeat("0", decpt-len(digits)) + ".0"
	}
	return sign + digits[:decpt] + "." + digits[decpt:]
}

// encodeUTF8 is str.encode(): a lone surrogate raises UnicodeEncodeError.
func encodeUTF8(s string) []byte {
	if hasSurrogate(s) {
		raise("UnicodeEncodeError")
	}
	return []byte(s)
}

func encodedLen(s string) int { return len(encodeUTF8(s)) }

func hasSurrogate(s string) bool {
	for i := 0; i+2 < len(s); i++ {
		if s[i] == 0xed && s[i+1] >= 0xa0 && s[i+1] <= 0xbf {
			return true
		}
	}
	return false
}

// pyLen is len(str): code points, a lone surrogate counting once.
func pyLen(s string) int {
	n := 0
	for i := 0; i < len(s); {
		_, size := decodeWTF8(s, i)
		i += size
		n++
	}
	return n
}

// pyIsSpace is str.isspace for one code point.
func pyIsSpace(r rune) bool {
	switch {
	case r >= 0x09 && r <= 0x0d, r >= 0x1c && r <= 0x20, r == 0x85, r == 0xa0, r == 0x1680,
		r >= 0x2000 && r <= 0x200a, r == 0x2028, r == 0x2029, r == 0x202f, r == 0x205f, r == 0x3000:
		return true
	}
	return false
}

// pyStrip is str.strip() with no arguments.
func pyStrip(s string) string {
	start, end := 0, len(s)
	for start < end {
		r, size := decodeWTF8(s, start)
		if !pyIsSpace(r) {
			break
		}
		start += size
	}
	for end > start {
		i := end - 1
		for i > start && s[i]&0xc0 == 0x80 {
			i--
		}
		r, _ := decodeWTF8(s, i)
		if !pyIsSpace(r) {
			break
		}
		end = i
	}
	return s[start:end]
}

func blank(s string) bool { return pyStrip(s) == "" }

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// validKey is key.isascii() and 16 <= len(key) <= 512 with no whitespace.
func validKey(key string) bool {
	if !isASCII(key) || len(key) < 16 || len(key) > 512 {
		return false
	}
	for i := 0; i < len(key); i++ {
		if pyIsSpace(rune(key[i])) {
			return false
		}
	}
	return true
}

// isInt is type(value) is int (bool excluded).
func isInt(value any) bool {
	switch value.(type) {
	case int64, *big.Int:
		return true
	}
	return false
}

func bigOf(value any) *big.Int {
	switch v := value.(type) {
	case int64:
		return big.NewInt(v)
	case *big.Int:
		return v
	case bool:
		if v {
			return big.NewInt(1)
		}
		return big.NewInt(0)
	}
	return nil
}

// intIn is type(value) is int and lo <= value <= hi.
func intIn(value any, lo, hi *big.Int) bool {
	if !isInt(value) {
		return false
	}
	v := bigOf(value)
	return (lo == nil || v.Cmp(lo) >= 0) && (hi == nil || v.Cmp(hi) <= 0)
}

func bigInt(v int64) *big.Int { return big.NewInt(v) }

// normInt stores an integer result in the smallest representation.
func normInt(v *big.Int) any {
	if v.IsInt64() {
		return v.Int64()
	}
	return v
}

func isStr(value any) bool { _, ok := value.(string); return ok }

// truthy is bool(value).
func truthy(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return v != ""
	case int64:
		return v != 0
	case *big.Int:
		return v.Sign() != 0
	case float64:
		return v != 0
	case []any:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	}
	return true
}

// pyEqual is Python ==, including True == 1 == 1.0.
func pyEqual(a, b any) bool {
	if na, ok := numeric(a); ok {
		nb, ok := numeric(b)
		return ok && na.Cmp(nb) == 0
	}
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !pyEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	case []string:
		items := make([]any, len(x))
		for i, s := range x {
			items[i] = s
		}
		return pyEqual(items, b)
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for key, value := range x {
			other, ok := y[key]
			if !ok || !pyEqual(value, other) {
				return false
			}
		}
		return true
	}
	return false
}

// numeric returns an exact rational for bool, int and finite float values.
func numeric(value any) (*big.Rat, bool) {
	switch v := value.(type) {
	case bool, int64, *big.Int:
		return new(big.Rat).SetInt(bigOf(v)), true
	case float64:
		if math.IsInf(v, 0) || math.IsNaN(v) {
			// inf == inf holds in Python; compare through a sentinel.
			return nil, false
		}
		return new(big.Rat).SetFloat64(v), true
	}
	return nil, false
}

// requireHashable raises TypeError, as Python does when an unhashable list or
// dict is tested for set membership.
func requireHashable(value any) {
	switch value.(type) {
	case []any, map[string]any:
		raise("TypeError")
	}
}

// keysEqual is set(m) == set(keys).
func keysEqual(m map[string]any, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, ok := m[key]; !ok {
			return false
		}
	}
	return true
}

// keysWithin is not (set(m) - set(keys)).
func keysWithin(m map[string]any, keys ...string) bool {
	for key := range m {
		found := false
		for _, allowed := range keys {
			if key == allowed {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// hasKeys is set(keys).issubset(m).
func hasKeys(m map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := m[key]; !ok {
			return false
		}
	}
	return true
}

// strIn is value in (choices...) for a tuple of strings.
func strIn(value any, choices ...string) bool {
	s, ok := value.(string)
	if !ok {
		return false
	}
	for _, choice := range choices {
		if s == choice {
			return true
		}
	}
	return false
}

// listContains is value in list (Python == membership).
func listContains(list []any, value any) bool {
	for _, item := range list {
		if pyEqual(item, value) {
			return true
		}
	}
	return false
}
