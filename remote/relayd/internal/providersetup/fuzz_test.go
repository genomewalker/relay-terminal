package providersetup

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"reflect"
	"strings"
	"testing"
)

func jsonDecodeReport(raw []byte, v *Report) error { return json.Unmarshal(raw, v) }
func FuzzProviderSettings(f *testing.F) {
	for _, seed := range []string{`{"statusLine":{"type":"command","command":"cc-status"}}`, `{"statusLine":{"type":"command","command":"quota --statusline YQ== --footer user"},"hooks":{"Stop":[]},"custom":"private"}`, `null`, `{`, `{"x":1} {"y":2}`, `{"enabledPlugins":{"chitta@genomewalker-chitta":0e0},"hooks":"å😀"}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		if data, e := object(raw); e == nil {
			enabled, enabledErr := configEnabled(data)
			count, countErr := configHookCount(data)
			_, statusErr := configStatus(data)
			if enabledErr == nil && countErr == nil && statusErr == nil {
				if count < 0 || count > len(raw) {
					t.Fatal("unbounded hook event count")
				}
				r := Report{Hooks: HookReport{UserEventCount: count}, canonicalDrift: enabled, canonicalDriftSet: true}
				wire, e := json.Marshal(r)
				if e != nil || len(wire) > 6*FileLimit+2048 {
					t.Fatal("unbounded/invalid metadata encoding")
				}
				d := json.NewDecoder(bytes.NewReader(wire))
				d.UseNumber()
				var round map[string]any
				if e = d.Decode(&round); e != nil || !reflect.DeepEqual(round["drift"], enabled) {
					t.Fatal("canonical drift JSON scalar/type did not roundtrip")
				}
			}
		}
		out, e := TransformSettings(raw)
		if e != nil {
			return
		}
		if len(raw) > FileLimit {
			t.Fatal("oversized settings accepted")
		}
		before, e := object(raw)
		if e != nil {
			t.Fatal("transform accepted invalid object")
		}
		after, e := object(out)
		if e != nil {
			t.Fatal("invalid transformed JSON")
		}
		if after["promptSuggestionEnabled"] != true {
			t.Fatal("suggestions missing")
		}
		for k, v := range before {
			if k != "statusLine" && k != "promptSuggestionEnabled" && !reflect.DeepEqual(v, after[k]) {
				t.Fatalf("unrelated setting lost: %s", k)
			}
		}
		oldStatus := before["statusLine"].(map[string]any)
		newStatus := after["statusLine"].(map[string]any)
		for k, v := range oldStatus {
			if k != "command" && !reflect.DeepEqual(v, newStatus[k]) {
				t.Fatal("unrelated status field lost")
			}
		}
		if _, e := object(append(append([]byte(nil), out...), []byte(` {"trailing":1}`)...)); e == nil {
			t.Fatal("trailing object accepted")
		}
		if _, e := object(bytes.TrimSpace(out)[:len(bytes.TrimSpace(out))-1]); e == nil {
			t.Fatal("truncated object accepted")
		}
	})
}
func FuzzProviderBundle(f *testing.F) {
	enc, _ := encodedAssets(DefaultAssets())
	for _, s := range []string{enc, "", "!!!!", base64.StdEncoding.EncodeToString([]byte(`{"../escape":"YQ=="}`))} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, encoded string) {
		m, e := DecodeAssets(encoded)
		if e != nil {
			return
		}
		if len(encoded) > 6*FileLimit {
			t.Fatal("oversized bundle accepted")
		}
		if len(m) != 3 {
			t.Fatal("asset count")
		}
		for _, n := range assetNames {
			if len(m[n]) == 0 || len(m[n]) > FileLimit {
				t.Fatal("invalid asset")
			}
		}
		round, e := encodedAssets(m)
		if e != nil {
			t.Fatal(e)
		}
		again, e := DecodeAssets(round)
		if e != nil || !reflect.DeepEqual(again, m) {
			t.Fatal("bundle roundtrip failed")
		}
		b, e := Bundle(m)
		if e != nil || !bytes.HasPrefix(b, []byte("#!/bin/sh\nset -eu\n")) {
			t.Fatal("bundle format")
		}
		if bytes.Contains(b, []byte("../escape")) {
			t.Fatal("unencoded path injected into shell")
		}
		if !bytes.Contains(b, []byte("--assets-base64 '"+round+"' \"$@\"")) {
			t.Fatal("portable entry lost payload or forwarded arguments")
		}
		decodedJSON, e := base64.StdEncoding.DecodeString(round)
		if e != nil {
			t.Fatal(e)
		}
		if _, e := DecodeAssets(base64.StdEncoding.EncodeToString(decodedJSON[:len(decodedJSON)-1])); e == nil {
			t.Fatal("truncated bundle object accepted")
		}
	})
}
func FuzzProviderRepair(f *testing.F) {
	for _, s := range []string{"", anchor, replacement, anchor + "\n" + anchor} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		out, changed, e := RepairBytes(raw)
		if e != nil {
			return
		}
		if len(raw) > FileLimit {
			t.Fatal("oversized adapter accepted")
		}
		if changed {
			if strings.Count(string(raw), anchor) != 1 || !strings.Contains(string(out), replacement) {
				t.Fatal("unguarded repair")
			}
		} else if !bytes.Equal(out, raw) {
			t.Fatal("unchanged repair changed bytes")
		}
		again, changed, e := RepairBytes(out)
		if e != nil || changed || !bytes.Equal(out, again) {
			t.Fatal("repair not idempotent")
		}
	})
}
func FuzzProviderRelativePath(f *testing.F) {
	for _, s := range []string{".config/relay/asset", "../escape", "/absolute", "a//b", "a/./b", "a\x00b"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, path string) {
		p, e := parts(path)
		if e != nil {
			return
		}
		if len(path) > 4096 || strings.HasPrefix(path, "/") || strings.ContainsRune(path, 0) {
			t.Fatal("unsafe path accepted")
		}
		for _, v := range p {
			if v == "" || v == "." || v == ".." || strings.Contains(v, "/") {
				t.Fatal("escaping component")
			}
		}
	})
}
func FuzzProviderStatusBound(f *testing.F) {
	for _, s := range []string{"", `{"hook":"payload"}`, strings.Repeat("x", StatusInputLimit+1)} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		calls := 0
		r := Runtime{Env: []string{}, Run: func(_ context.Context, program string, args []string, b []byte, _, _ io.Writer) (int, error) {
			calls++
			if !bytes.Equal(b, raw) {
				t.Fatal("status payload or renderer changed")
			}
			if calls == 1 && (args[0] != "subscription-quota-statusline" || args[1] != base64.StdEncoding.EncodeToString([]byte(":"))) {
				t.Fatal("quota capture changed")
			}
			if calls == 2 && (program != "bash" || len(args) != 1 || args[0] != ".config/relay/cc-status.sh") {
				t.Fatal("shared renderer changed")
			}
			return 7, nil
		}}
		code, e := r.Statusline(context.Background(), bytes.NewReader(raw), io.Discard, io.Discard)
		if len(raw) > StatusInputLimit {
			if e == nil || calls != 0 {
				t.Fatal("oversized status reached subprocess")
			}
			return
		}
		if e != nil || code != 7 || calls != 2 {
			t.Fatal("bounded status did not reach exact renderer once")
		}
	})
}
