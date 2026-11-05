package helperbundle

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// A fully hashed archive can still be malformed; reject all entries before
// replacing even the first currently installed payload.
func replaceArchiveEntry(t *testing.T, original []byte, name string, kind byte) []byte {
	t.Helper()
	reader := tar.NewReader(bytes.NewReader(original))
	var out bytes.Buffer
	writer := tar.NewWriter(&out)
	for {
		h, e := reader.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		data, e := io.ReadAll(reader)
		if e != nil {
			t.Fatal(e)
		}
		data = bytes.ReplaceAll(data, []byte("fixture"), []byte("changed"))
		if h.Name == name {
			h.Typeflag = kind
			h.Size = 0
			data = nil
			if kind == tar.TypeSymlink {
				h.Linkname = "relayd-linux-amd64"
			}
			if kind == tar.TypeReg {
				h.Size = 0
			}
		} else {
			h.Size = int64(len(data))
		}
		if e = writer.WriteHeader(h); e != nil {
			t.Fatal(e)
		}
		if _, e = writer.Write(data); e != nil {
			t.Fatal(e)
		}
	}
	if e := writer.Close(); e != nil {
		t.Fatal(e)
	}
	return out.Bytes()
}
func TestMalformedArchivePreservesEveryInstalledByte(t *testing.T) {
	for _, name := range []string{Names[len(Names)-1] + "-linux-amd64", "relay-release.json"} {
		for _, kind := range []byte{tar.TypeDir, tar.TypeSymlink, tar.TypeReg} {
			t.Run(name+"-"+string(kind), func(t *testing.T) {
				home := t.TempDir()
				full := archive(t, "")
				if out, e := install(t, home, full, false); e != nil {
					t.Fatalf("setup %v %s", e, out)
				}
				payload := filepath.Join(home, ".local/share/relay/bin")
				before := fileBytes(t, payload)
				manifest := filepath.Join(home, ".local/share/relay/relay-release.json")
				prior, e := os.ReadFile(manifest)
				if e != nil {
					t.Fatal(e)
				}
				if out, e := install(t, home, replaceArchiveEntry(t, full, name, kind), false); e == nil {
					t.Fatalf("accepted malformed archive %s %c: %s", name, kind, out)
				}
				if after := fileBytes(t, payload); !reflect.DeepEqual(before, after) {
					t.Fatal("malformed archive replaced installed payload before rejection")
				}
				after, e := os.ReadFile(manifest)
				if e != nil || !bytes.Equal(prior, after) {
					t.Fatal("malformed archive replaced release manifest")
				}
				if _, e := os.Lstat(filepath.Join(home, ".local/share/relay/install.lock")); !os.IsNotExist(e) {
					t.Fatal("malformed archive retained install lock")
				}
			})
		}
	}
}
func TestNativeCommandInstallationPreservesForeignSymlinks(t *testing.T) {
	for _, dangling := range []bool{false, true} {
		t.Run(map[bool]string{false: "existing-target", true: "dangling"}[dangling], func(t *testing.T) {
			home := t.TempDir()
			path := filepath.Join(home, ".local/bin", Names[0])
			os.MkdirAll(filepath.Dir(path), 0700)
			target := filepath.Join(home, "user-command")
			before := []byte("user-owned bytes")
			if !dangling {
				if e := os.WriteFile(target, before, 0700); e != nil {
					t.Fatal(e)
				}
			}
			if e := os.Symlink(target, path); e != nil {
				t.Fatal(e)
			}
			if out, e := install(t, home, archive(t, ""), false); e != nil {
				t.Fatalf("install %v %s", e, out)
			}
			// Join this fixture writer before TempDir cleanup; retain the existing five-second bound.
			waitForDetachedInstall(t, home)
			got, e := os.Readlink(path)
			if e != nil || got != target {
				t.Fatal("installer replaced foreign user symlink")
			}
			if dangling {
				if _, e := os.Lstat(target); !os.IsNotExist(e) {
					t.Fatal("installer created dangling user target")
				}
			} else {
				data, e := os.ReadFile(target)
				if e != nil || !bytes.Equal(data, before) {
					t.Fatal("installer changed foreign symlink target")
				}
			}
		})
	}
}

func TestManagedShimRoutesSelectedArchitectureAndRejectsUnknownInvocation(t *testing.T) {
	home := t.TempDir()
	if out, e := install(t, home, archive(t, ""), false); e != nil {
		t.Fatalf("install %v %s", e, out)
	}
	env := append(os.Environ(), "HOME="+home, "PATH="+filepath.Join(home, "tools")+":"+os.Getenv("PATH"))
	uname := filepath.Join(home, "tools/uname")
	tool := filepath.Join(home, ".local/bin", Names[0])
	arm := filepath.Join(home, ".local/share/relay/bin", Names[0]+"-linux-arm64")
	if e := os.WriteFile(arm, []byte("#!/bin/sh\nprintf 'arm64 %s\\n' \"$*\"\n"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(uname, []byte("#!/bin/sh\nprintf 'arm64\\n'\n"), 0700); e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(tool, "fixture")
	cmd.Env = env
	out, e := cmd.CombinedOutput()
	if e != nil || string(out) != "arm64 fixture\n" {
		t.Fatalf("native shim selected wrong architecture: %v %s", e, out)
	}
	cmd = exec.Command(filepath.Join(home, ".local/share/relay/shims/relay-native-tool"))
	cmd.Env = env
	out, e = cmd.CombinedOutput()
	if e == nil || !strings.Contains(string(out), "Unknown Relay tool") {
		t.Fatalf("unknown direct shim invocation accepted: %v %s", e, out)
	}
	if e := os.WriteFile(uname, []byte("#!/bin/sh\nprintf 'unsupported\\n'\n"), 0700); e != nil {
		t.Fatal(e)
	}
	cmd = exec.Command(tool)
	cmd.Env = env
	out, e = cmd.CombinedOutput()
	if e == nil || !strings.Contains(string(out), "unsupported architecture") {
		t.Fatalf("unknown architecture accepted: %v %s", e, out)
	}
}
func TestInstallRetainsOriginalProcessDeadline(t *testing.T) {
	before := time.Now()
	ctx, cancel := installContext()
	defer cancel()
	deadline, ok := ctx.Deadline()
	after := time.Now()
	if !ok || deadline.Before(before.Add(15*time.Second)) || deadline.After(after.Add(15*time.Second)) {
		t.Fatal("original 15-second install deadline changed")
	}
}

func TestManagedShimNeverFollowsDirectoryOrFileSymlink(t *testing.T) {
	type hostMove struct{ host, mover string }
	variants := []hostMove{{"", "/bin/mv"}}
	if gnu, err := exec.LookPath("gmv"); err == nil {
		variants = append(variants, hostMove{"Linux", gnu})
	}
	for _, variant := range variants {
		for _, directory := range []bool{false, true} {
			name := filepath.Base(variant.mover) + "-" + map[bool]string{false: "file", true: "directory"}[directory]
			t.Run(name, func(t *testing.T) {
				home := t.TempDir()
				shim := filepath.Join(home, ".local/share/relay/shims/relay-native-tool")
				outside := filepath.Join(home, "user-owned")
				original := []byte("user bytes")
				if e := os.MkdirAll(filepath.Dir(shim), 0700); e != nil {
					t.Fatal(e)
				}
				if directory {
					if e := os.Mkdir(outside, 0700); e != nil {
						t.Fatal(e)
					}
				} else {
					if e := os.WriteFile(outside, original, 0600); e != nil {
						t.Fatal(e)
					}
				}
				if e := os.Symlink(outside, shim); e != nil {
					t.Fatal(e)
				}
				if out, e := installWithHost(t, home, archive(t, ""), false, variant.host, variant.mover); e != nil {
					t.Fatalf("install: %v %s", e, out)
				}
				waitForDetachedInstall(t, home)
				if directory {
					entries, e := os.ReadDir(outside)
					if e != nil || len(entries) != 0 {
						t.Fatalf("managed shim followed directory symlink: %v %v", entries, e)
					}
				} else {
					data, e := os.ReadFile(outside)
					if e != nil || !bytes.Equal(data, original) {
						t.Fatal("managed shim changed file symlink target", e)
					}
				}
				st, e := os.Lstat(shim)
				if e != nil || !st.Mode().IsRegular() || st.Mode().Perm() != 0700 {
					t.Fatal("managed shim is not private executable regular file", e)
				}
				entries, e := os.ReadDir(filepath.Dir(shim))
				if e != nil || len(entries) != 1 || entries[0].Name() != "relay-native-tool" {
					t.Fatalf("temporary launcher leaked: %v %v", entries, e)
				}
			})
		}
	}
}
func TestManagedShimPreflightPreservesPayloads(t *testing.T) {
	for _, kind := range []string{"directory", "unsupported-host"} {
		t.Run(kind, func(t *testing.T) {
			home := t.TempDir()
			full := archive(t, "")
			if out, e := install(t, home, full, false); e != nil {
				t.Fatalf("setup %v %s", e, out)
			}
			waitForDetachedInstall(t, home)
			payload := filepath.Join(home, ".local/share/relay/bin")
			before := fileBytes(t, payload)
			manifest := filepath.Join(home, ".local/share/relay/relay-release.json")
			prior, e := os.ReadFile(manifest)
			if e != nil {
				t.Fatal(e)
			}
			shim := filepath.Join(home, ".local/share/relay/shims/relay-native-tool")
			host := ""
			if kind == "directory" {
				if e := os.Remove(shim); e != nil {
					t.Fatal(e)
				}
				if e := os.Mkdir(shim, 0700); e != nil {
					t.Fatal(e)
				}
			} else {
				host = "unsupported"
			}
			changed := replaceArchiveEntry(t, full, "not-an-entry", tar.TypeReg)
			if out, e := installWithHost(t, home, changed, false, host, ""); e == nil {
				t.Fatalf("preflight accepted %s: %s", kind, out)
			}
			if !reflect.DeepEqual(before, fileBytes(t, payload)) {
				t.Fatal("host/path preflight replaced installed payloads")
			}
			after, e := os.ReadFile(manifest)
			if e != nil || !bytes.Equal(prior, after) {
				t.Fatal("host/path preflight changed manifest")
			}
			if kind == "directory" {
				entries, e := os.ReadDir(shim)
				if e != nil || len(entries) != 0 {
					t.Fatal("installer wrote into owned directory", e)
				}
			}
		})
	}
}
func TestManagedShimFailedRenameIsNeverRetried(t *testing.T) {
	home := t.TempDir()
	tools := filepath.Join(home, "tools")
	if e := os.MkdirAll(tools, 0700); e != nil {
		t.Fatal(e)
	}
	wrapper := `#!/bin/sh
for arg do last="$arg"; done
case "$last" in */shims/relay-native-tool) printf x >> "$HOME/rename-calls"; exit 19 ;; esac
exec /bin/mv "$@"
`
	if e := os.WriteFile(filepath.Join(tools, "mv"), []byte(wrapper), 0700); e != nil {
		t.Fatal(e)
	}
	if out, e := install(t, home, archive(t, ""), false); e == nil {
		t.Fatalf("failed rename accepted: %s", out)
	}
	calls, e := os.ReadFile(filepath.Join(home, "rename-calls"))
	if e != nil || string(calls) != "x" {
		t.Fatalf("ambiguous rename retried: %q %v", calls, e)
	}
	entries, e := os.ReadDir(filepath.Join(home, ".local/share/relay/shims"))
	if e != nil || len(entries) != 0 {
		t.Fatalf("failed rename leaked temporary launcher: %v %v", entries, e)
	}
}

// Keep the original five-second receipt bound while joining the fixture's
// detached file writer before TempDir removes its private home.
func waitForDetachedInstall(t *testing.T, home string) {
	t.Helper()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if data, err := os.ReadFile(filepath.Join(home, ".local/share/relay/upgrade-workers-last.json")); err == nil && len(data) > 0 {
			return
		}
		select {
		case <-timer.C:
			t.Fatal("detached fixture receipt missing before cleanup")
		case <-tick.C:
		}
	}
}
