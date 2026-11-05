package appupdate

import (
	"bytes"
	"testing"
	"unicode/utf8"
)

func FuzzUpdatePlistSyntax(f *testing.F) {
	for _, s := range []string{`<plist><dict/></plist>`, `<plist><dict><key>a</key><array><integer>1</integer><true/><data>YQ==</data></array></dict></plist>`, `<plist><dict><key>a</key>`, `<plist><dict><key>x</key><string>a</string><key>x</key><string>b</string></dict></plist>`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := parsePlist(b)
		if e != nil {
			return
		}
		if len(b) > maxState || !utf8.Valid(b) {
			t.Fatal("plist encoding or byte bounds ignored")
		}
		encoded := jsonData(m)
		projection, e := object(encoded)
		if e != nil || !bytes.Equal(encoded, jsonData(projection)) {
			t.Fatal("plist JSON projection round trip changed")
		}
		extra := append(append([]byte{}, b...), []byte(`<plist><dict/></plist>`)...)
		if _, e = parsePlist(extra); e == nil {
			t.Fatal("concatenated plist accepted")
		}
	})
}
