package providersetup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func fixture(t *testing.T) (string, *Store) {
	t.Helper()
	home := t.TempDir()
	s, e := Open(home)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return home, s
}
func write(t *testing.T, home, path string, raw []byte) {
	t.Helper()
	p := filepath.Join(home, path)
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(p, raw, 0600); e != nil {
		t.Fatal(e)
	}
}
func read(t *testing.T, home, path string) []byte {
	t.Helper()
	raw, e := os.ReadFile(filepath.Join(home, path))
	if e != nil {
		t.Fatal(e)
	}
	return raw
}
func jsonBytes(t *testing.T, v any) []byte {
	t.Helper()
	raw, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return raw
}
func semantic(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	v, e := object(raw)
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func baseSettings() map[string]any {
	return map[string]any{"statusLine": map[string]any{"type": "command", "command": "user-cc-status --footer custom", "padding": json.Number("7")}, "custom": "å user footer", "hooks": map[string]any{"Stop": []any{map[string]any{"command": "user-hook"}}}}
}
func privateBackups(t *testing.T, home string) map[string][]byte {
	t.Helper()
	result := map[string][]byte{}
	e := filepath.WalkDir(home, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if strings.Contains(p, "/backups/") && !d.IsDir() {
			info, e := d.Info()
			if e != nil {
				return e
			}
			if info.Mode().Perm() != 0600 {
				t.Errorf("backup %s mode %o", p, info.Mode().Perm())
			}
			result[p] = read(t, "", p)
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	return result
}

func TestCanonicalInstallerAndRepairCapture(t *testing.T) {
	raw, e := os.ReadFile("testdata/canonical.json")
	if e != nil {
		t.Fatal(e)
	}
	var cases []map[string]json.RawMessage
	if e = json.Unmarshal(raw, &cases); e != nil {
		t.Fatal(e)
	}
	count := 0
	for i, c := range cases {
		var kind string
		json.Unmarshal(c["kind"], &kind)
		switch kind {
		case "installer":
			t.Run(fmt.Sprintf("installer-%d", i), func(t *testing.T) {
				home, s := fixture(t)
				input := c["input"]
				write(t, home, settingsPath, input)
				var exit int
				json.Unmarshal(c["exit"], &exit)
				e := s.Install(DefaultAssets())
				if (e != nil) != (exit != 0) {
					t.Fatalf("error mismatch canonical=%d native=%v", exit, e)
				}
				want := semantic(t, c["settings"])
				got := semantic(t, read(t, home, settingsPath))
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("canonical settings differ: got %v want %v", got, want)
				}
				if exit == 0 {
					if len(privateBackups(t, home)) != 1 {
						t.Fatal("changed settings need one private backup")
					}
				}
			})
			count++
		case "repair":
			t.Run(fmt.Sprintf("repair-%d", i), func(t *testing.T) {
				var input, output string
				var exit int
				json.Unmarshal(c["input"], &input)
				json.Unmarshal(c["output"], &output)
				json.Unmarshal(c["exit"], &exit)
				got, changed, e := RepairBytes([]byte(input))
				if (e != nil) != (exit != 0) {
					t.Fatalf("canonical repair error=%d native=%v", exit, e)
				}
				if e == nil && (!changed || string(got) != output) {
					t.Fatal("repair must exactly match canonical output")
				}
			})
			count++
		}
	}
	if count != 17 {
		t.Fatalf("lost primary cases: %d", count)
	}
}
func TestApplyAuditBundleAndIdempotence(t *testing.T) {
	home, s := fixture(t)
	initial := jsonBytes(t, baseSettings())
	write(t, home, settingsPath, initial)
	report, e := s.Apply(DefaultAssets())
	if e != nil {
		t.Fatal(e)
	}
	if report.Drift || len(report.Files) != 3 || !report.Statusline.Managed || report.Hooks.UserEventCount != 1 {
		t.Fatalf("bad audit %+v", report)
	}
	for _, f := range report.Files {
		if !f.Managed || f.SHA256 == nil {
			t.Fatal("all three assets must be installed")
		}
	}
	if !bytes.Equal(read(t, home, ".config/relay/claude-status"), DefaultAssets()["relay-claude-status"]) {
		t.Fatal("missing managed native status adapter")
	}
	settings := semantic(t, read(t, home, settingsPath))
	if !reflect.DeepEqual(settings["hooks"], baseSettings()["hooks"]) || settings["custom"] != "å user footer" {
		t.Fatal("user settings lost")
	}
	first := privateBackups(t, home)
	if len(first) != 1 {
		t.Fatalf("backups=%d", len(first))
	}
	for _, v := range first {
		if !bytes.Equal(v, initial) {
			t.Fatal("backup differs from original")
		}
	}
	b := read(t, home, ".config/relay/provider-setup")
	if hash(b) != report.BundleSHA256 {
		t.Fatal("bundle identity mismatch")
	}
	var manifest struct {
		SchemaVersion int               `json:"schema_version"`
		BundleSHA256  string            `json:"bundle_sha256"`
		Assets        map[string]string `json:"assets"`
	}
	if e = json.Unmarshal(read(t, home, ".config/relay/provider-setup-manifest.json"), &manifest); e != nil {
		t.Fatal(e)
	}
	if manifest.SchemaVersion != 1 || manifest.BundleSHA256 != hash(b) || len(manifest.Assets) != 3 {
		t.Fatal("manifest incomplete")
	}
	for n, raw := range DefaultAssets() {
		if manifest.Assets[n] != hash(raw) {
			t.Fatal("manifest asset mismatch")
		}
	}
	before, e := s.read(settingsPath)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.Apply(DefaultAssets())
	if e != nil || again.Drift {
		t.Fatalf("idempotent apply %v", e)
	}
	after, e := s.read(settingsPath)
	if e != nil {
		t.Fatal(e)
	}
	if !same(before, after) || !reflect.DeepEqual(first, privateBackups(t, home)) {
		t.Fatal("idempotent apply rewrote files or backups")
	}
	// The portable bundle contains only a fixed shell entry and base64 payload;
	// native executable bytes/platform names must not enter its identity.
	enc, e := encodedAssets(DefaultAssets())
	if e != nil {
		t.Fatal(e)
	}
	decoded, e := DecodeAssets(enc)
	if e != nil || !reflect.DeepEqual(decoded, DefaultAssets()) {
		t.Fatal("portable assets roundtrip")
	}
	bundle2, e := Bundle(decoded)
	if e != nil || !bytes.Equal(bundle2, b) {
		t.Fatal("portable bundle is unstable")
	}
	if bytes.Contains(b, []byte("python")) || bytes.Contains(b, []byte("GOOS")) {
		t.Fatal("bundle depends on interpreter or target platform")
	}
	// Explicitly document/correct the primary installer's missing third asset.
	raw, e := os.ReadFile("testdata/canonical.json")
	if e != nil {
		t.Fatal(e)
	}
	var rows []map[string]any
	json.Unmarshal(raw, &rows)
	found := false
	for _, row := range rows {
		if row["kind"] == "apply" {
			found = true
			if row["exit"] != float64(1) || !strings.Contains(row["stdout"].(string), `"file": "claude-status.py", "managed": false`) {
				t.Fatal("canonical apply drift control lost")
			}
		}
	}
	if !found {
		t.Fatal("missing original drift witness")
	}
}
func TestWrapperAndSettingsRefusal(t *testing.T) {
	command := "quota --x user --statusline YWJj --footer 'å user'"
	data := baseSettings()
	data["statusLine"].(map[string]any)["command"] = command
	raw, e := TransformSettings(jsonBytes(t, data))
	if e != nil {
		t.Fatal(e)
	}
	expected := "quota --x user --statusline " + base64.StdEncoding.EncodeToString([]byte(Launcher)) + " --footer 'å user'"
	if semantic(t, raw)["statusLine"].(map[string]any)["command"] != expected {
		t.Fatal("outer wrapper/footer lost")
	}
	for _, input := range []string{`{}`, `null`, `[]`, `{"statusLine":{"type":"text","command":"cc-status"}}`, `{"statusLine":{"type":"command","command":"other"}}`, `{"statusLine":{"type":"command","command":"quota --statusline ???"}}`, `{"statusLine":{"type":"command","command":"quota --statusline YQ== --statusline Yg=="}}`} {
		if _, e = TransformSettings([]byte(input)); e == nil {
			t.Fatalf("accepted unrecognized settings %s", input)
		}
	}
}
func TestLegacyShimUpgradeAndGuard(t *testing.T) {
	for _, hooks := range []string{`{"hooks":{}}`, `{"hooks":{},"other":"retain"}`, `{}`} {
		t.Run(hooks, func(t *testing.T) {
			home, s := fixture(t)
			write(t, home, settingsPath, jsonBytes(t, baseSettings()))
			write(t, home, ".local/share/relay/shims/claude", []byte(legacyShim))
			write(t, home, ".relay/claude-hooks.json", []byte(hooks))
			e := s.Install(DefaultAssets())
			valid := hooks == `{"hooks":{}}`
			if (e == nil) != valid {
				t.Fatalf("shim guard error=%v", e)
			}
			got := read(t, home, ".local/share/relay/shims/claude")
			if valid {
				if string(got) != thinShim {
					t.Fatal("legacy settings remain")
				}
				info, e := os.Stat(filepath.Join(home, ".local/share/relay/shims/claude"))
				if e != nil || info.Mode().Perm() != 0700 {
					t.Fatal("thin shim must be executable/private")
				}
			} else if string(got) != legacyShim {
				t.Fatal("unrecognized hook state changed shim")
			}
			if string(read(t, home, ".relay/claude-hooks.json")) != hooks {
				t.Fatal("user helper hooks changed")
			}
		})
	}
}
func TestExactChittaRepairGuardBackupsAndIdempotence(t *testing.T) {
	home, s := fixture(t)
	raw := []byte("header\n" + anchor + "\n")
	write(t, home, adapterPath, raw)
	if e := os.Chmod(filepath.Join(home, adapterPath), 0640); e != nil {
		t.Fatal(e)
	}
	changed, e := s.Repair()
	if e != nil || !changed {
		t.Fatalf("repair %v", e)
	}
	got := read(t, home, adapterPath)
	expected, _, _ := RepairBytes(raw)
	if !bytes.Equal(got, expected) {
		t.Fatal("repair bytes differ")
	}
	info, e := os.Stat(filepath.Join(home, adapterPath))
	if e != nil || info.Mode().Perm() != 0640 {
		t.Fatal("adapter mode not preserved")
	}
	backup := read(t, home, ".config/relay/backups/chitta-failure-event-20261004/hook_client-"+hash(raw)+".py")
	if !bytes.Equal(backup, raw) {
		t.Fatal("original adapter backup lost")
	}
	before := privateBackups(t, home)
	changed, e = s.Repair()
	if e != nil || changed || !reflect.DeepEqual(before, privateBackups(t, home)) {
		t.Fatal("repair not idempotent")
	}
	otherHome, other := fixture(t)
	write(t, otherHome, strings.Replace(adapterPath, "5.73.1", "5.73.2", 1), raw)
	if _, e = other.Repair(); e == nil {
		t.Fatal("guessed unsupported plugin version")
	}
}
func TestEnabledPluginApplyAndUnrelatedHooks(t *testing.T) {
	home, s := fixture(t)
	data := baseSettings()
	data["enabledPlugins"] = map[string]any{"chitta@genomewalker-chitta": true, "other": true}
	write(t, home, settingsPath, jsonBytes(t, data))
	write(t, home, adapterPath, []byte(anchor))
	report, e := s.Apply(DefaultAssets())
	if e != nil || report.Drift || !report.Hooks.FailureAdapterRepaired || report.Hooks.ChittaEnabled != true {
		t.Fatalf("enabled apply %+v %v", report, e)
	}
	settings := semantic(t, read(t, home, settingsPath))
	if !reflect.DeepEqual(settings["hooks"], data["hooks"]) || !reflect.DeepEqual(settings["enabledPlugins"], data["enabledPlugins"]) {
		t.Fatal("user plugin/hooks configuration changed")
	}
}
func TestAuditFlagsEachDrift(t *testing.T) {
	for _, part := range []string{"asset", "status-type", "status-command", "suggestions", "plugin"} {
		t.Run(part, func(t *testing.T) {
			home, s := fixture(t)
			write(t, home, settingsPath, jsonBytes(t, baseSettings()))
			if _, e := s.Apply(DefaultAssets()); e != nil {
				t.Fatal(e)
			}
			data := semantic(t, read(t, home, settingsPath))
			switch part {
			case "asset":
				write(t, home, ".config/relay/claude-status", []byte("changed"))
			case "status-type":
				data["statusLine"].(map[string]any)["type"] = "text"
			case "status-command":
				data["statusLine"].(map[string]any)["command"] = "other"
			case "suggestions":
				data["promptSuggestionEnabled"] = false
			case "plugin":
				data["enabledPlugins"] = map[string]any{"chitta@genomewalker-chitta": true}
			}
			if part != "asset" {
				write(t, home, settingsPath, jsonBytes(t, data))
			}
			r, e := s.Audit(DefaultAssets())
			if part == "status-type" {
				if e != nil || r.Drift || r.Statusline.Managed {
					t.Fatalf("canonical status-type-only quirk changed: %+v %v", r, e)
				}
			} else if e != nil || !r.Drift {
				t.Fatalf("drift %s escaped: %+v %v", part, r, e)
			}
		})
	}
}

func TestSettingsScalarAndOutputBounds(t *testing.T) {
	for _, v := range []string{`"\ud800"`, `"\udc00"`, `"\ud800x"`, `"\ud800\ud800"`} {
		raw := []byte(`{"statusLine":{"type":"command","command":"cc-status"},"user":` + v + `}`)
		if _, e := TransformSettings(raw); e == nil {
			t.Fatal("silently replaced lone user surrogate")
		}
	}
	for _, v := range []string{`"\ud83d\ude80"`, `"\\ud800"`, `"å user"`} {
		raw := []byte(`{"statusLine":{"type":"command","command":"cc-status"},"user":` + v + `}`)
		if _, e := TransformSettings(raw); e != nil {
			t.Fatalf("valid scalar rejected %s: %v", v, e)
		}
	}
	raw := []byte(`{"statusLine":{"type":"command","command":"cc-status"},"user":"` + strings.Repeat("x", FileLimit) + `"}`)
	if _, e := TransformSettings(raw); e == nil {
		t.Fatal("oversized settings accepted")
	}
	// Input fits, but the canonical repair insertion/pretty indentation may
	// exceed the storage bound. Success must always be storable/idempotent.
	raw = []byte(strings.Repeat("x", FileLimit-len(anchor)) + anchor)
	if _, _, e := RepairBytes(raw); e == nil {
		t.Fatal("oversized repaired output accepted")
	}
	raw = []byte(`{"statusLine":{"type":"command","command":"cc-status"},"a":[` + strings.TrimSuffix(strings.Repeat(`0,`, (FileLimit-100)/2), ",") + `]}`)
	if len(raw) >= FileLimit {
		t.Fatal("fixture exceeds intended input bound")
	}
	if _, e := TransformSettings(raw); e == nil {
		t.Fatal("oversized indented output accepted")
	}
}

func TestEmbeddedAssetsMatchPrimaryBytes(t *testing.T) {
	expected := map[string]string{"relay-prompt.bash": "1b8c47e648dff7877a967b0ebe9a89d24300e8300d5856d67fcd8c654c55730a", "relay-cc-status.sh": "a0bbd465ad5e7f6e8f9d2554216479b3d96f49126ab374b2259efff8bc72060c"}
	for name, want := range expected {
		if hash(DefaultAssets()[name]) != want {
			t.Fatalf("canonical shell asset changed %s", name)
		}
	}
}

func TestCanonicalAuditMetadata(t *testing.T) {
	raw, e := os.ReadFile("testdata/canonical-metadata.json")
	if e != nil {
		t.Fatal(e)
	}
	var rows []struct {
		InputRaw string          `json:"input_raw"`
		Accepted bool            `json:"accepted"`
		Report   json.RawMessage `json:"report"`
	}
	if e = json.Unmarshal(raw, &rows); e != nil {
		t.Fatal(e)
	}
	if len(rows) != 38 {
		t.Fatal("primary metadata case bound changed")
	}
	for i, row := range rows {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			home, s := fixture(t)
			assets := DefaultAssets()
			for j, name := range assetNames {
				write(t, home, ".config/relay/"+destinations[j], assets[name])
			}
			write(t, home, settingsPath, []byte(row.InputRaw))
			report, e := s.Audit(assets)
			if (e == nil) != row.Accepted {
				t.Fatalf("canonical metadata acceptance=%t native=%v input=%s", row.Accepted, e, row.InputRaw)
			}
			if e != nil {
				return
			}
			var wire map[string]json.RawMessage
			if e = json.Unmarshal(jsonBytes(t, report), &wire); e != nil {
				t.Fatal(e)
			}
			subset := map[string]json.RawMessage{"hooks": wire["hooks"], "drift": wire["drift"], "statusline": wire["statusline"]}
			var got, want any
			if e = json.Unmarshal(jsonBytes(t, subset), &got); e != nil {
				t.Fatal(e)
			}
			if e = json.Unmarshal(row.Report, &want); e != nil {
				t.Fatal(e)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("primary metadata differ: got %v want %v input=%s", got, want, row.InputRaw)
			}
		})
	}
}
