package daemon

import (
	"fmt"
	"testing"
	"unicode/utf16"
	"unicode/utf8"
)

func TestNativeJSONRejectsNonScalarUnicode(t *testing.T) {
	for _, input := range [][]byte{
		[]byte(`"\ud800"`), []byte(`"\udfff"`),
		[]byte(`{"\ud800":1}`), []byte(`{"ignored":"\ud800"}`),
		[]byte(`"\ud800\u0041"`), []byte(`"\ud800\ud800\udc00"`),
		[]byte(`"\ud800\\udc00"`), []byte(`"\ud83d\ude00\udfff"`),
		{'"', 0xff, '"'}, {'"', 0xed, 0xa0, 0x80, '"'},
	} {
		if _, err := pyDecode(input); err == nil {
			t.Fatalf("native JSON normalized non-scalar input: %q", input)
		}
	}
	for input, want := range map[string]string{
		`"\ud83d\ude00"`: "😀", `"\uD83D\uDE00"`: "😀",
		`"\ud800\udc00"`: "\U00010000", `"\udbff\udfff"`: "\U0010ffff",
		`"\ufffd"`: "�", `"é😀"`: "é😀", `"\\ud800"`: `\ud800`,
		`"a\"\\ud800"`: "a\"\\ud800", `"\ud7ff\ue000"`: "\ud7ff\ue000",
	} {
		value, err := pyDecode([]byte(input))
		if err != nil || value != want {
			t.Fatalf("valid Unicode or literal escape changed: %s: %q %v", input, value, err)
		}
	}
	for _, input := range []string{`"\u`, `"\u12xx"`, `"\ud83d\ude0`, `"\q"`, `"valid" trailing`} {
		if _, err := pyDecode([]byte(input)); err == nil {
			t.Fatalf("malformed JSON accepted: %q", input)
		}
	}
}

func TestNativeJSONSingleUnitDomain(t *testing.T) {
	for unit := 0; unit <= 0xffff; unit++ {
		input := fmt.Sprintf(`"\u%04x"`, unit)
		value, err := pyDecode([]byte(input))
		valid := !utf16.IsSurrogate(rune(unit))
		if (err == nil) != valid || valid && value != string(rune(unit)) {
			t.Fatalf("single-unit Unicode domain: %s value=%q error=%v", input, value, err)
		}
	}
	t.Log("checked all 65536 UTF-16 single-unit inputs")
}

func FuzzNativeJSONUnicode(f *testing.F) {
	f.Add([]byte(`{"normal":"é😀"}`), uint16(0xd800), uint16(0x41))
	f.Add([]byte(`"\ud800"`), uint16(0xd83d), uint16(0xde00))
	f.Add([]byte{'"', 0xff, '"'}, uint16(0x41), uint16(0xdc00))
	f.Add([]byte(`"\\ud800"`), uint16(0x20), uint16(0x7e))
	f.Fuzz(func(t *testing.T, data []byte, first, second uint16) {
		if len(data) > 16<<10 {
			return
		}
		if _, err := pyDecode(data); err == nil && !utf8.Valid(data) {
			t.Fatal("native JSON accepted invalid UTF-8")
		}
		encoded := fmt.Sprintf(`"\u%04x\u%04x"`, first, second)
		paired := first >= 0xd800 && first <= 0xdbff && second >= 0xdc00 && second <= 0xdfff
		valid := paired || !utf16.IsSurrogate(rune(first)) && !utf16.IsSurrogate(rune(second))
		value, err := pyDecode([]byte(encoded))
		if (err == nil) != valid {
			t.Fatalf("native JSON UTF-16 scalar boundary: %s valid=%v error=%v", encoded, valid, err)
		}
		if valid {
			want := string([]rune{rune(first), rune(second)})
			if paired {
				want = string(utf16.DecodeRune(rune(first), rune(second)))
			}
			if value != want {
				t.Fatalf("native JSON changed valid Unicode: %s", encoded)
			}
		}
	})
}
