package daemon

// Python-compatible JSON values for state and decisions that were produced by
// the former Python adapters. Existing ledgers, digests and persisted IDs were
// computed with Python's json module, so Go reproduces its value model:
// insertion-ordered objects, int versus float lexemes, unbounded integers,
// float repr, ensure_ascii escaping, equality and truthiness.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// pyObject is a Python dict: keys keep first-insertion order, replacing a
// value keeps its position, deletion forgets it. It is always shared by
// pointer, as Python dicts are.
type pyObject struct {
	keys   []string
	values map[string]any
}

// pyList is a Python list shared by pointer.
type pyList struct{ items []any }

func newPyObject() *pyObject { return &pyObject{values: map[string]any{}} }

func pyObj(pairs ...any) *pyObject {
	o := newPyObject()
	for i := 0; i+1 < len(pairs); i += 2 {
		o.Set(pairs[i].(string), pairs[i+1])
	}
	return o
}

func pyListOf(items ...any) *pyList { return &pyList{items: items} }

func (o *pyObject) Len() int { return len(o.keys) }

func (o *pyObject) Has(key string) bool { _, ok := o.values[key]; return ok }

func (o *pyObject) Get(key string) any { return o.values[key] }

func (o *pyObject) Lookup(key string) (any, bool) { v, ok := o.values[key]; return v, ok }

// GetOr is dict.get(key, fallback).
func (o *pyObject) GetOr(key string, fallback any) any {
	if v, ok := o.values[key]; ok {
		return v
	}
	return fallback
}

func (o *pyObject) Set(key string, value any) {
	if _, ok := o.values[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.values[key] = value
}

func (o *pyObject) Delete(key string) {
	if _, ok := o.values[key]; !ok {
		return
	}
	delete(o.values, key)
	for i, k := range o.keys {
		if k == key {
			o.keys = append(o.keys[:i:i], o.keys[i+1:]...)
			return
		}
	}
}

func (o *pyObject) Keys() []string { return append([]string(nil), o.keys...) }

// Copy is dict(o): a shallow copy keeping order.
func (o *pyObject) Copy() *pyObject {
	c := &pyObject{keys: append([]string(nil), o.keys...), values: make(map[string]any, len(o.values))}
	for k, v := range o.values {
		c.values[k] = v
	}
	return c
}

// pyDeepCopy copies containers so later mutation cannot alias stored values.
func pyDeepCopy(v any) any {
	switch t := v.(type) {
	case *pyObject:
		c := &pyObject{keys: append([]string(nil), t.keys...), values: make(map[string]any, len(t.values))}
		for k, item := range t.values {
			c.values[k] = pyDeepCopy(item)
		}
		return c
	case *pyList:
		items := make([]any, len(t.items))
		for i, item := range t.items {
			items[i] = pyDeepCopy(item)
		}
		return &pyList{items: items}
	}
	return v
}

// pyDecode retains json.loads value semantics for native scalar JSON: objects
// keep order, duplicate keys keep their first position with the last value,
// and integer lexemes stay integers of any size. Malformed Unicode is rejected
// explicitly instead of being normalized by encoding/json.
func pyDecode(data []byte) (any, error) {
	if err := nativeJSONUnicode(data); err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	value, err := pyDecodeValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("extra data")
	}
	return value, nil
}

func pyDecodeValue(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	switch t := token.(type) {
	case json.Delim:
		switch t {
		case '{':
			object := newPyObject()
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return nil, err
				}
				key, ok := keyToken.(string)
				if !ok {
					return nil, errors.New("invalid object key")
				}
				value, err := pyDecodeValue(decoder)
				if err != nil {
					return nil, err
				}
				object.Set(key, value)
			}
			if _, err := decoder.Token(); err != nil {
				return nil, err
			}
			return object, nil
		case '[':
			list := &pyList{items: []any{}}
			for decoder.More() {
				value, err := pyDecodeValue(decoder)
				if err != nil {
					return nil, err
				}
				list.items = append(list.items, value)
			}
			if _, err := decoder.Token(); err != nil {
				return nil, err
			}
			return list, nil
		}
		return nil, errors.New("unexpected delimiter")
	case json.Number:
		return pyNumber(string(t))
	case string, bool, nil:
		return t, nil
	}
	return nil, errors.New("unexpected token")
}

func pyNumber(lexeme string) (any, error) {
	if strings.ContainsAny(lexeme, ".eE") {
		f, err := strconv.ParseFloat(lexeme, 64)
		if err != nil && !math.IsInf(f, 0) {
			return nil, err
		}
		return f, nil // Python's float() also overflows to infinity.
	}
	if i, err := strconv.ParseInt(lexeme, 10, 64); err == nil {
		return i, nil
	}
	b, ok := new(big.Int).SetString(lexeme, 10)
	if !ok {
		return nil, errors.New("invalid integer")
	}
	return b, nil
}

// pyFromGo converts encoding/json-compatible Go values into the Python model.
func pyFromGo(value any) (any, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	return pyDecode(data)
}

// pyInt reports a Python int (never bool) as int64 when it fits.
func pyInt(v any) (int64, bool) {
	switch t := v.(type) {
	case int64:
		return t, true
	case int:
		return int64(t), true
	}
	return 0, false
}

func pyIsInt(v any) bool {
	switch v.(type) {
	case int64, int, *big.Int:
		return true
	}
	return false
}

// pyNumeric returns a number's value for Python numeric comparison. bool is
// an int subclass in Python, so True == 1 and False == 0.
func pyNumeric(v any) (*big.Rat, float64, bool, bool) {
	switch t := v.(type) {
	case bool:
		if t {
			return big.NewRat(1, 1), 0, false, true
		}
		return big.NewRat(0, 1), 0, false, true
	case int64:
		return new(big.Rat).SetInt64(t), 0, false, true
	case int:
		return new(big.Rat).SetInt64(int64(t)), 0, false, true
	case uint64:
		// Native unsigned values (st_ino) keep their full range.
		return new(big.Rat).SetInt(new(big.Int).SetUint64(t)), 0, false, true
	case uint32:
		return new(big.Rat).SetInt64(int64(t)), 0, false, true
	case uint:
		return new(big.Rat).SetInt(new(big.Int).SetUint64(uint64(t))), 0, false, true
	case *big.Int:
		return new(big.Rat).SetInt(t), 0, false, true
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			return nil, t, true, true
		}
		return new(big.Rat).SetFloat64(t), t, true, true
	}
	return nil, 0, false, false
}

// pyCompareNumbers is exact int/float comparison; ok is false for NaN.
func pyCompareNumbers(a, b any) (int, bool) {
	ra, fa, _, oka := pyNumeric(a)
	rb, fb, _, okb := pyNumeric(b)
	if !oka || !okb {
		panic(pyTypeError("unorderable values"))
	}
	if ra == nil || rb == nil {
		if math.IsNaN(fa) || math.IsNaN(fb) {
			return 0, false
		}
		x, y := fa, fb
		if ra != nil {
			x, _ = ra.Float64()
		}
		if rb != nil {
			y, _ = rb.Float64()
		}
		switch {
		case x < y:
			return -1, true
		case x > y:
			return 1, true
		}
		return 0, true
	}
	return ra.Cmp(rb), true
}

func pyLess(a, b any) bool { c, ok := pyCompareNumbers(a, b); return ok && c < 0 }

func pyLessEq(a, b any) bool { c, ok := pyCompareNumbers(a, b); return ok && c <= 0 }

// pyEqual is Python ==.
func pyEqual(a, b any) bool {
	if _, _, _, ok := pyNumeric(a); ok {
		if _, _, _, ok := pyNumeric(b); ok {
			c, ok := pyCompareNumbers(a, b)
			return ok && c == 0
		}
		return false
	}
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case *pyList:
		y, ok := b.(*pyList)
		if !ok || len(x.items) != len(y.items) {
			return false
		}
		for i := range x.items {
			if !pyEqual(x.items[i], y.items[i]) {
				return false
			}
		}
		return true
	case *pyObject:
		y, ok := b.(*pyObject)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for _, k := range x.keys {
			other, ok := y.values[k]
			if !ok || !pyEqual(x.values[k], other) {
				return false
			}
		}
		return true
	}
	return false
}

// pyTruthy is bool(value).
func pyTruthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case int64:
		return t != 0
	case int:
		return t != 0
	case *big.Int:
		return t.Sign() != 0
	case float64:
		return t != 0
	case string:
		return t != ""
	case *pyList:
		return len(t.items) > 0
	case *pyObject:
		return t.Len() > 0
	}
	return true
}

// pyTypeError marks the failures that Python raised as TypeError/KeyError/
// AttributeError on unexpected shapes. Callers recover them at a boundary.
type pyTypeError string

func (e pyTypeError) Error() string { return string(e) }

func pyMustObject(v any) *pyObject {
	o, ok := v.(*pyObject)
	if !ok {
		panic(pyTypeError("object required"))
	}
	return o
}

func pyMustList(v any) *pyList {
	l, ok := v.(*pyList)
	if !ok {
		panic(pyTypeError("list required"))
	}
	return l
}

func pyMustString(v any) string {
	s, ok := v.(string)
	if !ok {
		panic(pyTypeError("string required"))
	}
	return s
}

// pyIndex is value[key] on an object, raising KeyError when absent.
func pyIndex(v any, key string) any {
	value, ok := pyMustObject(v).values[key]
	if !ok {
		panic(pyTypeError("missing key " + key))
	}
	return value
}

// pyHashable reports whether v can be a dict key / set member.
func pyHashable(v any) bool {
	switch v.(type) {
	case *pyObject, *pyList:
		return false
	}
	return true
}

// pyEncodeOptions mirror json.dumps parameters.
type pyEncodeOptions struct {
	sortKeys    bool
	ensureASCII bool
	itemSep     string
	keySep      string
}

var (
	// json.dumps(value) defaults.
	pyDumpsDefault = pyEncodeOptions{ensureASCII: true, itemSep: ", ", keySep: ": "}
	// json.dumps(value, sort_keys=True, separators=(",", ":")).
	pyDumpsSortedASCII = pyEncodeOptions{sortKeys: true, ensureASCII: true, itemSep: ",", keySep: ":"}
	// json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).
	pyDumpsCompact = pyEncodeOptions{sortKeys: true, itemSep: ",", keySep: ":"}
)

func pyEncode(v any, options pyEncodeOptions) []byte {
	var buffer bytes.Buffer
	pyEncodeValue(&buffer, v, options)
	return buffer.Bytes()
}

// pyCompact is pane_health_controller.compact.
func pyCompact(v any) []byte { return pyEncode(v, pyDumpsCompact) }

func pyEncodeValue(buffer *bytes.Buffer, v any, options pyEncodeOptions) {
	switch t := v.(type) {
	case nil:
		buffer.WriteString("null")
	case bool:
		if t {
			buffer.WriteString("true")
		} else {
			buffer.WriteString("false")
		}
	case int64:
		buffer.WriteString(strconv.FormatInt(t, 10))
	case int:
		buffer.WriteString(strconv.Itoa(t))
	case uint64:
		buffer.WriteString(strconv.FormatUint(t, 10))
	case uint32:
		buffer.WriteString(strconv.FormatUint(uint64(t), 10))
	case uint:
		buffer.WriteString(strconv.FormatUint(uint64(t), 10))
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
		pyEncodeString(buffer, t, options.ensureASCII)
	case *pyList:
		buffer.WriteByte('[')
		for i, item := range t.items {
			if i > 0 {
				buffer.WriteString(options.itemSep)
			}
			pyEncodeValue(buffer, item, options)
		}
		buffer.WriteByte(']')
	case *pyObject:
		keys := t.keys
		if options.sortKeys {
			keys = append([]string(nil), keys...)
			sort.Strings(keys) // UTF-8 byte order is code point order.
		}
		buffer.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				buffer.WriteString(options.itemSep)
			}
			pyEncodeString(buffer, key, options.ensureASCII)
			buffer.WriteString(options.keySep)
			pyEncodeValue(buffer, t.values[key], options)
		}
		buffer.WriteByte('}')
	default:
		panic(pyTypeError("value is not JSON serializable"))
	}
}

func pyEncodeString(buffer *bytes.Buffer, s string, ensureASCII bool) {
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
			case r < 0x20:
				pyWriteUnicodeEscape(buffer, r)
			case ensureASCII && r > 0x7e:
				if r > 0xffff {
					high, low := utf16.EncodeRune(r)
					pyWriteUnicodeEscape(buffer, high)
					pyWriteUnicodeEscape(buffer, low)
				} else {
					pyWriteUnicodeEscape(buffer, r)
				}
			default:
				buffer.WriteRune(r)
			}
		}
	}
	buffer.WriteByte('"')
}

func pyWriteUnicodeEscape(buffer *bytes.Buffer, r rune) {
	const hex = "0123456789abcdef"
	buffer.WriteString(`\u`)
	buffer.WriteByte(hex[(r>>12)&0xf])
	buffer.WriteByte(hex[(r>>8)&0xf])
	buffer.WriteByte(hex[(r>>4)&0xf])
	buffer.WriteByte(hex[r&0xf])
}

// pyFloatRepr is float.__repr__ for finite values: shortest round-trip
// digits, positional notation for 1e-4 <= |x| < 1e16, otherwise exponent
// notation with at least two exponent digits; integral values keep ".0".
func pyFloatRepr(f float64) string {
	if math.IsNaN(f) {
		return "nan"
	}
	if math.IsInf(f, 1) {
		return "inf"
	}
	if math.IsInf(f, -1) {
		return "-inf"
	}
	sign := ""
	if math.Signbit(f) {
		sign = "-"
		f = -f
	}
	if f == 0 {
		return sign + "0.0"
	}
	formatted := strconv.FormatFloat(f, 'e', -1, 64) // d.ddde±XX
	mantissa, exponent, _ := strings.Cut(formatted, "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	exp, _ := strconv.Atoi(exponent)
	decpt := exp + 1 // value = 0.digits * 10^decpt
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
	e := decpt - 1
	esign := "+"
	if e < 0 {
		esign = "-"
		e = -e
	}
	estr := strconv.Itoa(e)
	if len(estr) < 2 {
		estr = "0" + estr
	}
	return sign + out + "e" + esign + estr
}

// pyRoundDigits is round(x, n) for a float: correctly rounded decimal.
func pyRoundDigits(x float64, digits int) float64 {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return x
	}
	rounded, err := strconv.ParseFloat(strconv.FormatFloat(x, 'f', digits, 64), 64)
	if err != nil {
		return x
	}
	if rounded == 0 && math.Signbit(x) {
		return math.Copysign(0, -1)
	}
	return rounded
}

// pyRound is round(x) for a finite float: banker's rounding to an int.
func pyRound(x float64) any {
	r := math.RoundToEven(x)
	if r >= -(1<<62) && r <= 1<<62 {
		return int64(r)
	}
	i, _ := big.NewFloat(r).Int(nil)
	return i
}

// pyRepr is repr() for the scalar values a status can carry.
func pyRepr(v any) string {
	switch t := v.(type) {
	case nil:
		return "None"
	case bool:
		if t {
			return "True"
		}
		return "False"
	case int64, int, *big.Int:
		return string(pyEncode(t, pyDumpsDefault))
	case float64:
		return pyFloatRepr(t)
	case string:
		return pyStringRepr(t)
	case *pyList:
		parts := make([]string, len(t.items))
		for i, item := range t.items {
			parts[i] = pyRepr(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *pyObject:
		parts := make([]string, 0, t.Len())
		for _, k := range t.keys {
			parts = append(parts, pyStringRepr(k)+": "+pyRepr(t.values[k]))
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return "?"
}

func pyStringRepr(s string) string {
	quote := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		switch {
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r < 0x20 || r == 0x7f:
			b.WriteString(`\x` + strconv.FormatInt(int64(r)|0x100, 16)[1:])
		case r < 0x7f:
			b.WriteRune(r)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r <= 0xff:
			b.WriteString(`\x` + strconv.FormatInt(int64(r)|0x100, 16)[1:])
		case r <= 0xffff:
			b.WriteString(`\u` + strconv.FormatInt(int64(r)|0x10000, 16)[1:])
		default:
			b.WriteString(`\U` + strconv.FormatInt(int64(r)|0x100000000, 16)[1:])
		}
	}
	b.WriteByte(quote)
	return b.String()
}

// pyLen is len() of a string in code points.
func pyLen(s string) int { return utf8.RuneCountInString(s) }
