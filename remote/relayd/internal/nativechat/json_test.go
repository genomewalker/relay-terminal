package nativechat

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestDecodeRejectsAmbiguityAndBounds(t *testing.T) {
	for _, raw := range []string{`{"id":"a","id":"b"}`, `{"x":{"identity":1,"identity":2}}`, `{"x":1}{"y":2}`, `{"x":`, `null`, `[]`, string([]byte{'{', '"', 0xff, '"', '}'})} {
		if _, e := DecodeObject([]byte(raw), MaxFrameBytes); e == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
	if _, e := DecodeObject([]byte(`{"x":1}`), 3); e == nil {
		t.Fatal("size bound ignored")
	}
	if _, e := DecodeAction([]byte(`{"id":"x","surprise":true}`)); e == nil {
		t.Fatal("unknown action field accepted")
	}
}
func FuzzDecodeObject(f *testing.F) {
	for _, s := range []string{`{}`, `{"id":"x","identity":{"pane":"p","instance":"i","provider":"codex"},"kind":"send","text":"hello"}`, `{"x":{"a":1,"a":2}}`, `{"x":[1,null,true,"text"]}`, `{"truncated":`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > MaxActionBytes+1 {
			return
		}
		object, err := DecodeObject(data, MaxActionBytes)
		if err != nil {
			return
		}
		encoded, e := json.Marshal(object)
		if e != nil {
			t.Fatal(e)
		}
		again, e := DecodeObject(encoded, MaxActionBytes)
		if e != nil {
			t.Fatal("accepted object cannot round trip", e)
		}
		var left, right any
		_ = json.Unmarshal(data, &left)
		_ = json.Unmarshal(encoded, &right)
		if !reflect.DeepEqual(left, right) || len(object) != len(again) {
			t.Fatal("round trip changed JSON")
		}
		if _, e := DecodeObject(append(bytes.Clone(data), []byte("{}")...), MaxActionBytes); e == nil {
			t.Fatal("concatenated input accepted")
		}
	})
}

func TestJSONStructureBounds(t *testing.T) {
	deep := `{"x":` + strings.Repeat("[", 65) + "null" + strings.Repeat("]", 65) + "}"
	if _, e := DecodeObject([]byte(deep), MaxFrameBytes); e == nil {
		t.Fatal("JSON depth bound ignored")
	}
	broad := `{"x":[` + strings.Repeat("null,", 65536) + "null]}"
	if _, e := DecodeObject([]byte(broad), MaxFrameBytes); e == nil {
		t.Fatal("JSON node bound ignored")
	}
}
