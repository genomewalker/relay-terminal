package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHTTPGDDescriptorAndConsoleLeakCheck(t *testing.T) {
	for _, data := range []string{`{}`, `{"token":""}`, `{"token":null}`, `{"token":7}`, `{"token":"x"} trailing`} {
		if _, err := descriptorToken([]byte(data)); err == nil {
			t.Fatal("accepted invalid descriptor")
		}
	}
	token, err := descriptorToken([]byte(`{"token":"private-fixture-token"}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, offset := range []int{0, (64 << 10) - 1, (64 << 10) - len(token)/2, 128 << 10} {
		input := strings.Repeat("x", offset) + token + "ok"
		if leaked, err := containsToken(strings.NewReader(input), token); err != nil || !leaked {
			t.Fatal("missed console leak at offset", offset, err)
		}
	}
	if leaked, err := containsToken(strings.NewReader("safe console output"), token); err != nil || leaked {
		t.Fatal("false console leak", err)
	}
}

func FuzzHTTPGDDescriptor(f *testing.F) {
	f.Add([]byte(`{"token":"fixture-token"}`), []byte("safe"))
	f.Add([]byte(`{"token":"x"}`), []byte("x"))
	f.Fuzz(func(t *testing.T, data, log []byte) {
		if len(data) > 1<<20 || len(log) > 1<<20 {
			return
		}
		token, err := descriptorToken(data)
		if err != nil {
			return
		}
		if token == "" || len(token) > 4096 {
			t.Fatal("unbounded/empty token accepted")
		}
		leaked, err := containsToken(bytes.NewReader(log), token)
		if err != nil || leaked != bytes.Contains(log, []byte(token)) {
			t.Fatal("streaming console leak check disagrees")
		}
		if _, err := descriptorToken(append(append([]byte{}, data...), 'x')); err == nil {
			t.Fatal("accepted trailing descriptor data")
		}
	})
}

func TestProvenanceRequiresExactSHA(t *testing.T) {
	sha := strings.Repeat("ab", 32)
	for _, data := range []string{`{}`, `{"library_sha256":7}`, `{"library_sha256":"bad"}`, `{"library_sha256":"` + strings.ToUpper(sha) + `"}`, `{"library_sha256":"` + sha + `"} trailing`} {
		if _, err := provenance([]byte(data)); err == nil {
			t.Fatalf("accepted %q", data)
		}
	}
	if got, err := provenance([]byte(`{"library_sha256":"` + sha + `"}`)); err != nil || got != sha {
		t.Fatalf("%s %v", got, err)
	}
}

func TestManifestExactFormatAndPayloadHashes(t *testing.T) {
	app := t.TempDir()
	root := filepath.Join(app, "Contents", "Resources")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "relayd-linux-amd64"), []byte("abc"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "dir-linux-a"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := manifest(app, []string{"1.2", "q\"\\é😀", "7"}, "", false); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(root, "relay-release.json"))
	if err != nil {
		t.Fatal(err)
	}
	want := "{\n  \"app_version\": \"1.2\",\n  \"daemon_version\": \"q\\\"\\\\\\u00e9\\ud83d\\ude00\",\n  \"build_number\": \"7\",\n  \"source_digest\": null,\n  \"sha256\": {\n    \"Resources/relayd-linux-amd64\": \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"\n  }\n}\n"
	if string(got) != want {
		t.Fatalf("manifest format/hash differs:\n%s", got)
	}
	if err := manifest(app, []string{"1", "1", "1"}, "", true); err != nil {
		t.Fatal(err)
	}
	got, _ = os.ReadFile(filepath.Join(root, "relay-release.json"))
	if !strings.Contains(string(got), `"source_digest": "",`) {
		t.Fatal("empty digest lost")
	}
}

func TestRunningResolvesSymlinksWithoutPrefixMatches(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Relay")
	link := filepath.Join(dir, "link")
	if err := os.WriteFile(path, nil, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+"-other", nil, 0700); err != nil {
		t.Fatal(err)
	}
	if ok, err := running(path, strings.NewReader("  "+link+"\n")); !ok || err != nil {
		t.Fatal(ok, err)
	}
	if ok, err := running(path, strings.NewReader(path+"-other\n")); ok || err != nil {
		t.Fatal(ok, err)
	}
}

func TestNativeResourceReferencesAndStaleAssets(t *testing.T) {
	root := t.TempDir()
	for path := range rotationReferences {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", path))
		if err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := rotationResources(root); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"stale.py", "deep/stale.pyc", "nested/__pycache__/file"} {
		path := filepath.Join(root, "Sources", "Relay", "Resources", name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("stale"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := rotationResources(root); err == nil {
			t.Fatalf("accepted %s", name)
		}
		if err := os.RemoveAll(filepath.Join(root, "Sources", "Relay", "Resources", strings.Split(name, "/")[0])); err != nil {
			t.Fatal(err)
		}
	}
	for path := range rotationReferences {
		target := filepath.Join(root, path)
		data, err := os.ReadFile(target)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, append(data, 'x'), 0600); err != nil {
			t.Fatal(err)
		}
		if err := rotationResources(root); err == nil {
			t.Fatalf("accepted drift %s", path)
		}
		if err := os.WriteFile(target, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestProvenanceRequiresExactDigestKey(t *testing.T) {
	for _, key := range []string{"LIBRARY_SHA256", "liBrArY_shA256"} {
		raw := []byte(`{"` + key + `":"` + strings.Repeat("0", 64) + `"}`)
		if _, err := provenance(raw); err == nil {
			t.Fatal("case-folded provenance key accepted")
		}
	}
}

func FuzzBuildProvenance(f *testing.F) {
	f.Add([]byte(`{"library_sha256":"` + strings.Repeat("ab", 32) + `"}`))
	f.Add([]byte(`{"library_sha256":null}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		v, err := provenance(b)
		if err != nil {
			return
		}
		if len(v) != 64 || strings.ToLower(v) != v {
			t.Fatalf("invalid SHA accepted: %q", v)
		}
		var original map[string]json.RawMessage
		if json.Unmarshal(b, &original) != nil {
			t.Fatal("accepted invalid JSON")
		}
		var s string
		if json.Unmarshal(original["library_sha256"], &s) != nil || s != v {
			t.Fatal("unbound digest")
		}
		if _, err := provenance(append(append([]byte{}, b...), 'x')); err == nil {
			t.Fatal("accepted trailing junk")
		}
	})
}

func FuzzManifestQuote(f *testing.F) {
	f.Add("q\"\\é😀\n")
	f.Add("<>&\x00")
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 1<<16 {
			return
		}
		q, err := quote(s)
		if err != nil {
			return
		}
		var got string
		if err := json.Unmarshal([]byte(q), &got); err != nil || got != s {
			t.Fatalf("roundtrip %q %v", s, err)
		}
		for _, c := range q {
			if c >= 127 {
				t.Fatal("manifest contains non-ASCII")
			}
		}
	})
}
