package rotationtext

import (
	"encoding/base64"
	"fmt"
	"math"
	"math/rand"
	"strconv"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

func rawCase(name, text string) oracleCase {
	if !utf8.ValidString(text) {
		panic("raw case text must be valid UTF-8: " + name)
	}
	return oracleCase{name: name, Fn: "parse_json", Raw: &text}
}

func bytesCase(name string, raw []byte) oracleCase {
	encoded := base64.StdEncoding.EncodeToString(raw)
	return oracleCase{name: name, Fn: "parse_json", RawB64: &encoded}
}

func TestDifferentialJSON(t *testing.T) {
	texts := []string{
		`{}`, `[]`, `""`, `0`, `-0`, `1`, `-1`, `01`, `1.`, `.5`, `1.5`, `1e5`, `1E+5`, `1e-5`, `-1.0e-0`, `1e`, `1e+`,
		`1.5e999`, `-1e999`, `1e-999`, `123456789012345678901234567890`, `-123456789012345678901234567890`,
		`9223372036854775807`, `9223372036854775808`, `-9223372036854775808`, `-9223372036854775809`,
		strings.Repeat("9", 4300), strings.Repeat("9", 4301), "-" + strings.Repeat("9", 4300), "-" + strings.Repeat("9", 4301),
		strings.Repeat("1", 4300) + ".5", `NaN`, `Infinity`, `-Infinity`, `[NaN]`, `nul`, `null`, `true`, `false`, `True`,
		`{"a":1,"a":2}`, `{"a":{"b":1,"b":1}}`, `[{"a":1},{"a":1}]`, `{"a" : 1 , "b":[1, 2 ,3 ] }`, " \t\n\r[1]\r\n",
		`[1,]`, `{"a":1,}`, `[1 2]`, `{"a" 1}`, `{1:2}`, `[`, `{`, `"abc`, `"\x"`, `"\u12"`, `"\u12g4"`, `"\uD800"`,
		`"𐀀"`, `"\udc00\ud800"`, `"\ud800x"`, `"\ud800A"`, `"\ud800\uZZZZ"`, `"\ud800\u"`, `"\/\b\f\n\r\t\"\\"`,
		"\"tab\there\"", "\"nl\nhere\"", "\"del\x7fok\"", "\"  \"", `"\u0000"`, "\ufeff[1]", "[1]\ufeff",
		`{"":""}`, `[[[[[]]]]]`, `{"a":[{"b":null}]}`, `"é"`, `1 2`, ``, ` `, `[1]x`,
		strings.Repeat("[", 1000) + strings.Repeat("]", 1000),
	}
	cases := []oracleCase{}
	for i, text := range texts {
		cases = append(cases, rawCase(fmt.Sprint("text-", i), text))
		cases = append(cases, bytesCase(fmt.Sprint("bytes-", i), []byte(text)))
	}
	encodings := [][]byte{
		{0xef, 0xbb, 0xbf, '[', '1', ']'},
		{0xfe, 0xff, 0, '[', 0, '1', 0, ']'},
		{0xff, 0xfe, '[', 0, '1', 0, ']', 0},
		{0, '[', 0, '1', 0, ']'},
		{'[', 0, '1', 0, ']', 0},
		{0, 0, 0, '1'},
		{'1', 0, 0, 0},
		{0, 0, 0xfe, 0xff, 0, 0, 0, '1'},
		{0xff, 0xfe, 0, 0, '1', 0, 0, 0},
		{0, '1'},
		{'1', 0},
		{0xfe, 0xff, 0xd8, 0x00, 0, '"'},
		{0xfe, 0xff, 0, '"', 0xd8, 0x00, 0, '"'},
		{0xfe, 0xff, 0, '"', 0xd8, 0x3d, 0xde, 0x00, 0, '"'},
		{0, 0, 0xfe, 0xff, 0, 0x11, 0, 0},
		{'"', 0xed, 0xa0, 0x80, '"'},
		{'"', 0xed, 0xb0, 0x80, '"'},
		{'"', 0xc0, 0x80, '"'},
		{'"', 0xf4, 0x90, 0x80, 0x80, '"'},
		{'"', 0xef, 0xbf, 0xbd, '"'},
		{0xfe, 0xff, 0, '1', 0},
	}
	for i, raw := range encodings {
		cases = append(cases, bytesCase(fmt.Sprint("encoding-", i), raw))
	}
	random := rand.New(rand.NewSource(7))
	for i := 0; i < 1500; i++ {
		text := randomJSONText(random, 0)
		if random.Intn(4) == 0 {
			text = mutateText(random, text)
		}
		cases = append(cases, rawCase(fmt.Sprint("random-", i), text))
	}
	compareOracle(t, cases)
}

var jsonPieces = []string{"a", "é", "\\u00e9", "\\ud83d\\ude00", "\\ud800", "\\udfff", "\\n", "\\\"", "\\\\", "\\/", " ", "\U0001F600", " ", "_", "\\t", "x"}

func randomJSONText(random *rand.Rand, depth int) string {
	space := func() string { return []string{"", "", " ", "\n", "\t", "\r\n "}[random.Intn(6)] }
	switch kind := random.Intn(10); {
	case depth > 3 || kind < 2:
		return []string{"0", "-0", "17", "-3", "1.25", "1e3", "2E-2", "123456789012345678901234567890", "1.7976931348623157e308",
			"5e-324", "0.1", "100.0", "1e16", "1e15", "true", "false", "null"}[random.Intn(17)]
	case kind < 5:
		var text strings.Builder
		text.WriteByte('"')
		for n := random.Intn(5); n > 0; n-- {
			text.WriteString(jsonPieces[random.Intn(len(jsonPieces))])
		}
		text.WriteByte('"')
		return text.String()
	case kind < 7:
		items := []string{}
		for n := random.Intn(4); n > 0; n-- {
			items = append(items, space()+randomJSONText(random, depth+1)+space())
		}
		return "[" + strings.Join(items, ",") + "]"
	default:
		items := []string{}
		for n := random.Intn(4); n > 0; n-- {
			key := randomJSONText(random, 9)
			if random.Intn(3) > 0 {
				key = `"` + jsonPieces[random.Intn(len(jsonPieces))] + `"`
			}
			if random.Intn(8) == 0 {
				key = `"k"`
			}
			items = append(items, space()+key+space()+":"+space()+randomJSONText(random, depth+1))
		}
		return "{" + strings.Join(items, ",") + "}"
	}
}

func mutateText(random *rand.Rand, text string) string {
	if text == "" {
		return "x"
	}
	const inserts = "{}[],:\"\\0e.-"
	i := random.Intn(len(text))
	var out string
	switch random.Intn(4) {
	case 0:
		out = text[:i]
	case 1:
		out = text[:i] + text[i+1:]
	case 2:
		out = text[:i] + string(inserts[random.Intn(len(inserts))]) + text[i:]
	default:
		out = text + " ]"
	}
	if !utf8.ValidString(out) {
		return text + "]"
	}
	return out
}

func TestDifferentialCompactAndFloats(t *testing.T) {
	cases := []oracleCase{}
	values := []string{
		`{"b":1,"a":[1,2,{"d":null,"c":true}]}`, `{"é":1,"e":2,"z":3,"😀":4,"￿":5,"\ud800":6}`,
		`["\u0000\u001f\u007f\"\\/\b\f\n\r\t  é😀"]`, `"\ud800"`, `[1e400]`, `[-1e400]`,
		`[123456789012345678901234567890]`, `[-0.0, 0.0, 1.0, 100.0, 1e16, 1e15, 0.0001, 0.00001, 1.5e300, 5e-324]`,
	}
	for i, value := range values {
		cases = append(cases, fnCase(fmt.Sprint("compact-", i), "compact", rawJSON(value)))
	}
	random := rand.New(rand.NewSource(11))
	floats := []float64{math.MaxFloat64, math.SmallestNonzeroFloat64, 1e-7, 123456789012345680, 0.1 + 0.2, 1 / 3.0, 2.5e-5, 9.999999999999999e15, 1e17}
	for i := 0; i < 1500; i++ {
		var f float64
		switch random.Intn(3) {
		case 0:
			f = math.Float64frombits(random.Uint64())
		case 1:
			f = random.NormFloat64() * math.Pow(10, float64(random.Intn(40)-20))
		default:
			f = math.Round(random.Float64()*1e6) / math.Pow(10, float64(random.Intn(8)))
		}
		floats = append(floats, f)
	}
	for i, f := range floats {
		if math.IsNaN(f) || math.IsInf(f, 0) {
			continue
		}
		text := strconv.FormatFloat(f, 'g', -1, 64)
		if !strings.ContainsAny(text, ".e") {
			text += ".0"
		}
		cases = append(cases, fnCase(fmt.Sprint("float-", i), "compact", rawJSON("["+text+"]")))
	}
	compareOracle(t, cases)
}

func assignedInGo(r rune) bool {
	for name, table := range unicode.Categories {
		if name != "C" && name != "Cn" && unicode.Is(table, r) {
			return true
		}
	}
	return false
}

func TestDifferentialUnicodeTables(t *testing.T) {
	result := runOracle(t, []oracleCase{{Fn: "unicode_tables"}})[0].(obj)["ok"].(obj)
	check := func(name string, predicate func(rune) bool) {
		inside := map[rune]bool{}
		for _, raw := range result[name].([]any) {
			bounds := raw.([]any)
			for r := rune(bigOf(bounds[0]).Int64()); r <= rune(bigOf(bounds[1]).Int64()); r++ {
				inside[r] = true
			}
		}
		// Code points Go's tables do not yet assign (Unicode version skew
		// between CPython and Go) are reported; any other difference fails.
		skew, wrong := []string{}, []string{}
		for r := rune(0); r <= utf8.MaxRune; r++ {
			if r >= 0xd800 && r <= 0xdfff || predicate(r) == inside[r] {
				continue
			}
			if inside[r] && !predicate(r) && !assignedInGo(r) {
				skew = append(skew, fmt.Sprintf("U+%04X", r))
			} else {
				wrong = append(wrong, fmt.Sprintf("U+%04X", r))
			}
		}
		if len(skew) > 0 {
			t.Logf("%s class: %d code points newer than Go's Unicode %s tables", name, len(skew), unicode.Version)
		}
		if len(wrong) > 0 {
			t.Errorf("%s class differs: %s", name, clip(strings.Join(wrong, " "), 2000))
		}
	}
	check("word", pyIsWord)
	spaces := 0
	for r := rune(0); r <= utf8.MaxRune; r++ {
		if pyIsSpace(r) {
			spaces++
		}
	}
	check("space", pyIsSpace)
	if spaces != 29 {
		t.Errorf("space class has %d members", spaces)
	}
}

var redactionPieces = []string{
	"sk-", "sk-ant-", "ABCDEFGHIJKLMNOPQRSTUVWX", "abcdefgh12345678", "0123456789", "ghp_", "gho_", "github_pat_", "AKIA", "ASIA",
	"ABCDEFGHIJKLMNOP", "eyJ", "eyJhbGciOiJIUzI1", ".", "Bearer ", "bearer\t", "BEARER  ", "password=", "Password: ", "api_key=",
	"API-KEY:", "apikey\"=\"", "access_token=", "refresh-token: '", "client_secret=", "authorization=", "token=", "secret: ",
	"passwd=", "apİ_key=", "apı_key=", "ſecret=", "Key", "tokens=", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----",
	"-----END RSA PRIVATE KEY-----", "-----END PRIVATE KEY-----", "\n", " ", "\t", " ", " ", "\x1c", "　", ",", "\"", "'",
	"}", "=", ":", "_", "-", "é", "x", "1", "İ", "ı", "٠", "Ⅻ", "ä", "=====", "/+~", "fake-secret-value-1234",
	"FAKEENVTOKEN0123", "😀",
}

func randomRedactionText(random *rand.Rand) string {
	var text strings.Builder
	for n := 1 + random.Intn(14); n > 0; n-- {
		text.WriteString(redactionPieces[random.Intn(len(redactionPieces))])
	}
	return text.String()
}

func TestDifferentialRedaction(t *testing.T) {
	env := map[string]string{"ANTHROPIC_API_KEY": "  fake-secret-value-1234 ", "OPENAI_API_KEY": "short", "CODEX_API_KEY": "FAKEENVTOKEN0123"}
	unset := []string{"ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"}
	cases := []oracleCase{}
	fixed := []string{
		"key sk-ant-abcdefghijklmnopqrstuv end", "xsk-sk-abcdefghijklmnopqrst", "ésk-abcdefghijklmnopqrstuv", "_sk-abcdefghijklmnopqrstuv",
		"AKIAABCDEFGHIJKLMNOP", "AKIAABCDEFGHIJKLMNOPQ", "AKIAABCDEFGHIJKLMNOPé", "AKIAABCDEFGHIJKLMNOP-", "xAKIAABCDEFGHIJKLMNOP",
		"Authorization: Bearer abc.def-ghi~jkl+mno/pqr==", "bearer İıſKabcdefgh", "password = \"hunter22secret\"", "apİ_key=12345678",
		"-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY----- tail -----END PRIVATE KEY-----",
		"x-----BEGIN PRIVATE KEY-----y-----END PRIVATE KEY-----", "token=abcdef", "token=abcde", "mytoken=abcdefgh", "secret:　abcdefg",
		"eyJabcdefgh.abcdefgh.abcdefgh", "fake-secret-value-1234 and fake-secret-value-1234", "FAKEENVTOKEN0123",
	}
	for i, text := range fixed {
		c := fnCase(fmt.Sprint("redact-fixed-", i), "redact_evidence", text)
		c.Env, c.Unset = env, unset
		cases = append(cases, c)
		c = fnCase(fmt.Sprint("redact-payload-fixed-", i), "redact_assistant_payload", text, "fake-secret-value-1234")
		c.Env, c.Unset = env, unset
		cases = append(cases, c)
	}
	// Length boundaries: environment secrets and payload keys of 7 and 8 code points.
	boundaryEnv := map[string]string{"ANTHROPIC_API_KEY": "  exact8ch ", "OPENAI_API_KEY": "seven77", "CODEX_API_KEY": "éxact8ch"}
	for i, text := range []string{"a exact8ch b seven77 c éxact8ch d", "seven77seven77", "exact8chexact8ch"} {
		c := fnCase(fmt.Sprint("redact-boundary-", i), "redact_evidence", text)
		c.Env, c.Unset = boundaryEnv, unset
		cases = append(cases, c)
		for _, key := range []string{"seven77", "exact8ch"} {
			c = fnCase(fmt.Sprint("redact-payload-boundary-", i, "-", key), "redact_assistant_payload", text, key)
			c.Env, c.Unset = boundaryEnv, unset
			cases = append(cases, c)
		}
	}
	random := rand.New(rand.NewSource(3))
	for i := 0; i < 2500; i++ {
		c := fnCase(fmt.Sprint("redact-random-", i), "redact_evidence", randomRedactionText(random))
		c.Env, c.Unset = env, unset
		cases = append(cases, c)
	}
	for i := 0; i < 600; i++ {
		value := []any{randomRedactionText(random), obj{"token": randomRedactionText(random), "n": int64(i), "nested": []any{randomRedactionText(random), nil, true}}}
		key := []string{"", "short", "abcdefgh12345678", "fake-secret-value-1234"}[random.Intn(4)]
		c := fnCase(fmt.Sprint("redact-payload-random-", i), "redact_assistant_payload", value, key)
		c.Env, c.Unset = env, unset
		cases = append(cases, c)
	}
	compareOracle(t, cases)
}
