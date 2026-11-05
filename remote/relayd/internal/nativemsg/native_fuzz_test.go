//go:build linux || darwin

package nativemsg

import (
	"encoding/json"
	"testing"
)

func FuzzNativeMessageJSON(f *testing.F) {
	for _, seed := range []string{"", "plain", "quotes \" \\ \n", "é 😀", "\x00\xff", "@@REF:pid:agent@@"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		if len(input) > 16384 {
			return
		}
		encoded, err := json.Marshal(map[string]any{"payload": input, "enabled": true, "id": 123})
		if err != nil {
			t.Fatal(err)
		}
		// encoding/json independently defines invalid-UTF8 replacement in this
		// generated valid-JSON domain. The native decoder must retain each value.
		var expected map[string]any
		if err = json.Unmarshal(encoded, &expected); err != nil {
			t.Fatal(err)
		}
		value, err := loadsBytes(encoded)
		if err != nil {
			t.Fatal(err)
		}
		payload, err := pyGet(value, "payload", nil)
		if err != nil || payload != expected["payload"] {
			t.Fatal("payload value changed")
		}
		enabled, err := pyGet(value, "enabled", nil)
		if err != nil || enabled != true {
			t.Fatal("boolean value changed")
		}
		id, err := pyGet(value, "id", nil)
		if err != nil || !pyEqual(id, int64(123)) {
			t.Fatal("integer value changed")
		}
		canonical := dumps(value, true)
		again, err := loadsText([]byte(canonical))
		if err != nil || dumps(again, true) != canonical {
			t.Fatal("canonical JSON round trip changed")
		}
		if len(canonical) > 12*len(input)+128 {
			t.Fatal("encoded output exceeded bounded escaping")
		}
		if _, err = loadsBytes(encoded[:len(encoded)-1]); err == nil {
			t.Fatal("truncated object accepted")
		}
		if _, err = loadsBytes(append(encoded, 'x')); err == nil {
			t.Fatal("trailing bytes accepted")
		}
	})
}
