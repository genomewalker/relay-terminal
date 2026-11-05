package clientbootstrap

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

type remoteObservation struct {
	Args        []string          `json:"args"`
	Environment map[string]string `json:"environment"`
	PID         int               `json:"pid"`
	ParentPID   int               `json:"parent_pid"`
}

// Only a copied private MCP fixture enters this branch; normal tests retain
// their runner. No real provider or installed helper is executed by these tests.
func TestMain(m *testing.M) {
	if os.Getenv("RELAY_REMOTE_NATIVE_CAPTURE") == "1" && filepath.Base(os.Args[0]) == "relay-mcp-communication" {
		env := map[string]string{}
		for _, key := range []string{"RELAY_MCP_TOKEN", "RELAY_MCP_PORT", "RELAY_MCP_CALLER_TOKEN", "RELAY_MCP_BACKEND", "RELAY_MCP_DAEMON", "RELAY_MCP_OWNER_PID", "KEEP_REMOTE"} {
			env[key] = os.Getenv(key)
		}
		if json.NewEncoder(os.Stdout).Encode(remoteObservation{os.Args, env, os.Getpid(), os.Getppid()}) != nil {
			os.Exit(91)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func remoteFixture(t testing.TB) (home, executable, credential string) {
	t.Helper()
	home = t.TempDir()
	executable = filepath.Join(home, "caller", "relay-client")
	credential = filepath.Join(filepath.Dir(executable), "credential.json")
	if err := os.MkdirAll(filepath.Dir(executable), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credential, []byte(`{"caller_token":"remote-fixture-caller"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".relay-mcp-desktop.json"), []byte(`{"token":"remote-fixture-desktop","port":47479}`), 0600); err != nil {
		t.Fatal(err)
	}
	return
}
func remoteEnv() []string {
	return []string{"KEEP_REMOTE=first", "RELAY_MCP_TOKEN=old", "RELAY_MCP_PORT=old", "RELAY_MCP_CALLER_TOKEN=old", "RELAY_MCP_BACKEND=old", "RELAY_MCP_DAEMON=old", "RELAY_MCP_OWNER_PID=42", "KEEP_REMOTE=second", "RELAY_MCP_TOKEN=duplicate", "RELAY_MCP_PORT=duplicate", "RELAY_MCP_CALLER_TOKEN=duplicate", "RELAY_MCP_BACKEND=duplicate", "RELAY_MCP_DAEMON=duplicate", "RELAY_MCP_TOKEN_SUFFIX=keep"}
}
func TestRemoteCompositionExactAliasesArgvAndEnvironment(t *testing.T) {
	home := "/private/remote fixture"
	incoming := remoteEnv()
	before := append([]string(nil), incoming...)
	plan, err := prepareRemote(home, "remote-fixture-caller", []byte(`{"token":"remote-fixture-desktop","port":47479}`), incoming)
	if err != nil {
		t.Fatal(err)
	}
	mcp := filepath.Join(home, ".local/share/relay/bin/relay-mcp-communication")
	if plan.Executable != mcp || !reflect.DeepEqual(plan.Args, []string{mcp}) {
		t.Fatal("REMOTE_ARGV: original communication alias or ignored argv contract changed")
	}
	want := []string{"KEEP_REMOTE=first", "RELAY_MCP_OWNER_PID=42", "KEEP_REMOTE=second", "RELAY_MCP_TOKEN_SUFFIX=keep", "RELAY_MCP_TOKEN=remote-fixture-desktop", "RELAY_MCP_PORT=47479", "RELAY_MCP_CALLER_TOKEN=remote-fixture-caller", "RELAY_MCP_BACKEND=daemon", "RELAY_MCP_DAEMON=" + filepath.Join(home, ".local/share/relay/bin/relayd-communication")}
	if !reflect.DeepEqual(plan.Environment, want) {
		t.Fatal("REMOTE_ENV: forwarding, unrelated duplicate preservation or owned-key replacement changed")
	}
	if !reflect.DeepEqual(incoming, before) {
		t.Fatal("REMOTE_ENV: composition mutated original environment")
	}
}
func TestRemoteAuthorityRefusals(t *testing.T) {
	for _, kind := range []string{"public", "symlink", "fifo", "directory", "missing", "empty", "duplicate", "trailing", "oversized"} {
		t.Run(kind, func(t *testing.T) {
			home, exe, credential := remoteFixture(t)
			switch kind {
			case "public":
				if err := os.Chmod(credential, 0644); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Rename(credential, credential+".old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(credential+".old", credential); err != nil {
					t.Fatal(err)
				}
			case "fifo", "directory", "missing":
				if err := os.Remove(credential); err != nil {
					t.Fatal(err)
				}
				if kind == "fifo" {
					if err := syscall.Mkfifo(credential, 0600); err != nil {
						t.Fatal(err)
					}
				}
				if kind == "directory" {
					if err := os.Mkdir(credential, 0700); err != nil {
						t.Fatal(err)
					}
				}
			default:
				value := map[string]string{"empty": `{"caller_token":""}`, "duplicate": `{"caller_token":"a","caller_token":"b"}`, "trailing": `{"caller_token":"a"}{}`, "oversized": strings.Repeat(" ", MaxCredential+1)}[kind]
				if err := os.WriteFile(credential, []byte(value), 0600); err != nil {
					t.Fatal(err)
				}
			}
			plan, err := prepareForHost("linux", exe, home, []string{"--http", "--use-relay-token"}, remoteEnv())
			if err == nil || !reflect.DeepEqual(plan, Plan{}) {
				t.Fatal("REMOTE_AUTHORITY: unsafe caller produced an exec plan")
			}
		})
	}
}
func TestRemoteDesktopRefusalAndBoundedFile(t *testing.T) {
	home, exe, _ := remoteFixture(t)
	path := filepath.Join(home, ".relay-mcp-desktop.json")
	valid := []byte(`{"token":"remote-fixture-desktop","port":47479}`)
	for _, data := range [][]byte{nil, []byte(`{}`), []byte(`[]`), []byte(`{"token":"a","port":1,"port":2}`), []byte(`{"token":"a","port":1}{}`), []byte(`{"token":"a","port":[]}`), []byte(`{"token":"a\u0000","port":1}`), []byte(`{"token":"a","port":"x\u0000"}`), []byte(`{"token":"\ud800","port":1}`), bytes.Repeat([]byte{' '}, maxDesktopConfiguration+1)} {
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		plan, err := prepareForHost("linux", exe, home, nil, remoteEnv())
		if err == nil || !reflect.DeepEqual(plan, Plan{}) {
			t.Fatal("REMOTE_DESKTOP: malformed or oversized desktop configuration admitted")
		}
	}
	if _, err := readDesktopConfiguration(path); err == nil {
		t.Fatal("REMOTE_FILE_BOUND: oversized file admitted by bounded reader")
	}
	padded := append(append([]byte(nil), valid...), bytes.Repeat([]byte{' '}, maxDesktopConfiguration-len(valid))...)
	if err := os.WriteFile(path, padded, 0600); err != nil {
		t.Fatal(err)
	}
	if data, err := readDesktopConfiguration(path); err != nil || len(data) != maxDesktopConfiguration {
		t.Fatal("REMOTE_FILE_BOUND: exact file bound changed")
	}
	if _, err := prepareForHost("linux", exe, home, nil, nil); err != nil {
		t.Fatal("REMOTE_FILE_BOUND: bounded valid desktop refused")
	}
	if err := os.Rename(path, path+".target"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path+".target", path); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareForHost("linux", exe, home, nil, nil); err != nil {
		t.Fatal("REMOTE_DESKTOP: original regular symlink target refused")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readDesktopConfiguration(path); err == nil {
		t.Fatal("REMOTE_FILE_BOUND: nonregular desktop admitted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := readDesktopConfiguration(path); err == nil {
		t.Fatal("REMOTE_FILE_BOUND: missing desktop admitted")
	}
	if _, err := prepareRemote("", "caller", valid, nil); err == nil {
		t.Fatal("REMOTE_DESKTOP: missing home admitted")
	}
}
func TestRemoteBoundedAuthorityEveryTwoActorInterleaving(t *testing.T) {
	home, exe, credential := remoteFixture(t)
	desktop := filepath.Join(home, ".relay-mcp-desktop.json")
	schedules := [][]int{{0, 1, 2, 3}, {0, 2, 1, 3}, {0, 2, 3, 1}, {2, 0, 1, 3}, {2, 0, 3, 1}, {2, 3, 0, 1}}
	transitions, checks := 0, 0
	states := map[string]bool{}
	for initial := 0; initial < 4; initial++ {
		for _, schedule := range schedules {
			private, valid := initial&1 != 0, initial&2 != 0
			syncState := func() {
				t.Helper()
				mode := os.FileMode(0644)
				if private {
					mode = 0600
				}
				if err := os.Chmod(credential, mode); err != nil {
					t.Fatal(err)
				}
				data := []byte(`{"token":"remote-fixture-desktop","port":47479}`)
				if !valid {
					data = []byte(`{"token":"a","port":1,"port":2}`)
				}
				if err := os.WriteFile(desktop, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			check := func() {
				t.Helper()
				plan, err := prepareForHost("linux", exe, home, []string{"--ignored"}, remoteEnv())
				if (err == nil) != (private && valid) {
					t.Fatalf("REMOTE_MODEL: authority escaped initial=%d schedule=%v private=%v valid=%v", initial, schedule, private, valid)
				}
				if err != nil && !reflect.DeepEqual(plan, Plan{}) {
					t.Fatal("REMOTE_MODEL: refusal retained an executable plan")
				}
				if err == nil && (len(plan.Args) != 1 || plan.Args[0] != filepath.Join(home, ".local/share/relay/bin/relay-mcp-communication")) {
					t.Fatal("REMOTE_MODEL: admitted route changed")
				}
				states[fmt.Sprintf("%v/%v", private, valid)] = true
				checks++
			}
			syncState()
			check()
			for _, op := range schedule {
				switch op {
				case 0:
					private = false
				case 1:
					private = true
				case 2:
					valid = false
				case 3:
					valid = true
				}
				syncState()
				check()
				transitions++
			}
		}
	}
	if transitions != 96 || checks != 120 || len(states) != 4 {
		t.Fatal("REMOTE_MODEL: finite coverage changed")
	}
	t.Log("real host preparation: 4 initial states x 6 order-preserving two-actor histories, depth4; 96 transitions,120 checks,4 observed states")
}
func TestRemoteRunFixture(t *testing.T) {
	if os.Getenv("RELAY_REMOTE_BOOTSTRAP_FIXTURE") != "1" {
		return
	}
	args := []string{"--http", "--use-relay-token", "ignored-user-argument"}
	if runtime.GOOS == "linux" {
		if Run(args) != nil {
			os.Exit(92)
		}
	} else {
		exe, err := os.Executable()
		if err != nil {
			os.Exit(93)
		}
		home, err := os.UserHomeDir()
		if err != nil {
			os.Exit(94)
		}
		plan, err := prepareForHost("linux", exe, home, args, os.Environ())
		// A faulty host selection must never execute an installed Mac app in this test.
		if err != nil || plan.Executable != filepath.Join(home, ".local/share/relay/bin/relay-mcp-communication") {
			os.Exit(95)
		}
		if Execute(plan) != nil {
			os.Exit(96)
		}
	}
	// A successful exec never returns. If a child-spawning mutant returns,
	// retain its capture unchanged so the parent test checks PID/PPID directly.
	os.Exit(0)
}
func TestRemoteNativeExecKeepsExactProcessParentAndForwarding(t *testing.T) {
	home, bootstrap, credential := remoteFixture(t)
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	mcp := filepath.Join(home, ".local/share/relay/bin/relay-mcp-communication")
	if err := os.MkdirAll(filepath.Dir(mcp), 0700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{bootstrap, mcp} {
		if err := os.WriteFile(path, body, 0700); err != nil {
			t.Fatal(err)
		}
	}
	before, err := os.ReadFile(credential)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, bootstrap, "-test.run=^TestRemoteRunFixture$")
	command.Env = append(os.Environ(), "HOME="+home, "RELAY_REMOTE_BOOTSTRAP_FIXTURE=1", "RELAY_REMOTE_NATIVE_CAPTURE=1", "GORACE=atexit_sleep_ms=0", "RELAY_MCP_TOKEN=stale", "RELAY_MCP_PORT=stale", "RELAY_MCP_CALLER_TOKEN=stale", "RELAY_MCP_BACKEND=stale", "RELAY_MCP_DAEMON=stale", "KEEP_REMOTE=untouched", "RELAY_MCP_OWNER_PID=42")
	out, err := command.Output()
	if err != nil {
		t.Fatalf("REMOTE_EXEC: private native launch failed: %v", err)
	}
	var observed remoteObservation
	if json.Unmarshal(out, &observed) != nil {
		t.Fatal("REMOTE_EXEC: invalid private capture")
	}
	if observed.PID != command.Process.Pid || observed.ParentPID != os.Getpid() {
		t.Fatal("REMOTE_EXEC: exec changed caller PID or parent")
	}
	if !reflect.DeepEqual(observed.Args, []string{mcp}) {
		t.Fatal("REMOTE_EXEC: remote argv included a Mac flag or caller argument")
	}
	want := map[string]string{"RELAY_MCP_TOKEN": "remote-fixture-desktop", "RELAY_MCP_PORT": "47479", "RELAY_MCP_CALLER_TOKEN": "remote-fixture-caller", "RELAY_MCP_BACKEND": "daemon", "RELAY_MCP_DAEMON": filepath.Join(home, ".local/share/relay/bin/relayd-communication"), "KEEP_REMOTE": "untouched", "RELAY_MCP_OWNER_PID": "42"}
	if !reflect.DeepEqual(observed.Environment, want) {
		t.Fatal("REMOTE_EXEC: caller/desktop transport or unrelated environment changed")
	}
	after, err := os.ReadFile(credential)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("REMOTE_EXEC: existing credential changed")
	}
}

//go:embed testdata/remote_primary.json
var remotePrimary []byte

func TestRemoteMatchesCaptured814BytePrimary(t *testing.T) {
	if fmt.Sprintf("%x", sha256.Sum256(remotePrimary)) != "d6c20143938256122898bc0b5cba1ef08511d51a77ba965292fd1451b93c7df1" {
		t.Fatal("REMOTE_PRIMARY: captured primary corpus identity changed")
	}
	var corpus struct {
		SourceSHA256 string `json:"source_sha256"`
		Cases        []struct {
			Desktop  json.RawMessage   `json:"desktop"`
			Incoming []string          `json:"incoming"`
			Expected remoteObservation `json:"expected"`
		} `json:"cases"`
	}
	if json.Unmarshal(remotePrimary, &corpus) != nil || corpus.SourceSHA256 != "4d5013c0d4f8faac8608e635c3fe48ab34f221898b1aae43948f9140688539ff" || len(corpus.Cases) != 12 {
		t.Fatal("REMOTE_PRIMARY: primary cases or source changed")
	}
	for i, c := range corpus.Cases {
		plan, err := prepareRemote("/primary-home", "remote-fixture-caller", c.Desktop, c.Incoming)
		if err != nil || plan.Executable != "/primary-home/.local/share/relay/bin/relay-mcp-communication" || !reflect.DeepEqual(plan.Args, c.Expected.Args) {
			t.Fatalf("REMOTE_PRIMARY: selection/argv differs case%d", i)
		}
		got := map[string]string{}
		for _, field := range plan.Environment {
			k, v, ok := strings.Cut(field, "=")
			if ok {
				got[k] = v
			}
		}
		if !reflect.DeepEqual(got, c.Expected.Environment) {
			t.Fatalf("REMOTE_PRIMARY: exact primary environment differs case%d", i)
		}
	}
}
func FuzzRemoteComposition(f *testing.F) {
	for _, data := range [][]byte{[]byte(`{"token":"fixture","port":47479}`), []byte(`{"token":"","port":null}`), []byte(`{"token":"a","port":1,"port":2}`), []byte(`{"token":"a","port":[]}`), nil} {
		f.Add(data)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		incoming := remoteEnv()
		before := append([]string(nil), incoming...)
		plan, err := prepareRemote("/fixture", "remote-fixture-caller", data, incoming)
		if !reflect.DeepEqual(incoming, before) {
			t.Fatal("REMOTE_FUZZ: input environment mutated")
		}
		if err != nil {
			if !reflect.DeepEqual(plan, Plan{}) {
				t.Fatal("REMOTE_FUZZ: error retained authority")
			}
			return
		}
		if len(data) > maxDesktopConfiguration || plan.Executable != "/fixture/.local/share/relay/bin/relay-mcp-communication" || !reflect.DeepEqual(plan.Args, []string{plan.Executable}) {
			t.Fatal("REMOTE_FUZZ: output bound or remote argv escaped")
		}
		keep := []string{}
		counts := map[string]int{}
		owned := map[string]string{}
		for _, field := range plan.Environment {
			key, value, _ := strings.Cut(field, "=")
			switch key {
			case "RELAY_MCP_TOKEN", "RELAY_MCP_PORT", "RELAY_MCP_CALLER_TOKEN", "RELAY_MCP_BACKEND", "RELAY_MCP_DAEMON":
				counts[key]++
				owned[key] = value
			default:
				keep = append(keep, field)
			}
		}
		for _, key := range []string{"RELAY_MCP_TOKEN", "RELAY_MCP_PORT", "RELAY_MCP_CALLER_TOKEN", "RELAY_MCP_BACKEND", "RELAY_MCP_DAEMON"} {
			if counts[key] != 1 {
				t.Fatal("REMOTE_FUZZ: owned environment not replaced exactly once")
			}
		}
		if !reflect.DeepEqual(keep, []string{"KEEP_REMOTE=first", "RELAY_MCP_OWNER_PID=42", "KEEP_REMOTE=second", "RELAY_MCP_TOKEN_SUFFIX=keep"}) || owned["RELAY_MCP_CALLER_TOKEN"] != "remote-fixture-caller" || owned["RELAY_MCP_BACKEND"] != "daemon" || owned["RELAY_MCP_DAEMON"] != "/fixture/.local/share/relay/bin/relayd-communication" {
			t.Fatal("REMOTE_FUZZ: unrelated/caller/backend environment changed")
		}
		var document map[string]json.RawMessage
		var token string
		if json.Unmarshal(data, &document) != nil || json.Unmarshal(document["token"], &token) != nil || owned["RELAY_MCP_TOKEN"] != token {
			t.Fatal("REMOTE_FUZZ: forwarded token differs from accepted JSON")
		}
		for i := len(data) - 1; i >= 0; i-- {
			if data[i] == '}' {
				if _, err := prepareRemote("/fixture", "remote-fixture-caller", data[:i], incoming); err == nil {
					t.Fatal("REMOTE_FUZZ: truncated document admitted")
				}
				break
			}
		}
	})
}
