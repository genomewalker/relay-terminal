package nativeprovider

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func sum(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func put(t *testing.T, p string, b []byte, mode os.FileMode) {
	t.Helper()
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(p, b, mode); e != nil {
		t.Fatal(e)
	}
}
func sources(t *testing.T) string {
	p := filepath.Join(t.TempDir(), "src")
	for _, n := range names {
		put(t, filepath.Join(p, n), []byte(n), 0700)
	}
	return p
}
func fakeVersion(c Command) ([]byte, error) {
	if c.Timeout != 15*time.Second {
		return nil, fmt.Errorf("version/help timeout changed")
	}
	return []byte("codex-cli 0.160.0\n"), nil
}

type oracle struct {
	Mode, Scenario string
	OK             bool
	Result         map[string]any
	Cargo          [][]string
	Fetches        int
}

func TestOriginalOracle(t *testing.T) {
	b, e := os.ReadFile("testdata/oracle.json")
	if e != nil {
		t.Fatal(e)
	}
	var cases []oracle
	if e = json.Unmarshal(b, &cases); e != nil {
		t.Fatal(e)
	}
	if len(cases) != 25 {
		t.Fatal("oracle count changed")
	}
	for _, c := range cases {
		t.Run(c.Mode+"/"+c.Scenario, func(t *testing.T) {
			var err error
			var result map[string]any
			switch c.Mode {
			case "build":
				root, target, downloads := buildFixture(t, c.Scenario)
				var cargo [][]string
				fetches := 0
				run := func(cmd Command) ([]byte, error) {
					switch cmd.Args[0] {
					case "curl":
						fetches++
						b, ok := downloads[filepath.Base(cmd.Args[2])]
						if !ok {
							return nil, fmt.Errorf("unexpected fetch")
						}
						return nil, os.WriteFile(cmd.Args[4], b, 0600)
					case "cargo":
						if !cmd.Stream {
							t.Fatal("cargo output must stream")
						}
						cargo = append(cargo, cmd.Args)
						if cmd.Dir != filepath.Join(root, "codex-rs") {
							t.Fatal("cargo cwd changed")
						}
						env := strings.Join(cmd.Env, "\n")
						for _, k := range []string{"RUSTY_V8_ARCHIVE=", "RUSTY_V8_SRC_BINDING_PATH="} {
							if !strings.Contains(env, k+filepath.Join(root, ".relay-codehost-v8", target)) {
								t.Fatal("verified asset environment missing")
							}
						}
					}
					return nil, nil
				}
				err = Build(root, target, c.Scenario == "bundle", run)
				if c.OK && (!reflect.DeepEqual(cargo, c.Cargo) || fetches != c.Fetches) {
					t.Fatalf("oracle command mismatch cargo=%v fetches=%d", cargo, fetches)
				}
				if !c.OK && len(cargo) > 0 {
					t.Fatal("untrusted build executed")
				}
			case "install":
				src := sources(t)
				home := t.TempDir()
				o := InstallOptions{Codex: filepath.Join(src, names[0]), Worker: filepath.Join(src, names[1]), Home: home, StageOnly: c.Scenario == "stage"}
				parent := filepath.Join(home, ".local/share/relay")
				os.MkdirAll(parent, 0700)
				if c.Scenario == "unmanaged" {
					os.Mkdir(filepath.Join(parent, "native-codex"), 0700)
				}
				if c.Scenario == "existing_link" {
					os.Mkdir(filepath.Join(parent, "old"), 0700)
					os.Symlink("old", filepath.Join(parent, "native-codex"))
				}
				if c.Scenario == "missing_worker" {
					os.Remove(o.Worker)
				}
				if c.Scenario == "manifest" || c.Scenario == "bad_manifest" {
					files := map[string]string{}
					if c.Scenario == "manifest" {
						for _, n := range names {
							files[n] = sum([]byte(n))
						}
					}
					o.Expected = filepath.Join(home, "expected.json")
					put(t, o.Expected, jsonBytes(map[string]any{"files": files}), 0600)
				}
				run := fakeVersion
				if c.Scenario == "bad_version" {
					run = func(Command) ([]byte, error) { return []byte("unexpected"), nil }
				}
				result, err = Install(o, run)
				if err == nil {
					installed := result["installed"].(string)
					checkPrivate(t, installed)
					if !o.StageOnly {
						info, e := os.Lstat(installed)
						if e != nil || info.Mode()&os.ModeSymlink == 0 {
							t.Fatal("activation was not a symlink")
						}
					}
					delete(result, "installed")
				}
			case "repair":
				root, src := repairFixture(t, c.Scenario)
				result, err = Repair(root, src, fakeVersion)
				if err == nil {
					delete(result, "installation")
					for _, n := range names[:2] {
						b, _ := os.ReadFile(filepath.Join(root, n))
						if string(b) != n {
							t.Fatal("existing executable changed")
						}
					}
				}
			}
			if (err == nil) != c.OK {
				t.Fatalf("oracle outcome differs: ok=%v error=%v", c.OK, err)
			}
			if c.OK && c.Mode != "build" && !reflect.DeepEqual(result, c.Result) {
				t.Fatalf("oracle result differs got=%v want=%v", result, c.Result)
			}
		})
	}
}
func checkPrivate(t *testing.T, installed string) {
	t.Helper()
	s, e := os.Stat(installed)
	if e != nil || s.Mode().Perm() != 0700 {
		t.Fatal("stage directory not private")
	}
	for _, n := range append(append([]string{}, names...), "installed.json") {
		s, e := os.Stat(filepath.Join(installed, n))
		want := os.FileMode(0700)
		if n == "installed.json" {
			want = 0600
		}
		if e != nil || s.Mode().Perm() != want {
			t.Fatal("file permissions changed", n)
		}
	}
	b, _ := os.ReadFile(filepath.Join(installed, "installed.json"))
	m, e := parseObject(b)
	if e != nil || m["version"] != "0.160.0-relay-native-1" || fmt.Sprint(m["native_inbox_protocol"]) != "1" || m["platform"] == "" || m["arch"] == "" {
		t.Fatal("bundle manifest metadata changed")
	}
	files, e := filesOf(m)
	if e != nil || len(files) != 3 {
		t.Fatal("bundle companion set changed")
	}
	for _, n := range names {
		h, e := hashFile(filepath.Join(installed, n))
		if e != nil || h != files[n] {
			t.Fatal("bundle hash mismatch")
		}
	}
}
func buildFixture(t *testing.T, scenario string) (string, string, map[string][]byte) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	target := "aarch64-apple-darwin"
	profile := "ptrcomp_sandbox_release_" + target
	mn := "rusty_v8_" + profile + ".sha256"
	an := "librusty_v8_" + profile + ".a.gz"
	bn := "src_binding_" + profile + ".rs"
	downloads := map[string][]byte{an: []byte("archive"), bn: []byte("binding")}
	lines := []string{sum(downloads[an]) + "  " + an, sum(downloads[bn]) + "  " + bn}
	if scenario == "extra_asset" {
		downloads["extra"] = []byte("extra")
		lines = append(lines, sum(downloads["extra"])+"  extra")
	}
	if scenario == "path_asset" {
		lines[0] = sum(downloads[an]) + "  ../escape"
	}
	manifest := []byte(strings.Join(lines, "\n") + "\n")
	downloads[mn] = manifest
	digest := sum(manifest)
	if scenario == "bad_manifest_hash" {
		digest = strings.Repeat("0", 64)
	}
	trusted := filepath.Join(root, "third_party/v8/rusty_v8_150_4_0_release_manifests.sha256")
	put(t, trusted, []byte(digest+" "+mn+"\n"), 0600)
	os.Mkdir(filepath.Join(root, "codex-rs"), 0700)
	if scenario == "missing_trust" {
		os.Remove(trusted)
	}
	if scenario == "bad_asset_hash" {
		downloads[an] = []byte("bad")
	}
	if scenario == "cached" {
		for n, b := range downloads {
			put(t, filepath.Join(root, ".relay-codehost-v8", target, n), b, 0600)
		}
	}
	return root, target, downloads
}
func repairFixture(t *testing.T, scenario string) (string, string) {
	root := t.TempDir()
	src := filepath.Join(sources(t), names[2])
	files := map[string]string{}
	for _, n := range names[:2] {
		put(t, filepath.Join(root, n), []byte(n), 0700)
		files[n] = sum([]byte(n))
	}
	version := "0.160.0-relay-native-1"
	if scenario == "wrong_version" {
		version = "wrong"
	}
	if scenario == "bad_codex" {
		put(t, filepath.Join(root, "codex"), []byte("bad"), 0700)
	}
	if scenario == "missing_source" {
		os.Remove(src)
	}
	if scenario == "already" || scenario == "same_host" || scenario == "different_host" {
		b := []byte(names[2])
		if scenario == "different_host" {
			b = []byte("bad")
		}
		put(t, filepath.Join(root, names[2]), b, 0700)
		if scenario == "already" {
			files[names[2]] = sum(b)
		}
	}
	if scenario == "symlink_host" {
		os.Symlink(src, filepath.Join(root, names[2]))
	}
	if scenario == "existing_backup" {
		put(t, filepath.Join(root, "installed.before-codehost.json"), []byte("prior"), 0600)
	}
	put(t, filepath.Join(root, "installed.json"), jsonBytes(map[string]any{"version": version, "files": files}), 0600)
	return root, src
}
func TestInstallBoundedOwnership(t *testing.T) {
	// Real sequential lifecycle: 4 operations, all 4^3 schedules, immutable bytes after every transition.
	count := 0
	for a := 0; a < 4; a++ {
		for b := 0; b < 4; b++ {
			for c := 0; c < 4; c++ {
				home := t.TempDir()
				src := sources(t)
				active := ""
				snapshots := map[string]string{}
				for _, op := range []int{a, b, c} {
					o := InstallOptions{Home: home, Codex: filepath.Join(src, names[0]), Worker: filepath.Join(src, names[1]), StageOnly: op == 1}
					if op == 2 {
						o.Expected = filepath.Join(home, "reject.json")
						put(t, o.Expected, []byte(`{"files":{}}`), 0600)
					}
					dst := filepath.Join(home, ".local/share/relay/native-codex")
					if op == 3 {
						os.Remove(dst)
						os.MkdirAll(dst, 0700)
						active = ""
					}
					r, e := Install(o, fakeVersion)
					s, se := os.Lstat(dst)
					unmanaged := se == nil && s.Mode()&os.ModeSymlink == 0
					if op == 2 || unmanaged {
						if e == nil {
							t.Fatal("ownership or acceptance rejection bypassed")
						}
					} else {
						if e != nil {
							t.Fatal(e)
						}
						p := r["installed"].(string)
						if !o.StageOnly {
							active, _ = os.Readlink(dst)
						}
						resolved, _ := filepath.EvalSymlinks(p)
						for _, n := range names {
							h, _ := hashFile(filepath.Join(resolved, n))
							snapshots[filepath.Join(resolved, n)] = h
						}
					}
					if !unmanaged {
						got, _ := os.Readlink(dst)
						if got != active {
							t.Fatal("stage/failure changed activation")
						}
					}
					for p, h := range snapshots {
						got, e := hashFile(p)
						if e != nil || got != h {
							t.Fatal("immutable bundle overwritten")
						}
					}
					count++
				}
			}
		}
	}
	if count != 192 {
		t.Fatal("bound changed")
	}
	t.Log("64 depth-3 sequences; 192 transitions; four install/stage/reject/unmanaged operations")
}
func TestConcurrentInstalls(t *testing.T) {
	home := t.TempDir()
	src := sources(t)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := Install(InstallOptions{Home: home, Codex: filepath.Join(src, names[0]), Worker: filepath.Join(src, names[1])}, fakeVersion)
			errs <- e
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	checkPrivate(t, filepath.Join(home, ".local/share/relay/native-codex"))
}
func TestRepairManifestRace(t *testing.T) {
	root, src := repairFixture(t, "valid")
	_, e := Repair(root, src, func(Command) ([]byte, error) {
		put(t, filepath.Join(root, "installed.json"), []byte(`{"changed":true}`), 0600)
		return nil, nil
	})
	if e == nil || !strings.Contains(e.Error(), "changed during repair") {
		t.Fatal("manifest race accepted")
	}
	b, _ := os.ReadFile(filepath.Join(root, "installed.json"))
	if string(b) != `{"changed":true}` {
		t.Fatal("racing manifest overwritten")
	}
}
func TestParsers(t *testing.T) {
	for _, b := range []string{`{"x":1,"x":2}`, `{"files":{"x":1,"x":2}}`, `[]`, `{} {}`, `{"x":`, strings.Repeat(" ", maxManifest+1), `{"x":` + strings.Repeat("[", 34) + `0` + strings.Repeat("]", 34) + `}`} {
		if _, e := parseObject([]byte(b)); e == nil {
			t.Fatal("ambiguous JSON accepted")
		}
	}
	for _, b := range []string{sum(nil) + " ../escape", sum(nil) + " a\n" + sum(nil) + " a", "bad a", sum(nil) + " a b", sum(nil) + " ..", sum(nil) + " a\\b"} {
		if _, e := parseSums([]byte(b)); e == nil {
			t.Fatal("unsafe checksum manifest accepted")
		}
	}
	if _, e := parseObject([]byte("{\"x\":\"\xff\"}")); e == nil {
		t.Fatal("invalid Unicode accepted")
	}
}
func TestCLIUsage(t *testing.T) {
	for _, kind := range []string{"build", "install", "repair", "unknown"} {
		var b bytes.Buffer
		if CLI(kind, nil, &b, &b) != 2 {
			t.Fatal("usage must exit 2")
		}
	}
}
func TestBoundedOutput(t *testing.T) {
	var b boundedBuffer
	b.Write(make([]byte, maxManifest+2))
	if !b.overflow || b.Len() > maxManifest {
		t.Fatal("command output bound ignored")
	}
}
func FuzzManifestJSON(f *testing.F) {
	for _, s := range []string{`{"files":{}}`, `{"x":1,"x":2}`, `{"x":[1,true,null]}`, `{"x":`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := parseObject(b)
		if len(b) > maxManifest && e == nil {
			t.Fatal("JSON size ignored")
		}
		if e != nil {
			return
		}
		encoded := jsonBytes(m)
		round, e := parseObject(encoded)
		if e != nil || !reflect.DeepEqual(m, round) {
			t.Fatal("JSON round trip changed")
		}
		if _, e = parseObject(encoded[:len(encoded)-2]); e == nil {
			t.Fatal("truncated JSON accepted")
		}
	})
}
func FuzzManifestSums(f *testing.F) {
	for _, s := range []string{sum(nil) + " asset", sum(nil) + " ../escape", "bad"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := parseSums(b)
		if e != nil {
			return
		}
		var out strings.Builder
		for n, h := range m {
			if !safeName(n) || !digestPattern.MatchString(h) {
				t.Fatal("checksum path escaped")
			}
			fmt.Fprintf(&out, "%s %s\n", h, n)
		}
		round, e := parseSums([]byte(out.String()))
		if e != nil || !reflect.DeepEqual(m, round) {
			t.Fatal("checksum round trip changed")
		}
	})
}
func FuzzNativeVersionTarget(f *testing.F) {
	for _, s := range []string{"codex-cli 0.160.0", "../escape", "aarch64-apple-darwin", "x/y"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if targetPattern.MatchString(s) && (!safeName(s) || len(s) > 128) {
			t.Fatal("target path escaped")
		}
		if m := stableVersion.FindStringSubmatch(s); m != nil {
			if !safeName("native-codex-"+m[1]) || "codex-cli "+m[1] != s {
				t.Fatal("version path escaped")
			}
		}
	})
}
func TestInstallTwoActorInterleavings(t *testing.T) {
	schedules := [][]int{{0, 0, 1, 1}, {0, 1, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, 1}, {1, 0, 1, 0}, {1, 1, 0, 0}}
	transitions := 0
	for _, schedule := range schedules {
		home := t.TempDir()
		src := sources(t)
		stages := [2]string{}
		active := ""
		dst := filepath.Join(home, ".local/share/relay/native-codex")
		for _, actor := range schedule {
			if stages[actor] == "" {
				r, e := Install(InstallOptions{Home: home, Codex: filepath.Join(src, names[0]), Worker: filepath.Join(src, names[1]), StageOnly: true}, fakeVersion)
				if e != nil {
					t.Fatal(e)
				}
				stages[actor] = r["installed"].(string)
			} else {
				committed, e := activateStage(stages[actor], dst)
				if e != nil || !committed {
					t.Fatal("activation did not commit", e)
				}
				active = filepath.Base(stages[actor])
			}
			got, _ := os.Readlink(dst)
			if got != active {
				t.Fatal("nonactivating operation changed reference")
			}
			for _, stage := range stages {
				if stage != "" {
					checkPrivate(t, stage)
				}
			}
			transitions++
		}
	}
	if transitions != 24 {
		t.Fatal("interleaving bound changed")
	}
	t.Log("6 two-actor prepare/activate interleavings, 24 transitions; actual Install and activateStage")
}
func TestRepairBoundedOwnership(t *testing.T) {
	count := 0
	for version := 0; version < 2; version++ {
		for integrity := 0; integrity < 4; integrity++ {
			for host := 0; host < 4; host++ {
				for backup := 0; backup < 2; backup++ {
					root, src := repairFixture(t, "valid")
					mp := filepath.Join(root, "installed.json")
					mdata, _ := os.ReadFile(mp)
					m, _ := parseObject(mdata)
					if version == 1 {
						m["version"] = "unsupported"
						put(t, mp, jsonBytes(m), 0600)
					}
					if integrity&1 != 0 {
						put(t, filepath.Join(root, names[0]), []byte("changed"), 0700)
					}
					if integrity&2 != 0 {
						put(t, filepath.Join(root, names[1]), []byte("changed"), 0700)
					}
					hp := filepath.Join(root, names[2])
					if host == 1 {
						put(t, hp, []byte(names[2]), 0700)
					} else if host == 2 {
						put(t, hp, []byte("foreign"), 0700)
					} else if host == 3 {
						os.Symlink(src, hp)
					}
					bp := filepath.Join(root, "installed.before-codehost.json")
					if backup == 1 {
						put(t, bp, []byte("preserve backup"), 0600)
					}
					before, _ := os.ReadFile(mp)
					_, e := Repair(root, src, fakeVersion)
					want := version == 0 && integrity == 0 && host < 2 && backup == 0
					if (e == nil) != want {
						t.Fatal("repair ownership state accepted/rejected incorrectly", version, integrity, host, backup, e)
					}
					if !want {
						after, _ := os.ReadFile(mp)
						if !bytes.Equal(before, after) {
							t.Fatal("rejected repair changed manifest")
						}
					}
					if host == 2 {
						b, _ := os.ReadFile(hp)
						if string(b) != "foreign" {
							t.Fatal("foreign host overwritten")
						}
					}
					if host == 3 {
						s, _ := os.Lstat(hp)
						if s.Mode()&os.ModeSymlink == 0 {
							t.Fatal("foreign symlink overwritten")
						}
					}
					if backup == 1 {
						b, _ := os.ReadFile(bp)
						if string(b) != "preserve backup" {
							t.Fatal("exclusive backup overwritten")
						}
					}
					count++
				}
			}
		}
	}
	if count != 64 {
		t.Fatal("repair bound changed")
	}
	t.Log("64 real repair states: version x two companion integrity bits x host ownership x backup")
}
func TestParserBounds(t *testing.T) {
	if _, e := parseObject([]byte(`{"padding":"` + strings.Repeat("x", maxManifest) + `"}`)); e == nil {
		t.Fatal("JSON byte bound ignored")
	}
	if _, e := parseSums([]byte(sum(nil) + " " + strings.Repeat("x", maxManifest))); e == nil {
		t.Fatal("checksum byte bound ignored")
	}
}
func TestExecuteFixture(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "fixture")
	put(t, script, []byte("#!/bin/sh\nprintf '%s' \"$1\"\n"), 0700)
	out, e := Execute(Command{Args: []string{script, "fixture-output"}, Timeout: time.Second})
	if e != nil || string(out) != "fixture-output" {
		t.Fatal("actual command output changed", e)
	}
	put(t, script, []byte("#!/bin/sh\nexec /bin/sleep 1\n"), 0700)
	_, e = Execute(Command{Args: []string{script}, Timeout: 20 * time.Millisecond})
	if e == nil {
		t.Fatal("command timeout ignored")
	}
}

// The subprocesses are this test binary, never an installed provider. The
// descendant deliberately retains stdout and exits naturally after two seconds.
func TestExecuteInheritedPipeFixture(t *testing.T) {
	role := os.Getenv("RELAY_NATIVEPROVIDER_PIPE_FIXTURE")
	if role == "" {
		return
	}
	dir := os.Getenv("RELAY_NATIVEPROVIDER_PIPE_DIRECTORY")
	if role == "descendant" {
		fmt.Fprintln(os.Stdout, "private-descendant-ready")
		if err := os.WriteFile(filepath.Join(dir, "descendant-ready"), []byte("ready"), 0600); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Second)
		if err := os.WriteFile(filepath.Join(dir, "descendant-completed"), []byte("done"), 0600); err != nil {
			t.Fatal(err)
		}
		fmt.Fprintln(os.Stdout, "private-descendant-completed")
		return
	}
	if role != "parent" && role != "parent-exit" {
		t.Fatal("invalid fixture role")
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command(executable, "-test.run=^TestExecuteInheritedPipeFixture$")
	child.Env = []string{"GORACE=atexit_sleep_ms=0", "RELAY_NATIVEPROVIDER_PIPE_FIXTURE=descendant", "RELAY_NATIVEPROVIDER_PIPE_DIRECTORY=" + dir}
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	if err = child.Start(); err != nil {
		t.Fatal(err)
	}
	if role == "parent-exit" {
		deadline := time.Now().Add(time.Second)
		for {
			if _, err := os.Stat(filepath.Join(dir, "descendant-ready")); err == nil {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("descendant did not retain stdout")
			}
			time.Sleep(time.Millisecond)
		}
	}
	if err = child.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestExecuteTimeoutBoundsInheritedOutputPipe(t *testing.T) {
	for _, role := range []string{"parent", "parent-exit"} {
		t.Run(role, func(t *testing.T) {
			dir := t.TempDir()
			executable, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			// Cover both timeout and normal direct-child exit while a descendant
			// retains the output pipe. The descendant has a fixed natural lifetime.
			timeout := 250 * time.Millisecond
			if role == "parent-exit" {
				timeout = 0
			}
			started := time.Now()
			out, err := Execute(Command{
				Args:    []string{executable, "-test.run=^TestExecuteInheritedPipeFixture$"},
				Env:     []string{"GORACE=atexit_sleep_ms=0", "RELAY_NATIVEPROVIDER_PIPE_FIXTURE=" + role, "RELAY_NATIVEPROVIDER_PIPE_DIRECTORY=" + dir},
				Timeout: timeout,
			})
			elapsed := time.Since(started)
			t.Logf("role=%s elapsed=%s error=%v", role, elapsed, err)
			if role == "parent-exit" && !errors.Is(err, exec.ErrWaitDelay) {
				t.Fatalf("direct child exit did not reach bounded pipe drain: %v", err)
			}
			if err == nil || !bytes.Contains(out, []byte("private-descendant-ready")) {
				t.Fatalf("fixture did not reach timeout with an inherited pipe: %v %q", err, out)
			}
			// Allow the fixture to finish naturally before TempDir cleanup. No numeric process
			// group is retained or signalled after its direct leader has been reaped.
			deadline := time.Now().Add(5 * time.Second)
			for {
				if _, statErr := os.Stat(filepath.Join(dir, "descendant-completed")); statErr == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("private pipe fixture did not finish naturally")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if elapsed >= time.Second {
				t.Fatalf("inherited output pipe extended command timeout: %s", elapsed)
			}
			if bytes.Contains(out, []byte("private-descendant-completed")) {
				t.Fatal("Execute waited for descendant output after cancellation or direct exit")
			}
		})
	}
}

func TestCLIHelp(t *testing.T) {
	for _, kind := range []string{"build", "install", "repair"} {
		for _, flag := range []string{"--help", "-h"} {
			var b bytes.Buffer
			if CLI(kind, []string{flag}, &b, &b) != 0 || b.Len() == 0 {
				t.Fatal("help must print usage and exit zero")
			}
		}
	}
}

func TestPrivateModesWithUmask(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "source")
	put(t, src, []byte("fixture"), 0700)
	prior := syscall.Umask(0777)
	defer syscall.Umask(prior)
	dst := filepath.Join(dir, "copy")
	if e := copyPrivate(src, dst); e != nil {
		t.Fatal(e)
	}
	meta := filepath.Join(dir, "metadata")
	if e := writePrivate(meta, []byte("fixture")); e != nil {
		t.Fatal(e)
	}
	for p, want := range map[string]os.FileMode{dst: 0700, meta: 0600} {
		s, e := os.Stat(p)
		if e != nil || s.Mode().Perm() != want {
			t.Fatal("explicit private modes lost to umask")
		}
	}
}
