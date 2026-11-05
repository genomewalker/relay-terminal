package pluginverify

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/relay-terminal/relayd/internal/daemon"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if filepath.Base(os.Args[0]) == "ssh" {
		want := []string{"-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "fixture.invalid"}
		if len(os.Args) != 8 || !reflect.DeepEqual(os.Args[1:7], want) {
			fmt.Fprintln(os.Stderr, "fake SSH argv mismatch")
			os.Exit(33)
		}
		os.WriteFile(os.Getenv("PLUGIN_SSH_MARKER"), []byte("fake SSH only\n"), 0600)
		c := exec.Command("/bin/sh", "-c", os.Args[7])
		c.Stdin = os.Stdin
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if e := c.Run(); e != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	if len(os.Args) == 2 && os.Args[1] == "plugin" {
		var q daemon.PluginRequest
		if json.NewDecoder(os.Stdin).Decode(&q) != nil {
			os.Exit(2)
		}
		r, e := daemon.InspectPlugin(q)
		fault := os.Getenv("PLUGIN_FAULT")
		if e != nil {
			if fault == "outside" && (q.Path == "../outside" || q.Path == "/etc/passwd") {
				json.NewEncoder(os.Stdout).Encode(map[string]any{})
				os.Exit(0)
			}
			os.Exit(1)
		}
		if q.Operation == "artifacts" && q.Path == "" && fault == "listing" {
			r.Entries = []string{"table.csv"}
		}
		if q.Path == "table.csv" && q.Operation == "artifacts" {
			switch fault {
			case "fullhash":
				r.SHA256 = "wrong"
			case "path":
				r.Text = "wrong.csv"
			case "base64":
				s := "!bad!"
				r.Content = &s
			case "missingcontent":
				r.Content = nil
			}
		}
		if q.Path == "empty.txt" && q.Transfer == nil && fault == "empty" {
			s := base64.StdEncoding.EncodeToString([]byte("x"))
			r.Content = &s
			r.SHA256 = digest([]byte("x"))
		}
		if q.Operation == "projectActions" && fault == "pnpm" {
			r.Entries = nil
		}
		if q.Operation == "gitReview" {
			if q.Path == "" && fault == "git" {
				r.Text = "wrong"
			}
			if q.Path == "table.csv" && fault == "diff" {
				r.Text = "table.csv"
			}
		}
		if q.Transfer != nil {
			switch q.Transfer.Mode {
			case "stat":
				switch fault {
				case "metadata":
					r.Transfer = nil
				case "negative":
					r.Transfer.Size = -1
				case "oversize":
					r.Transfer.Size = 1 << 40
				case "version":
					r.Transfer.Version = ""
				}
			case "chunk":
				switch fault {
				case "chunkzero":
					s := ""
					r.Content = &s
					r.SHA256 = digest(nil)
				case "chunklarge":
					data := make([]byte, chunkLimit+1)
					s := base64.StdEncoding.EncodeToString(data)
					r.Content = &s
					r.SHA256 = digest(data)
				case "chunkhash":
					r.SHA256 = "wrong"
				case "overrun":
					data := []byte("too much for the declared file contents")
					s := base64.StdEncoding.EncodeToString(data)
					r.Content = &s
					r.SHA256 = digest(data)
				}
			case "verify":
				if fault == "finalhash" {
					r.Transfer.SHA256 = "wrong"
				}
			}
		}
		json.NewEncoder(os.Stdout).Encode(r)
		os.Exit(0)
	}
	os.Exit(m.Run())
}
func fixture(t *testing.T) Options {
	t.Helper()
	dir, e := os.MkdirTemp("/tmp", "plugin smoke '")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	root := filepath.Join(dir, "fixture")
	bin := filepath.Join(dir, "bin")
	os.Mkdir(root, 0700)
	os.Mkdir(bin, 0700)
	for n, s := range map[string]string{"package.json": "{}\n", "pnpm-lock.yaml": "lockfileVersion: '9.0'\n", "table.csv": "x,y\n1,2\n", "empty.txt": ""} {
		if e := os.WriteFile(filepath.Join(root, n), []byte(s), 0600); e != nil {
			t.Fatal(e)
		}
	}
	// Private fake Git: fixed staged bytes, no real repository or git command.
	fakeGit := `#!/bin/sh
case " $* " in
 *" rev-parse "*) printf '%s\n%s/.git\n' "$PWD" "$PWD";;
 *" --name-only "*) case " $* " in *" --cached "*) printf 'table.csv\000';; esac;;
 *" diff "*) case " $* " in *" --cached "*) printf 'diff --git a/table.csv b/table.csv\n+1,2\n';; esac;;
 *) exit 34;;
esac
`
	if e := os.WriteFile(filepath.Join(bin, "git"), []byte(fakeGit), 0700); e != nil {
		t.Fatal(e)
	}
	self, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	data, e := os.ReadFile(self)
	if e != nil {
		t.Fatal(e)
	}
	helper := filepath.Join(dir, "staged helper '")
	os.WriteFile(helper, data, 0700)
	os.WriteFile(filepath.Join(bin, "ssh"), data, 0700)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("PLUGIN_FAULT", "")
	t.Setenv("GORACE", "atexit_sleep_ms=0")
	t.Setenv("PLUGIN_SSH_MARKER", filepath.Join(dir, "ssh-marker"))
	return Options{Helper: helper, Fixture: root}
}
func TestOriginalAssertions(t *testing.T) {
	o := fixture(t)
	r, e := Run(context.Background(), o)
	if e != nil || r != (Summary{"local", 10, "passed"}) {
		t.Fatalf("original smoke: %+v %v", r, e)
	}
	cases := map[string]string{"listing": "artifact listing", "fullhash": "full-file SHA256", "path": "file path identity", "empty": "empty-file content", "pnpm": "pnpm detection", "git": "Git attribution", "diff": "staged diff", "outside": "outside path must be rejected", "chunkzero": "chunk size", "chunklarge": "chunk size", "chunkhash": "chunk SHA256", "finalhash": "final transfer SHA256", "base64": "invalid base64", "missingcontent": "missing base64", "metadata": "invalid transfer metadata", "negative": "invalid transfer metadata", "oversize": "invalid transfer metadata", "version": "invalid transfer metadata", "overrun": "chunk exceeds declared size"}
	for fault, want := range cases {
		t.Run(fault, func(t *testing.T) {
			t.Setenv("PLUGIN_FAULT", fault)
			defer func() {
				if recovered := recover(); recovered != nil {
					t.Fatalf("smoke must reject malformed helper response without panic: %v", recovered)
				}
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, e := Run(ctx, o)
			if e == nil || !strings.Contains(e.Error(), want) {
				t.Fatalf("fault %s accepted or wrong refusal: %v, want %s", fault, e, want)
			}
		})
	}
}
func TestFakeSSH(t *testing.T) {
	o := fixture(t)
	o.SSH = "fixture.invalid"
	r, e := Run(context.Background(), o)
	if e != nil || r.Target != o.SSH {
		t.Fatalf("fake SSH smoke: %+v %v", r, e)
	}
	data, e := os.ReadFile(os.Getenv("PLUGIN_SSH_MARKER"))
	if e != nil || string(data) != "fake SSH only\n" {
		t.Fatalf("SSH fixture not used: %s %v", data, e)
	}
}
func TestNativeStagedHelper(t *testing.T) {
	o := fixture(t)
	helper := filepath.Join(filepath.Dir(o.Fixture), "actual-relayd")
	c := exec.Command("go", "build", "-buildvcs=false", "-o", helper, "../../cmd/relayd")
	if b, e := c.CombinedOutput(); e != nil {
		t.Fatalf("build staged Go helper: %v: %s", e, b)
	}
	o.Helper = helper
	r, e := Run(context.Background(), o)
	if e != nil || r.Checks != 10 {
		t.Fatalf("actual staged Go helper: %+v %v", r, e)
	}
}
func TestPathAndArgumentRefusal(t *testing.T) {
	for _, args := range [][]string{{"/tmp/h", "/tmp/f"}, {"/tmp/h", "/tmp/f", "--ssh", "fixture.invalid"}, {"--ssh", "fixture.invalid", "/tmp/h", "/tmp/f"}} {
		if _, e := ParseArgs(args); e != nil {
			t.Fatal(e)
		}
	}
	for _, args := range [][]string{{}, {"/usr/bin/helper", "/tmp/f"}, {"/else/../tmp/helper", "/tmp/f"}, {"/tmp/h", "/real/project"}, {"/tmp/../real/helper", "/tmp/f"}, {"/tmp/h", "/tmp/../real/project"}, {"/tmp/h", "/tmp/f", "--ssh"}, {"/tmp/h", "/tmp/f", "--ssh", "-option"}, {"/tmp/h", "/tmp/f", "--ssh", "bad\nhost"}, {"/tmp/h", "/tmp/f", "--unknown"}} {
		if _, e := ParseArgs(args); e == nil {
			t.Fatalf("unsafe args accepted: %q", args)
		}
	}
	_, e := Run(context.Background(), Options{Helper: "/usr/bin/helper", Fixture: "/real/project"})
	if e == nil {
		t.Fatal("programmatic unsafe paths accepted")
	}
}
func TestTimeoutAndExitDistinction(t *testing.T) {
	o := fixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, e := call(ctx, o, request{Operation: "artifacts", Root: o.Fixture})
	if !errors.Is(e, context.Canceled) {
		t.Fatalf("context cancellation: %v", e)
	}
	if requestTimeout != 15*time.Second {
		t.Fatal("original request timeout changed")
	}
	_, e = call(context.Background(), o, request{Operation: "transfers", Root: o.Fixture, Path: "../outside"})
	var exit *exec.ExitError
	if !errors.As(e, &exit) {
		t.Fatalf("actual process rejection missing: %v", e)
	}
}
func TestBoundedResponseDecoder(t *testing.T) {
	for _, s := range []string{"null", "[]", "{} {}", "{", "\xff", "{\"transfer\":{\"size\":1.5}}"} {
		if _, e := decode([]byte(s)); e == nil {
			t.Fatalf("invalid response accepted %q", s)
		}
	}
	if _, e := decode([]byte(`{"text":"okay","entries":[]}`)); e != nil {
		t.Fatal(e)
	}
	if _, e := decode([]byte("{}" + strings.Repeat(" ", responseLimit))); e == nil {
		t.Fatal("oversized response accepted")
	}
	b := &cappedBuffer{limit: 4}
	if n, e := b.Write([]byte("1234")); n != 4 || e != nil {
		t.Fatal(n, e)
	}
	if _, e := b.Write([]byte("5")); e == nil || b.Len() > 4 {
		t.Fatal("output cap exceeded")
	}
}
func TestBase64Validation(t *testing.T) {
	for _, s := range []string{"!bad!", "YQ==\n", "YQ"} {
		if _, e := content(response{Content: &s}); e == nil {
			t.Fatalf("invalid base64 accepted %q", s)
		}
	}
	s := ""
	if b, e := content(response{Content: &s}); e != nil || len(b) != 0 {
		t.Fatal("empty base64 rejected")
	}
}
func FuzzPluginJSON(f *testing.F) {
	for _, s := range []string{`{"text":"x","content":"","transfer":{"size":0,"version":"v"}}`, `null`, `{} {}`, `{"content":"!"}`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<20 {
			return
		}
		r, e := decode(data)
		if e == nil {
			if !json.Valid(data) {
				t.Fatal("accepted malformed JSON")
			}
			encoded, e := json.Marshal(r)
			if e != nil {
				t.Fatal(e)
			}
			again, e := decode(encoded)
			if e != nil || !reflect.DeepEqual(r, again) {
				t.Fatal("response round trip changed")
			}
			if r.Content != nil {
				b, e := content(r)
				if e == nil && base64.StdEncoding.EncodeToString(b) != *r.Content { // Python accepts noncanonical pad bits; decoded bytes must still roundtrip.
					b2, e := base64.StdEncoding.DecodeString(base64.StdEncoding.EncodeToString(b))
					if e != nil || string(b) != string(b2) {
						t.Fatal("base64 bytes changed")
					}
				}
			}
		}
	})
}

func FuzzPluginArguments(f *testing.F) {
	for _, v := range [][3]string{{"/tmp/helper", "/tmp/fixture", ""}, {"/tmp/../outside", "/tmp/f", ""}, {"/tmp/h", "/tmp/f", "-option"}} {
		f.Add(v[0], v[1], v[2])
	}
	f.Fuzz(func(t *testing.T, helper, fixture, host string) {
		if len(helper)+len(fixture)+len(host) > 65536 {
			return
		}
		args := []string{helper, fixture}
		if host != "" {
			args = append(args, "--ssh", host)
		}
		o, e := ParseArgs(args)
		if e == nil {
			for _, p := range []string{o.Helper, o.Fixture} {
				if !strings.HasPrefix(p, "/tmp/") || !strings.HasPrefix(filepath.Clean(p), "/tmp/") || strings.ContainsRune(p, 0) {
					t.Fatal("accepted escaping path")
				}
			}
			if o.SSH != "" && (strings.HasPrefix(o.SSH, "-") || strings.ContainsAny(o.SSH, "\r\n\x00")) {
				t.Fatal("accepted SSH option or control")
			}
			again, e := ParseArgs(args)
			if e != nil || o != again {
				t.Fatal("argument parse not stable")
			}
		}
	})
}
