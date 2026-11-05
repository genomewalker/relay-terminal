package helperbundle

// Process successors of the three original helper-installation tests. No live
// installation, worker, provider, credential or SSH connection is used.
import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

func installSource(data []byte) (string, error) {
	if len(data) > 1<<20 {
		return "", errors.New("source limit")
	}
	start := bytes.Index(data, []byte("    private static func installScript("))
	if start < 0 {
		return "", errors.New("function missing")
	}
	rest := data[start:]
	begin := bytes.Index(rest, []byte("#\"\"\"\n"))
	if begin < 0 {
		return "", errors.New("opener missing")
	}
	rest = rest[begin+5:]
	end := bytes.Index(rest, []byte("\n\"\"\"#"))
	if end < 0 {
		return "", errors.New("truncated script")
	}
	script := string(rest[:end])
	if !strings.HasPrefix(script, "set -eu\numask 077\n") {
		return "", errors.New("unexpected install policy")
	}
	return script, nil
}
func currentSource(t *testing.T) []byte {
	t.Helper()
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "Sources", "Relay", "RelaydManagement.swift"))
	if err != nil {
		t.Fatal(err)
	}
	return source
}
func TestNativeHelperCatalogueMatchesSwiftAndEveryMaintainedCommand(t *testing.T) {
	source := string(currentSource(t))
	a := strings.Index(source, "static let nativeHelperNames: [String] = [")
	if a < 0 {
		t.Fatal("Swift helper catalogue missing")
	}
	part := source[a+len("static let nativeHelperNames: [String] = ["):]
	end := strings.Index(part, "]")
	if end < 0 {
		t.Fatal("truncated catalogue")
	}
	matches := regexp.MustCompile(`"([a-z0-9-]+)"`).FindAllStringSubmatch(part[:end], -1)
	var got []string
	for _, m := range matches {
		got = append(got, m[1])
	}
	if !reflect.DeepEqual(got, Names) {
		t.Fatalf("Go/Swift helper catalogue differs: %v %v", Names, got)
	}
	seen := map[string]bool{}
	for _, name := range Names {
		if seen[name] || !regexp.MustCompile(`^relay-[a-z0-9-]+$`).MatchString(name) {
			t.Fatal("invalid/duplicate helper", name)
		}
		seen[name] = true
		if st, err := os.Stat(filepath.Join("..", "..", "cmd", name, "main.go")); err != nil || !st.Mode().IsRegular() {
			t.Fatal("maintained helper source missing", name, err)
		}
	}
}
func archive(t *testing.T, missing string) []byte {
	t.Helper()
	var out bytes.Buffer
	writer := tar.NewWriter(&out)
	names := append([]string{"relayd", "relay-mcp", "relay-peer-link"}, Names...)
	for _, name := range names {
		if name == missing {
			continue
		}
		data := []byte("#!/bin/sh\nprintf 'fixture %s\\n' \"$*\"\n")
		if err := writer.WriteHeader(&tar.Header{Name: name + "-linux-amd64", Mode: 0700, Size: int64(len(data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	data := []byte("{\"build_number\":\"fixture\"}\n")
	if err := writer.WriteHeader(&tar.Header{Name: "relay-release.json", Mode: 0600, Size: int64(len(data))}); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}
func install(t *testing.T, home string, data []byte, badHash bool) ([]byte, error) {
	return installWithHost(t, home, data, badHash, "", "")
}
func installWithHost(t *testing.T, home string, data []byte, badHash bool, host, mover string) ([]byte, error) {
	t.Helper()
	previousReceipt, receiptError := os.Lstat(filepath.Join(home, ".local/share/relay/upgrade-workers-last.json"))
	if receiptError != nil && !os.IsNotExist(receiptError) {
		t.Fatal(receiptError)
	}
	script, err := installSource(currentSource(t))
	if err != nil {
		t.Fatal(err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(data))
	if badHash {
		digest = strings.Repeat("0", 64)
	}
	script = strings.NewReplacer(`\#(architecture)`, "amd64", `\#(expectedHash)`, digest, `\#(nativeHelperNames.joined(separator: " "))`, strings.Join(Names, " "), `\#(nativeHelperNames.joined(separator: "|"))`, strings.Join(Names, "|")).Replace(script)
	if strings.Contains(script, `\#(`) {
		t.Fatal("unresolved Swift interpolation")
	}
	tools := filepath.Join(home, "tools")
	if err := os.MkdirAll(tools, 0700); err != nil {
		t.Fatal(err)
	}
	hostCommand := "exec /usr/bin/uname -s"
	if host != "" {
		hostCommand = fmt.Sprintf("printf '%%s\\n' %q", host)
	}
	if err := os.WriteFile(filepath.Join(tools, ".uname-new"), []byte("#!/bin/sh\ncase \"$1\" in -s) "+hostCommand+" ;; *) printf 'x86_64\\n' ;; esac\n"), 0700); err != nil {
		t.Fatal(err)
	}
	// Linux refuses truncating an executable still in use by a detached fixture.
	// Publish a new inode, leaving the running helper and all fixture assertions intact.
	if err := os.Rename(filepath.Join(tools, ".uname-new"), filepath.Join(tools, "uname")); err != nil {
		t.Fatal(err)
	}
	if mover != "" {
		if err := os.Symlink(mover, filepath.Join(tools, "mv")); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := installContext()
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", script)
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+tools+":"+os.Getenv("PATH"))
	cmd.Stdin = bytes.NewReader(data)
	output, runError := cmd.CombinedOutput()
	if runError == nil {
		waitForInstallReceiptGeneration(t, home, previousReceipt)
	}
	return output, runError
}
func fileBytes(t *testing.T, dir string) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			out[e.Name()] = string(data)
		}
	}
	return out
}
func TestCompleteReleaseInstallsOriginalAliasesAndNativeCommands(t *testing.T) {
	home := t.TempDir()
	if out, err := install(t, home, archive(t, ""), false); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	payload := filepath.Join(home, ".local/share/relay/bin")
	for alias, target := range map[string]string{"relayd-communication": "relayd-linux-amd64", "relayd-verified": "relayd-linux-amd64", "relay-mcp-communication": "relay-mcp-linux-amd64", "relay-mcp": "relay-mcp-linux-amd64", "relay-peer-link": "relay-peer-link-linux-amd64"} {
		path := filepath.Join(payload, alias)
		resolved, err := filepath.EvalSymlinks(path)
		expectedTarget, targetErr := filepath.EvalSymlinks(filepath.Join(payload, target))
		info, e := os.Stat(path)
		if err != nil || targetErr != nil || resolved != expectedTarget || e != nil || info.Mode().Perm()&0111 == 0 || unix.Access(path, unix.X_OK) != nil {
			t.Fatal("installed alias changed", alias, err, e)
		}
	}
	if info, err := os.Stat(filepath.Join(home, ".local/share/relay/relay-release.json")); err != nil || !info.Mode().IsRegular() {
		t.Fatal("release manifest missing")
	}
	for _, name := range Names {
		cmd := exec.Command(filepath.Join(home, ".local/bin", name), "private-fixture")
		cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+filepath.Join(home, "tools")+":"+os.Getenv("PATH"))
		out, err := cmd.CombinedOutput()
		if err != nil || string(out) != "fixture private-fixture\n" {
			t.Fatalf("native tool unavailable: %s %v %s", name, err, out)
		}
	}
}
func TestInstallMovesDisposableLiveWorkersAndKeepsPrivateReceipt(t *testing.T) {
	home := t.TempDir()
	if out, err := install(t, home, archive(t, ""), false); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	path := filepath.Join(home, ".local/share/relay/upgrade-workers-last.json")
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			if string(data) != "fixture upgrade-workers\n" {
				t.Fatal("worker upgrade receipt differs")
			}
			st, err := os.Stat(path)
			if err != nil || st.Mode().Perm() != 0600 {
				t.Fatal("worker receipt not private")
			}
			return
		}
		select {
		case <-deadline.C:
			t.Fatal("worker receipt missing")
		case <-tick.C:
		}
	}
}
func TestRejectedUploadAndEveryMissingNativePayloadPreserveInstalledBytes(t *testing.T) {
	home := t.TempDir()
	full := archive(t, "")
	if out, err := install(t, home, full, false); err != nil {
		t.Fatalf("initial: %v %s", err, out)
	}
	payload := filepath.Join(home, ".local/share/relay/bin")
	before := fileBytes(t, payload)
	for _, missing := range append([]string{"bad-hash", "relayd", "relay-mcp", "relay-peer-link"}, Names...) {
		data := full
		if missing != "bad-hash" {
			data = bytes.ReplaceAll(archive(t, missing), []byte("fixture"), []byte("changed"))
		}
		if out, err := install(t, home, data, missing == "bad-hash"); err == nil {
			t.Fatalf("accepted invalid upload %s: %s", missing, out)
		}
		if after := fileBytes(t, payload); !reflect.DeepEqual(before, after) {
			t.Fatalf("rejected upload changed installed bytes: %s", missing)
		}
		if _, err := os.Lstat(filepath.Join(home, ".local/share/relay/install.lock")); !os.IsNotExist(err) {
			t.Fatal("rejected install kept lock", missing, err)
		}
	}
}
func TestNativeCommandInstallationPreservesUserOwnedCommands(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, ".local/bin", Names[0])
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	before := []byte("#!/bin/sh\necho user-owned\n")
	if err := os.WriteFile(path, before, 0700); err != nil {
		t.Fatal(err)
	}
	if out, err := install(t, home, archive(t, ""), false); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("native install replaced user command")
	}
}
func FuzzInstallationSourceBoundary(f *testing.F) {
	f.Add([]byte(strings.Repeat("x", 1<<20) + "    private static func installScript(x) -> String {\n#\"\"\"\nset -eu\numask 077\nhello\n\"\"\"#"))
	f.Add([]byte("    private static func installScript(x) -> String {\n#\"\"\"\nset -eu\numask 077\nhello\n\"\"\"#"))
	f.Add([]byte("#\"\"\"\n"))
	f.Fuzz(func(t *testing.T, data []byte) {
		script, err := installSource(data)
		if err == nil {
			if len(data) > 1<<20 || !strings.HasPrefix(script, "set -eu\numask 077\n") || !bytes.Contains(data, []byte(script)) {
				t.Fatal("install source boundary changed")
			}
			if !bytes.Contains(data, []byte("\n\"\"\"#")) {
				t.Fatal("accepted truncated installation source")
			}
		}
	})
}

func TestNativeCommandEveryTwoActorOwnershipInterleaving(t *testing.T) {
	schedules := [][]int{{0, 1, 2, 3}, {0, 2, 1, 3}, {0, 2, 3, 1}, {2, 0, 1, 3}, {2, 0, 3, 1}, {2, 3, 0, 1}}
	transitions := 0
	for _, schedule := range schedules {
		home := t.TempDir()
		path := filepath.Join(home, ".local/bin", Names[0])
		state := "absent"
		for _, op := range schedule {
			switch op {
			case 0, 1:
				if out, err := install(t, home, archive(t, ""), false); err != nil {
					t.Fatalf("ownership schedule %v install: %v %s", schedule, err, out)
				}
				if state != "user" {
					state = "managed"
				}
			case 2:
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte("user-owned-fixture"), 0700); err != nil {
					t.Fatal(err)
				}
				state = "user"
			case 3:
				if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
					t.Fatal(err)
				}
				state = "absent"
			}
			info, err := os.Lstat(path)
			switch state {
			case "absent":
				if !os.IsNotExist(err) {
					t.Fatalf("schedule %v: removed command resurrected", schedule)
				}
			case "managed":
				if err != nil || info.Mode()&os.ModeSymlink == 0 {
					t.Fatalf("schedule %v: managed command missing", schedule)
				}
				target, e := os.Readlink(path)
				if e != nil || target != filepath.Join(home, ".local/share/relay/shims/relay-native-tool") {
					t.Fatal("managed command escaped shim root")
				}
			case "user":
				data, e := os.ReadFile(path)
				if err != nil || info.Mode()&os.ModeSymlink != 0 || e != nil || string(data) != "user-owned-fixture" {
					t.Fatalf("schedule %v: user ownership overwritten", schedule)
				}
			}
			transitions++
		}
	}
	if transitions != 24 {
		t.Fatal("ownership bound changed")
	}
	t.Log("real install: six order-preserving two-actor schedules; depth4; 24 post-transition ownership checks")
}

func TestManagedShimReplacementDoesNotFollowExistingSymlink(t *testing.T) {
	home := t.TempDir()
	shim := filepath.Join(home, ".local/share/relay/shims/relay-native-tool")
	if err := os.MkdirAll(filepath.Dir(shim), 0700); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(home, "keep-user-file")
	before := []byte("must remain byte-identical")
	if err := os.WriteFile(outside, before, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, shim); err != nil {
		t.Fatal(err)
	}
	if out, err := install(t, home, archive(t, ""), false); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	after, err := os.ReadFile(outside)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("managed shim followed existing symlink")
	}
	info, err := os.Lstat(shim)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0700 {
		t.Fatal("managed shim was not atomically replaced with a private executable")
	}
}

func installContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 15*time.Second)
}
