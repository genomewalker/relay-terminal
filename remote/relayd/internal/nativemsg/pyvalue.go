package nativemsg

import (
	"fmt"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Values follow Python's json module: nil, bool, string, int64 or *big.Int,
// float64, []any and map[string]any. obj is a dict whose insertion order
// json.dumps keeps; maps are always written in sorted order, which is the
// order Go's json.Marshal gave every packet the adapter receives.
type obj []kv

type kv struct {
	k string
	v any
}

func (o obj) get(key string) (any, bool) {
	for _, item := range o {
		if item.k == key {
			return item.v, true
		}
	}
	return nil, false
}

func pyTypeName(value any) string {
	switch value.(type) {
	case nil:
		return "NoneType"
	case bool:
		return "bool"
	case int, int64, *big.Int:
		return "int"
	case float64:
		return "float"
	case string:
		return "str"
	case []any:
		return "list"
	case map[string]any, obj:
		return "dict"
	}
	return fmt.Sprintf("%T", value)
}

// pyInt reports isinstance(value, int), which includes bool.
func pyInt(value any) (*big.Int, bool) {
	switch v := value.(type) {
	case bool:
		if v {
			return big.NewInt(1), true
		}
		return big.NewInt(0), true
	case int:
		return big.NewInt(int64(v)), true
	case int64:
		return big.NewInt(v), true
	case *big.Int:
		return v, true
	}
	return nil, false
}

// intNotBool reports isinstance(value, int) and not isinstance(value, bool).
func intNotBool(value any) (*big.Int, bool) {
	if _, ok := value.(bool); ok {
		return nil, false
	}
	return pyInt(value)
}

// smallInt is a Python int that fits a PID-sized Go int.
func smallInt(value any) (int64, bool) {
	n, ok := pyInt(value)
	if !ok || !n.IsInt64() {
		return 0, false
	}
	return n.Int64(), true
}

func isDict(value any) bool {
	switch value.(type) {
	case map[string]any, obj:
		return true
	}
	return false
}

// pyGet is value.get(key, fallback); a non-dict raises AttributeError.
func pyGet(value any, key string, fallback any) (any, error) {
	switch v := value.(type) {
	case map[string]any:
		if item, ok := v[key]; ok {
			return item, nil
		}
		return fallback, nil
	case obj:
		if item, ok := v.get(key); ok {
			return item, nil
		}
		return fallback, nil
	}
	return nil, attributeError(value, "get")
}

// pyIndex is value[key] for a string key.
func pyIndex(value any, key string) (any, error) {
	switch v := value.(type) {
	case map[string]any:
		if item, ok := v[key]; ok {
			return item, nil
		}
		return nil, keyError(key)
	case obj:
		if item, ok := v.get(key); ok {
			return item, nil
		}
		return nil, keyError(key)
	case []any:
		return nil, typeError("list indices must be integers or slices, not str")
	case string:
		return nil, typeError("string indices must be integers")
	}
	return nil, typeError(fmt.Sprintf("'%s' object is not subscriptable", pyTypeName(value)))
}

// pyHas is `key in value` for a dict.
func pyHas(value any, key string) (bool, error) {
	switch v := value.(type) {
	case map[string]any:
		_, ok := v[key]
		return ok, nil
	case obj:
		_, ok := v.get(key)
		return ok, nil
	case string:
		return strings.Contains(v, key), nil
	case []any:
		for _, item := range v {
			if pyEqual(item, key) {
				return true, nil
			}
		}
		return false, nil
	}
	return false, typeError(fmt.Sprintf("argument of type '%s' is not iterable", pyTypeName(value)))
}

// pyContains is `item in container` for any JSON container.
func pyContains(container, item any) (bool, error) {
	switch c := container.(type) {
	case []any:
		for _, element := range c {
			if pyEqual(element, item) {
				return true, nil
			}
		}
		return false, nil
	case string:
		s, ok := item.(string)
		if !ok {
			return false, typeError(fmt.Sprintf("'in <string>' requires string as left operand, not %s", pyTypeName(item)))
		}
		return strings.Contains(c, s), nil
	case map[string]any, obj:
		switch item.(type) {
		case []any, map[string]any, obj:
			return false, typeError(fmt.Sprintf("unhashable type: '%s'", pyTypeName(item)))
		}
		s, ok := item.(string)
		if !ok {
			return false, nil
		}
		return pyHas(c, s)
	}
	return false, typeError(fmt.Sprintf("argument of type '%s' is not iterable", pyTypeName(container)))
}

// pyIn is `value in (choices...)` for a tuple of strings.
func pyIn(value any, choices ...string) bool {
	for _, choice := range choices {
		if pyEqual(value, choice) {
			return true
		}
	}
	return false
}

func pyTruthy(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case int:
		return v != 0
	case int64:
		return v != 0
	case *big.Int:
		return v.Sign() != 0
	case float64:
		return v != 0
	case string:
		return v != ""
	case []any:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	case obj:
		return len(v) > 0
	}
	return true
}

func numeric(value any) (*big.Int, float64, bool, bool) {
	if n, ok := pyInt(value); ok {
		return n, 0, false, true
	}
	if f, ok := value.(float64); ok {
		return nil, f, true, true
	}
	return nil, 0, false, false
}

// pyEqual is Python ==: numbers compare by value across int, float and bool.
func pyEqual(a, b any) bool {
	an, af, aFloat, aNum := numeric(a)
	bn, bf, bFloat, bNum := numeric(b)
	if aNum || bNum {
		if !aNum || !bNum {
			return false
		}
		switch {
		case !aFloat && !bFloat:
			return an.Cmp(bn) == 0
		case aFloat && bFloat:
			return af == bf
		case aFloat:
			return floatEqualsInt(af, bn)
		default:
			return floatEqualsInt(bf, an)
		}
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
	case map[string]any, obj:
		if !isDict(b) {
			return false
		}
		xs, ys := dictItems(a), dictItems(b)
		if len(xs) != len(ys) {
			return false
		}
		for key, value := range xs {
			other, ok := ys[key]
			if !ok || !pyEqual(value, other) {
				return false
			}
		}
		return true
	}
	return false
}

func floatEqualsInt(f float64, n *big.Int) bool {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return false
	}
	return new(big.Float).SetFloat64(f).Cmp(new(big.Float).SetInt(n)) == 0
}

func dictItems(value any) map[string]any {
	switch v := value.(type) {
	case map[string]any:
		return v
	case obj:
		result := make(map[string]any, len(v))
		for _, item := range v {
			result[item.k] = item.v
		}
		return result
	}
	return nil
}

// pyRunes decodes a string as Python sees it: lone surrogates kept as
// WTF-8 come back as surrogate code points, undecodable bytes as \udcXX
// (os.fsdecode's surrogateescape).
func pyRunes(s string) []rune {
	result := make([]rune, 0, len(s))
	for i := 0; i < len(s); {
		if s[i] == 0xED && i+2 < len(s) && s[i+1] >= 0xA0 && s[i+1] <= 0xBF && s[i+2]&0xC0 == 0x80 {
			result = append(result, rune(0xD000|rune(s[i+1]&0x3F)<<6|rune(s[i+2]&0x3F)))
			i += 3
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			result = append(result, rune(0xDC00+int(s[i])))
		} else {
			result = append(result, r)
		}
		i += size
	}
	return result
}

// pyString encodes code points back, keeping lone surrogates as WTF-8.
func pyString(runes []rune) string {
	var b strings.Builder
	for _, r := range runes {
		if r >= 0xD800 && r <= 0xDFFF {
			b.WriteByte(0xED)
			b.WriteByte(byte(0xA0 | (r>>6)&0x1F))
			b.WriteByte(byte(0x80 | r&0x3F))
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func pyLen(s string) int { return len(pyRunes(s)) }

// pySlice is s[:n] in code points.
func pySlice(s string, n int) string {
	runes := pyRunes(s)
	if len(runes) <= n {
		return s
	}
	return pyString(runes[:n])
}

// pyEncode is s.encode() (UTF-8, strict): a lone surrogate cannot be encoded.
func pyEncode(s string) ([]byte, error) {
	for i, r := range pyRunes(s) {
		if r >= 0xD800 && r <= 0xDFFF {
			return nil, &pyErr{class: classUnicode, msg: fmt.Sprintf(
				"'utf-8' codec can't encode character '\\u%04x' in position %d: surrogates not allowed", r, i)}
		}
	}
	return []byte(s), nil
}

// pyIsSpace is str.isspace for one character.
func pyIsSpace(r rune) bool {
	return unicode.IsSpace(r) || (r >= 0x1C && r <= 0x1F)
}

func pyStrip(s string) string {
	runes := pyRunes(s)
	start, end := 0, len(runes)
	for start < end && pyIsSpace(runes[start]) {
		start++
	}
	for end > start && pyIsSpace(runes[end-1]) {
		end--
	}
	return pyString(runes[start:end])
}

// pySplit is str.split() with no separator.
func pySplit(s string) []string {
	var fields []string
	var current []rune
	in := false
	for _, r := range pyRunes(s) {
		if pyIsSpace(r) {
			if in {
				fields = append(fields, pyString(current))
				current, in = nil, false
			}
			continue
		}
		current, in = append(current, r), true
	}
	if in {
		fields = append(fields, pyString(current))
	}
	return fields
}

func pyLower(s string) string {
	runes := pyRunes(s)
	for i, r := range runes {
		runes[i] = unicode.ToLower(r)
	}
	return pyString(runes)
}

// pyHTMLEscape is html.escape(s, quote=True).
func pyHTMLEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return strings.ReplaceAll(s, "'", "&#x27;")
}

// pyFloatRepr is repr(float).
func pyFloatRepr(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	}
	text := strconv.FormatFloat(f, 'e', -1, 64)
	sign := ""
	if text[0] == '-' {
		sign, text = "-", text[1:]
	}
	mantissa, exponent, _ := strings.Cut(text, "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	exp, _ := strconv.Atoi(exponent)
	point := exp + 1
	if point <= -4 || point > 16 {
		result := digits[:1]
		if len(digits) > 1 {
			result += "." + digits[1:]
		}
		e := point - 1
		esign := "+"
		if e < 0 {
			esign, e = "-", -e
		}
		return fmt.Sprintf("%s%se%s%02d", sign, result, esign, e)
	}
	switch {
	case point <= 0:
		return sign + "0." + strings.Repeat("0", -point) + digits
	case point >= len(digits):
		return sign + digits + strings.Repeat("0", point-len(digits)) + ".0"
	}
	return sign + digits[:point] + "." + digits[point:]
}

// pyStrRepr is repr(str).
func pyRepr(value any) string {
	switch v := value.(type) {
	case string:
		return reprString(v)
	case nil:
		return "None"
	case bool:
		if v {
			return "True"
		}
		return "False"
	case int:
		return strconv.Itoa(v)
	case int64:
		return strconv.FormatInt(v, 10)
	case *big.Int:
		return v.String()
	case float64:
		return pyFloatRepr(v)
	case []any:
		parts := make([]string, len(v))
		for i, item := range v {
			parts[i] = pyRepr(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case map[string]any, obj:
		items := dictItems(v)
		keys := make([]string, 0, len(items))
		for key := range items {
			keys = append(keys, key)
		}
		if o, ok := v.(obj); ok {
			keys = keys[:0]
			for _, item := range o {
				keys = append(keys, item.k)
			}
		} else {
			sort.Strings(keys)
		}
		parts := make([]string, len(keys))
		for i, key := range keys {
			parts[i] = reprString(key) + ": " + pyRepr(items[key])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(value)
}

// pyStr is str(value).
func pyStr(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	return pyRepr(value)
}

func reprString(s string) string {
	runes := pyRunes(s)
	quote := '\''
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		quote = '"'
	}
	var b strings.Builder
	b.WriteRune(quote)
	for _, r := range runes {
		switch {
		case r == quote || r == '\\':
			b.WriteRune('\\')
			b.WriteRune(r)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r < ' ' || r == 0x7F:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < 0x7F:
			b.WriteRune(r)
		case r >= 0xD800 && r <= 0xDFFF:
			fmt.Fprintf(&b, `\u%04x`, r)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r <= 0xFF:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r <= 0xFFFF:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			fmt.Fprintf(&b, `\U%08x`, r)
		}
	}
	b.WriteRune(quote)
	return b.String()
}

// pyIntConvert is int(value) for the JSON values a worker record may hold.
func pyIntConvert(value any) (*big.Int, error) {
	if n, ok := pyInt(value); ok {
		return n, nil
	}
	switch v := value.(type) {
	case float64:
		if math.IsNaN(v) {
			return nil, valueError("cannot convert float NaN to integer")
		}
		if math.IsInf(v, 0) {
			return nil, &pyErr{class: classOverflow, msg: "cannot convert float infinity to integer"}
		}
		n, _ := new(big.Float).SetFloat64(math.Trunc(v)).Int(nil)
		return n, nil
	case string:
		text := pyStrip(v)
		digits := text
		if strings.HasPrefix(digits, "+") || strings.HasPrefix(digits, "-") {
			digits = digits[1:]
		}
		valid := digits != "" && !strings.HasPrefix(digits, "_") && !strings.HasSuffix(digits, "_") && !strings.Contains(digits, "__")
		var clean strings.Builder
		for _, r := range digits {
			switch {
			case r == '_':
			case r >= '0' && r <= '9':
				clean.WriteRune(r)
			case unicode.IsDigit(r):
				clean.WriteRune('0' + rune(unicodeDigit(r)))
			default:
				valid = false
			}
		}
		if valid {
			if n, ok := new(big.Int).SetString(clean.String(), 10); ok {
				if strings.HasPrefix(text, "-") {
					n.Neg(n)
				}
				return n, nil
			}
		}
		return nil, valueError("invalid literal for int() with base 10: " + reprString(v))
	}
	return nil, typeError(fmt.Sprintf("int() argument must be a string, a bytes-like object or a number, not '%s'", pyTypeName(value)))
}

// unicodeDigit is the value of a non-ASCII decimal digit, whose blocks
// start at a zero.
func unicodeDigit(r rune) int {
	start := r
	for unicode.IsDigit(start - 1) {
		start--
	}
	return int(r-start) % 10
}
