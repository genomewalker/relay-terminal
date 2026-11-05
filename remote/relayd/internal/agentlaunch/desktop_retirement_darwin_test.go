//go:build darwin

package agentlaunch

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestDesktopRetiredProcargsEnvironmentSkipsArguments(t *testing.T) {
	raw := append([]byte{2, 0, 0, 0}, []byte("/usr/bin/claude\x00\x00\x00\x00claude\x00CLAUDE_CONFIG_DIR=/evil\x00HOME=/h\x00CLAUDE_CONFIG_DIR=/h/.claude-max\x00\x00loader=private\x00")...)
	got, e := procargsEnvironment(raw)
	want := []byte("HOME=/h\x00CLAUDE_CONFIG_DIR=/h/.claude-max\x00")
	if e != nil || !bytes.Equal(got, want) {
		t.Fatalf("argv or loader string became environment: %q %v", got, e)
	}
	if _, e := procargsEnvironment(append([]byte{3, 0, 0, 0}, []byte("/usr/bin/claude\x00claude\x00")...)); e == nil {
		t.Fatal("truncated argv accepted")
	}
}

func FuzzDesktopProcargsEnvironmentBoundary(f *testing.F) {
	f.Add([]byte("value"), uint16(3))
	f.Add([]byte{0, 255, '='}, uint16(0))
	f.Fuzz(func(t *testing.T, payload []byte, count uint16) {
		if len(payload) > 16384 {
			return
		}
		payload = bytes.ReplaceAll(payload, []byte{0}, []byte{'_'})
		argc := int(count%32) + 1
		raw := make([]byte, 4)
		binary.LittleEndian.PutUint32(raw, uint32(argc))
		raw = append(raw, []byte("/private/app\x00\x00")...)
		for i := 0; i < argc; i++ {
			raw = append(raw, []byte("ENV=argument-must-not-leak\x00")...)
		}
		boundary := len(raw)
		expected := append(append([]byte("VALUE="), payload...), 0)
		raw = append(raw, expected...)
		raw = append(raw, []byte("\x00ENV=loader-must-not-leak\x00")...)
		got, e := procargsEnvironment(raw)
		if e != nil || !bytes.Equal(got, expected) || len(got) > len(raw) {
			t.Fatalf("argument/environment boundary escaped: %q %v", got, e)
		}
		if _, e := procargsEnvironment(raw[:boundary-1]); e == nil {
			t.Fatal("truncated argument accepted")
		}
	})
}
