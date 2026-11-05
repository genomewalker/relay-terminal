package providersetup

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func migrationInput(t *testing.T, home, renderer string) []byte {
	t.Helper()
	v := baseSettings()
	v["precision"] = json.Number("9007199254740993")
	v["statusLine"].(map[string]any)["command"] = "python3 " + filepath.Join(home, legacyQuotaPath) + " --statusline " + base64.StdEncoding.EncodeToString([]byte(renderer))
	return jsonBytes(t, v)
}

func assertMigrationOnly(t *testing.T, before, after []byte, home string) {
	t.Helper()
	a, b := semantic(t, before), semantic(t, after)
	x, y := a["statusLine"].(map[string]any), b["statusLine"].(map[string]any)
	old := x["command"].(string)
	encoded := strings.TrimRight(strings.TrimPrefix(old, "python3 "+filepath.Join(home, legacyQuotaPath)+" --statusline "), " \t")
	want := shellLiteral(filepath.Join(home, ".local/bin/relayd")) + " subscription-quota-statusline " + shellLiteral(encoded)
	if y["command"] != want {
		t.Fatal("renderer argument or native dispatch changed")
	}
	delete(x, "command")
	delete(y, "command")
	if !reflect.DeepEqual(a, b) {
		t.Fatal("unrelated settings changed")
	}
}

func TestQuotaMigrationRendererAndRejection(t *testing.T) {
	home := "/tmp/relay-managed-home"
	for _, renderer := range []string{"printf '%s' '$HOME'", "bash \"$HOME/.config/relay/cc-status.sh\"", "printf 'å😀\\n'; exit 7"} {
		before := migrationInput(t, home, renderer)
		after, e := MigrateQuotaSettings(before, home)
		if e != nil {
			t.Fatal(e)
		}
		assertMigrationOnly(t, before, after, home)
		second, e := MigrateQuotaSettings(after, home)
		if e != nil || !bytes.Equal(after, second) {
			t.Fatal("native migration is not byte-idempotent")
		}
	}
	v := semantic(t, migrationInput(t, home, "user-footer"))
	command := v["statusLine"].(map[string]any)["command"].(string)
	for _, bad := range []string{command + " --extra", command + "; touch /tmp/forbidden", strings.Replace(command, "python3 ", "python3 -u ", 1), strings.Replace(command, home, "/other-home", 1), strings.Replace(command, "subscription_quota.py", "custom.py", 1), strings.Replace(command, "--statusline ", "--statusline\t", 1), command + "\n", strings.TrimSuffix(command, base64.StdEncoding.EncodeToString([]byte("user-footer")))} {
		v["statusLine"].(map[string]any)["command"] = bad
		if _, e := MigrateQuotaSettings(jsonBytes(t, v), home); e == nil {
			t.Fatal("unrecognized wrapper accepted")
		}
	}
	for _, bad := range [][]byte{[]byte(`{}`), []byte(`null`), []byte(`{"statusLine":{"type":"text","command":"cc-status"}}`), append(migrationInput(t, home, "x"), []byte(` {}`)...), bytes.Repeat([]byte("x"), FileLimit+1)} {
		if _, e := MigrateQuotaSettings(bad, home); e == nil {
			t.Fatal("invalid migration input accepted")
		}
	}
}

func TestQuotaMigrationStoreAndCLI(t *testing.T) {
	home, s := fixture(t)
	before := migrationInput(t, home, "printf footer")
	legacy := []byte("reviewed legacy managed source\n")
	write(t, home, settingsPath, before)
	write(t, home, legacyQuotaPath, legacy)
	for _, hashes := range [][2]string{{strings.Repeat("0", 64), hash(legacy)}, {hash(before), strings.Repeat("0", 64)}, {"bad", hash(legacy)}} {
		if e := s.MigrateQuotaStatusline(home, hashes[0], hashes[1]); e == nil {
			t.Fatal("changed preimage accepted")
		}
		if !bytes.Equal(read(t, home, settingsPath), before) {
			t.Fatal("failed migration changed settings")
		}
	}
	var out, errout bytes.Buffer
	if code := Main(context.Background(), []string{"migrate-quota-statusline", hash(before), hash(legacy)}, home, strings.NewReader(""), &out, &errout); code != 0 {
		t.Fatalf("CLI migration failed: %s", errout.String())
	}
	after := read(t, home, settingsPath)
	assertMigrationOnly(t, before, after, home)
	backups := privateBackups(t, home)
	if len(backups) != 1 {
		t.Fatal("original settings backup missing")
	}
	for _, raw := range backups {
		if !bytes.Equal(raw, before) {
			t.Fatal("backup is not the preimage")
		}
	}
	if !bytes.Equal(read(t, home, legacyQuotaPath), legacy) {
		t.Fatal("migration modified legacy source")
	}
	if e := s.MigrateQuotaStatusline(home, hash(after), hash(legacy)); e != nil {
		t.Fatal(e)
	}
	if len(privateBackups(t, home)) != 1 {
		t.Fatal("idempotent migration created backup")
	}
}

func TestQuotaMigrationLegacyTrailingWhitespace(t *testing.T) {
	home := "/tmp/relay-managed-home"
	for _, padding := range []string{" ", "\t "} {
		before := semantic(t, migrationInput(t, home, "footer"))
		status := before["statusLine"].(map[string]any)
		status["command"] = status["command"].(string) + padding
		raw := jsonBytes(t, before)
		after, err := MigrateQuotaSettings(raw, home)
		if err != nil {
			t.Fatal("managed horizontal whitespace rejected", err)
		}
		assertMigrationOnly(t, raw, after, home)
	}
}

func TestQuotaMigrationReinstallAndAuditNativeCommand(t *testing.T) {
	home, s := fixture(t)
	legacy := []byte("legacy reviewed source")
	write(t, home, settingsPath, migrationInput(t, home, Launcher))
	write(t, home, legacyQuotaPath, legacy)
	if err := s.Install(DefaultAssets()); err != nil {
		t.Fatal(err)
	}
	before := read(t, home, settingsPath)
	if err := s.MigrateQuotaStatusline(home, hash(before), hash(legacy)); err != nil {
		t.Fatal(err)
	}
	native := read(t, home, settingsPath)
	report, err := s.Audit(DefaultAssets())
	if err != nil || !report.Statusline.Managed || !report.Statusline.QuotaCapture || report.Drift {
		t.Fatal("native quota command not recognized by audit", err)
	}
	if err := s.Install(DefaultAssets()); err != nil {
		t.Fatal("native quota reinstall refused", err)
	}
	if !bytes.Equal(read(t, home, settingsPath), native) {
		t.Fatal("native reinstall changed canonical settings")
	}
	// A foreign home containing the old renderer name must not fall through
	// the legacy cc-status recognizer and silently remove the quota wrapper.
	v := semantic(t, native)
	v["statusLine"].(map[string]any)["command"] = nativeQuotaPrefix("/foreign/cc-status") + shellLiteral(base64.StdEncoding.EncodeToString([]byte(Launcher)))
	foreign := jsonBytes(t, v)
	write(t, home, settingsPath, foreign)
	report, err = s.Audit(DefaultAssets())
	if err != nil || report.Statusline.Managed || report.Statusline.QuotaCapture || !report.Drift {
		t.Fatal("foreign native quota command treated as managed")
	}
	if err = s.Install(DefaultAssets()); err == nil {
		t.Fatal("foreign native quota command installed")
	}
	if !bytes.Equal(read(t, home, settingsPath), foreign) {
		t.Fatal("foreign settings overwritten")
	}
}

func TestQuotaMigrationNativeRendererSyntax(t *testing.T) {
	home := "/tmp/cc-status-home"
	for _, tail := range []string{"Zm9v", "'???'", "'ZE=='", "'AA=='", "'//8='", "'Zg==' extra", "'Zg=='\n"} {
		v := semantic(t, migrationInput(t, home, Launcher))
		v["statusLine"].(map[string]any)["command"] = nativeQuotaPrefix(home) + tail
		if _, err := transformSettings(jsonBytes(t, v), home); err == nil {
			t.Fatal("malformed native renderer accepted")
		}
	}
	for _, home := range []string{"/tmp/plain", "/tmp/å home'quoted"} {
		command := nativeQuotaPrefix(home) + shellLiteral(base64.StdEncoding.EncodeToString([]byte(Launcher)))
		encoded, err := nativeQuotaEncoded(command, home)
		if err != nil || encoded != base64.StdEncoding.EncodeToString([]byte(Launcher)) {
			t.Fatal("literal native home or renderer changed")
		}
	}
}

func TestQuotaMigrationRejectsScheduledSettingsChange(t *testing.T) {
	for _, kind := range []string{"write", "replace", "remove", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			home, s := fixture(t)
			before := migrationInput(t, home, "footer")
			legacy := []byte("legacy")
			write(t, home, settingsPath, before)
			write(t, home, legacyQuotaPath, legacy)
			external := []byte(`{"external":"preserve"}`)
			s.beforeCommit = func(path string) {
				if path != settingsPath {
					t.Fatal("unexpected mutation destination")
				}
				full := filepath.Join(home, path)
				switch kind {
				case "write":
					write(t, home, path, external)
				case "replace":
					if e := os.Remove(full); e != nil {
						t.Fatal(e)
					}
					write(t, home, path, external)
				case "remove":
					if e := os.Remove(full); e != nil {
						t.Fatal(e)
					}
				case "symlink":
					if e := os.Remove(full); e != nil {
						t.Fatal(e)
					}
					if e := os.Symlink("absent", full); e != nil {
						t.Fatal(e)
					}
				}
			}
			if e := s.MigrateQuotaStatusline(home, hash(before), hash(legacy)); e == nil {
				t.Fatal("concurrent settings change overwritten")
			}
			if kind == "write" || kind == "replace" {
				if !bytes.Equal(read(t, home, settingsPath), external) {
					t.Fatal("external settings lost")
				}
			}
			if kind == "symlink" {
				if info, e := os.Lstat(filepath.Join(home, settingsPath)); e != nil || info.Mode()&os.ModeSymlink == 0 {
					t.Fatal("external symlink lost")
				}
			}
			if kind == "remove" {
				if _, e := os.Lstat(filepath.Join(home, settingsPath)); !os.IsNotExist(e) {
					t.Fatal("removed settings recreated")
				}
			}
		})
	}
}

func TestQuotaMigrationBoundedHistories(t *testing.T) {
	// All 4^3 operation histories. Every transition checks the real store;
	// existing generic Store CAS tests cover two-actor filesystem schedules.
	transitions := 0
	for history := 0; history < 64; history++ {
		t.Run(fmt.Sprint(history), func(t *testing.T) {
			home, s := fixture(t)
			initial := migrationInput(t, home, "footer")
			legacy := []byte("legacy")
			write(t, home, settingsPath, initial)
			write(t, home, legacyQuotaPath, legacy)
			code := history
			native, legacyChanged := false, false
			for step := 0; step < 3; step++ {
				op := code % 4
				code /= 4
				before := read(t, home, settingsPath)
				switch op {
				case 0, 1:
					expected := hash(initial)
					if op == 1 {
						expected = hash(before)
					}
					e := s.MigrateQuotaStatusline(home, expected, hash(legacy))
					wantError := expected != hash(before) || (!native && legacyChanged)
					if (e != nil) != wantError {
						t.Fatal("bounded migration preimage policy changed", history, step)
					}
					after := read(t, home, settingsPath)
					if e != nil {
						if !bytes.Equal(before, after) {
							t.Fatal("refusal changed settings")
						}
					} else if !bytes.Equal(before, after) {
						assertMigrationOnly(t, before, after, home)
					}
					if e == nil {
						native = true
					}
				case 2:
					v := semantic(t, before)
					v["external"] = json.Number(fmt.Sprint(step))
					write(t, home, settingsPath, jsonBytes(t, v))
				case 3:
					write(t, home, legacyQuotaPath, []byte("externally changed"))
					legacyChanged = true
				}
				transitions++
			}
		})
	}
	if transitions != 192 {
		t.Fatal("history bound changed")
	}
	t.Log("64 histories / 192 transitions; settings preimage, renderer, unrelated settings and refusal preservation checked")
}

func FuzzQuotaSettingsMigration(f *testing.F) {
	for _, command := range []string{"python3 /tmp/relay-home/.local/share/relay/subscription-quotas/subscription_quota.py --statusline Zm9vdGVy", "python3 /tmp/relay-home/.local/share/relay/subscription-quotas/subscription_quota.py --statusline Zm9vdGVy ", "unrelated", "'bad'"} {
		raw, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": command}, "user": json.Number("9007199254740993")})
		f.Add(raw)
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		out, e := MigrateQuotaSettings(raw, "/tmp/relay-home")
		if e != nil {
			return
		}
		if len(raw) > FileLimit || len(out) > FileLimit {
			t.Fatal("input/output bound exceeded")
		}
		before, after := semantic(t, raw), semantic(t, out)
		x, y := before["statusLine"].(map[string]any), after["statusLine"].(map[string]any)
		delete(x, "command")
		delete(y, "command")
		if !reflect.DeepEqual(before, after) {
			t.Fatal("unrelated setting changed")
		}
		again, e := MigrateQuotaSettings(out, "/tmp/relay-home")
		if e != nil || !bytes.Equal(out, again) {
			t.Fatal("migration not idempotent")
		}
		installed, e := transformSettings(out, "/tmp/relay-home")
		if e != nil {
			t.Fatal("native migration cannot be reinstalled")
		}
		configured := semantic(t, installed)
		command := configured["statusLine"].(map[string]any)["command"].(string)
		encoded, e := nativeQuotaEncoded(command, "/tmp/relay-home")
		if e != nil || encoded != base64.StdEncoding.EncodeToString([]byte(Launcher)) {
			t.Fatal("native reinstall lost quota dispatch or managed renderer")
		}
		if _, e := MigrateQuotaSettings(append(append([]byte(nil), out...), []byte(` {}`)...), "/tmp/relay-home"); e == nil {
			t.Fatal("trailing JSON accepted")
		}
	})
}

func TestQuotaMigrationTwoActorInterleavings(t *testing.T) {
	count, transitions := 0, 0
	for first := 0; first < 3; first++ {
		for second := first + 1; second < 4; second++ {
			home, s := fixture(t)
			initial := migrationInput(t, home, "footer")
			legacy := []byte("legacy")
			write(t, home, settingsPath, initial)
			write(t, home, legacyQuotaPath, legacy)
			next := [2]int{}
			for position := 0; position < 4; position++ {
				actor := 1
				if position == first || position == second {
					actor = 0
				}
				before := read(t, home, settingsPath)
				if next[actor] == 0 {
					err := s.MigrateQuotaStatusline(home, hash(initial), hash(legacy))
					if (err != nil) != (hash(before) != hash(initial)) {
						t.Fatal("two-actor migration preimage policy changed")
					}
					after := read(t, home, settingsPath)
					if err != nil && !bytes.Equal(before, after) {
						t.Fatal("stale actor overwrote external settings")
					}
					if err == nil {
						assertMigrationOnly(t, before, after, home)
					}
				} else {
					v := semantic(t, before)
					v[fmt.Sprintf("actor%d", actor)] = "preserve"
					write(t, home, settingsPath, jsonBytes(t, v))
				}
				next[actor]++
				v := semantic(t, read(t, home, settingsPath))
				for a := range next {
					if next[a] == 2 && v[fmt.Sprintf("actor%d", a)] != "preserve" {
						t.Fatal("actor setting lost")
					}
				}
				transitions++
			}
			count++
		}
	}
	if count != 6 || transitions != 24 {
		t.Fatal("interleaving bound changed")
	}
	t.Log("6 order-preserving two-actor interleavings / 24 transitions")
}
