package clientbootstrap

import (
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestCredentialParserRequiresExactPrivateCallerToken(t *testing.T) {
	for _, data := range []string{`{"caller_token":"fixture","other":1}`, `{"caller_token":"fixture"}`} {
		token, err := ParseCredential([]byte(data))
		if err != nil || token != "fixture" {
			t.Fatalf("valid token lost: %v", err)
		}
	}
	for _, data := range []string{`{}`, `[]`, `{"caller_token":""}`, `{"caller_token":1}`, `{"caller_token":"a","caller_token":"b"}`, `{"caller_token":"a","x":1,"x":2}`, `{"caller_token":"x"`, `{"caller_token":"x"} {}`, `{"caller_token":"x\n"}`, `{"caller_token":"x\u0000"}`, `{"caller_token":"` + strings.Repeat("x", 201) + `"}`, strings.Repeat(" ", MaxCredential+1)} {
		if _, err := ParseCredential([]byte(data)); err == nil {
			t.Fatalf("accepted invalid credential %q", data[:min(len(data), 200)])
		}
	}
}

func fixture(t *testing.T) (string, []Candidate) {
	t.Helper()
	root := t.TempDir()
	credential := filepath.Join(root, "credential.json")
	if err := os.WriteFile(credential, []byte(`{"caller_token":"same-existing-fixture"}`), 0600); err != nil {
		t.Fatal(err)
	}
	var candidates []Candidate
	for i := 0; i < 2; i++ {
		paths := []string{filepath.Join(root, fmt.Sprintf("mcp-%d", i)), filepath.Join(root, fmt.Sprintf("daemon-%d", i))}
		for _, p := range paths {
			if err := os.WriteFile(p, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
				t.Fatal(err)
			}
		}
		candidates = append(candidates, Candidate{paths[0], paths[1]})
	}
	return credential, candidates
}
func TestCredentialPrivateDescriptorRefusesSymlinkPublicAndSpecialFiles(t *testing.T) {
	credential, _ := fixture(t)
	before, err := os.ReadFile(credential)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredential(credential); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(credential, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredential(credential); err == nil {
		t.Fatal("accepted public credential")
	}
	if err := os.Chmod(credential, 0600); err != nil {
		t.Fatal(err)
	}
	link := credential + ".link"
	if err := os.Symlink(credential, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredential(link); err == nil {
		t.Fatal("accepted symlink credential")
	}
	fifo := credential + ".fifo"
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCredential(fifo); err == nil {
		t.Fatal("accepted nonregular credential")
	}
	if _, err := ReadCredential(filepath.Dir(credential)); err == nil {
		t.Fatal("accepted credential directory")
	}
	after, err := os.ReadFile(credential)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("credential changed during read")
	}
}
func TestBootstrapStdioUsesCallerTokenWithoutInstallationFlag(t *testing.T) {
	credential, candidates := fixture(t)
	for _, args := range [][]string{nil, {"ignored-user-argument"}} {
		plan, err := Prepare(credential, candidates, args, nil)
		if err != nil {
			t.Fatal(err)
		}
		want := append([]string{"relay-mcp"}, args...)
		if !reflect.DeepEqual(plan.Args, want) {
			t.Fatalf("stdio argv %#v, want %#v", plan.Args, want)
		}
		if !reflect.DeepEqual(plan.Environment[:1], []string{"RELAY_MCP_CALLER_TOKEN=same-existing-fixture"}) {
			t.Fatalf("caller token missing: %#v", plan.Environment)
		}
	}
}
func TestBootstrapReplacesOnlyOwnedEnvironmentAndPreservesArguments(t *testing.T) {
	credential, candidates := fixture(t)
	env := []string{"UNCHANGED=1", "RELAY_MCP_CALLER_TOKEN=stale", "RELAY_MCP_BACKEND=stale", "RELAY_MCP_DAEMON=/stale", "RELAY_MCP_OWNER_PID=42", "RELAY_MCP_CALLER_TOKEN=duplicate"}
	args := []string{"--http", "--print-http-headers"}
	plan, err := Prepare(credential, candidates, args, env)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Executable != candidates[0].MCP || !reflect.DeepEqual(plan.Args, []string{"relay-mcp", "--use-relay-token", "--http", "--print-http-headers"}) {
		t.Fatalf("selection/argv changed: %#v", plan.Args)
	}
	want := []string{"UNCHANGED=1", "RELAY_MCP_OWNER_PID=42", "RELAY_MCP_CALLER_TOKEN=same-existing-fixture", "RELAY_MCP_BACKEND=daemon", "RELAY_MCP_DAEMON=" + candidates[0].Daemon}
	if !reflect.DeepEqual(plan.Environment, want) {
		t.Fatal("caller/backend environment was not replaced exactly")
	}
	if args[0] != "--http" || env[1] != "RELAY_MCP_CALLER_TOKEN=stale" {
		t.Fatal("input arguments/environment mutated")
	}
}
func TestBootstrapBoundedAuthorityAndEveryTwoActorInterleaving(t *testing.T) {
	credential, candidates := fixture(t)
	paths := []string{candidates[0].MCP, candidates[0].Daemon, candidates[1].MCP, candidates[1].Daemon}
	schedules := [][]int{{0, 1, 2, 3}, {0, 2, 1, 3}, {0, 2, 3, 1}, {2, 0, 1, 3}, {2, 0, 3, 1}, {2, 3, 0, 1}}
	transitions := 0
	for mask := 0; mask < 16; mask++ {
		for _, schedule := range schedules {
			private := true
			present := make([]bool, 4)
			for i, p := range paths {
				present[i] = mask&(1<<i) != 0
				mode := os.FileMode(0600)
				if present[i] {
					mode = 0700
				}
				if err := os.Chmod(p, mode); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Chmod(credential, 0600); err != nil {
				t.Fatal(err)
			}
			check := func() {
				t.Helper()
				plan, err := Prepare(credential, candidates, nil, nil)
				expected := ""
				if private {
					if present[0] && present[1] {
						expected = paths[0]
					} else if present[2] && present[3] {
						expected = paths[2]
					}
				}
				if (err == nil) != (expected != "") || plan.Executable != expected {
					t.Fatalf("authority escaped mask=%d schedule=%v private=%v expected=%q got=%q error=%v", mask, schedule, private, expected, plan.Executable, err)
				}
			}
			check()
			for _, op := range schedule {
				switch op {
				case 0:
					private = false
					if err := os.Chmod(credential, 0644); err != nil {
						t.Fatal(err)
					}
				case 1:
					private = true
					if err := os.Chmod(credential, 0600); err != nil {
						t.Fatal(err)
					}
				case 2:
					present[0] = false
					if err := os.Chmod(paths[0], 0600); err != nil {
						t.Fatal(err)
					}
				case 3:
					present[0] = true
					if err := os.Chmod(paths[0], 0700); err != nil {
						t.Fatal(err)
					}
				}
				check()
				transitions++
			}
		}
	}
	if transitions != 384 {
		t.Fatal("bounded model coverage changed")
	}
	t.Log("actual Prepare: 16 candidate availability states x 6 order-preserving two-actor interleavings; depth4; 384 transitions plus 96 initial checks")
}

func TestBootstrapNativeExecFixture(t *testing.T) {
	if os.Getenv("RELAY_BOOTSTRAP_NATIVE_FIXTURE") != "1" {
		return
	}
	var candidates []Candidate
	if json.Unmarshal([]byte(os.Getenv("RELAY_BOOTSTRAP_CANDIDATES")), &candidates) != nil {
		os.Exit(2)
	}
	plan, err := Prepare(os.Getenv("RELAY_BOOTSTRAP_CREDENTIAL"), candidates, []string{"--http"}, os.Environ())
	if err != nil {
		os.Exit(2)
	}
	if Execute(plan) != nil {
		os.Exit(2)
	}
}
func TestNativeExecKeepsCallerParentPIDAndExistingCredential(t *testing.T) {
	credential, candidates := fixture(t)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nprintf '%s\\n' \"$PPID\" \"$RELAY_MCP_BACKEND\" \"$RELAY_MCP_DAEMON\" \"$RELAY_MCP_CALLER_TOKEN\" \"$1\" \"$2\"\n"
	if err := os.WriteFile(candidates[0].MCP, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(candidates)
	cmd := exec.Command(exe, "-test.run=^TestBootstrapNativeExecFixture$")
	cmd.Env = append(os.Environ(), "RELAY_BOOTSTRAP_NATIVE_FIXTURE=1", "RELAY_BOOTSTRAP_CREDENTIAL="+credential, "RELAY_BOOTSTRAP_CANDIDATES="+string(encoded))
	out, err := cmd.CombinedOutput()
	want := fmt.Sprintf("%d\ndaemon\n%s\nsame-existing-fixture\n--use-relay-token\n--http\n", os.Getpid(), candidates[0].Daemon)
	if err != nil || string(out) != want {
		t.Fatalf("native exec parent/environment/argv changed: %v", err)
	}
}

func FuzzCredentialParser(f *testing.F) {
	for _, data := range [][]byte{[]byte(`{"caller_token":"fixture"}`), []byte(`{"caller_token":"a","caller_token":"b"}`), []byte(`{"caller_token":"fixture"`), nil} {
		f.Add(data)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		token, err := ParseCredential(data)
		if err == nil {
			if len(data) > MaxCredential || token == "" || len(token) > 200 || strings.ContainsAny(token, "\x00\r\n") {
				t.Fatal("credential authority bound escaped")
			}
			var v map[string]any
			if json.Unmarshal(data, &v) != nil || v["caller_token"] != token {
				t.Fatal("accepted token disagrees with JSON")
			}
			for i := len(data) - 1; i >= 0; i-- {
				if data[i] == '}' {
					if _, err := ParseCredential(data[:i]); err == nil {
						t.Fatal("accepted truncated credential")
					}
					break
				}
			}
		}
	})
}
func FuzzCredentialTokenRoundtrip(f *testing.F) {
	f.Add("fixture")
	f.Add("a b")
	f.Add("æ😀")
	f.Fuzz(func(t *testing.T, token string) {
		if len(token) > 200 || token == "" || strings.ContainsAny(token, "\x00\r\n") {
			return
		}
		data, err := json.Marshal(map[string]string{"caller_token": token})
		if err != nil {
			t.Fatal(err)
		}
		var normalized map[string]string
		if json.Unmarshal(data, &normalized) != nil {
			t.Fatal("marshal did not create JSON")
		}
		got, err := ParseCredential(data)
		if len(normalized["caller_token"]) > 200 {
			if err == nil {
				t.Fatal("normalized credential exceeded downstream bound")
			}
			return
		}
		if err != nil || got != normalized["caller_token"] {
			t.Fatal("credential token roundtrip changed")
		}
	})
}

//go:embed testdata/primary.json
var bootstrapPrimary []byte

func TestBootstrapMatchesAll48CanonicalOriginalSelections(t *testing.T) {
	if fmt.Sprintf("%x", sha256.Sum256(bootstrapPrimary)) != "84b21b0c8130a24238783ad1dac18dd1ce26b0c04de67d16b2d336ad81abd11b" {
		t.Fatal("bootstrap primary corpus drift")
	}
	var records []struct {
		Mask   int      `json:"mask"`
		Args   []string `json:"args"`
		Result struct {
			Executable  string            `json:"executable"`
			Args        []string          `json:"args"`
			Environment map[string]string `json:"environment"`
		} `json:"result"`
	}
	if json.Unmarshal(bootstrapPrimary, &records) != nil || len(records) != 48 {
		t.Fatal("bootstrap primary case coverage changed")
	}
	credential, candidates := fixture(t)
	paths := []string{candidates[0].MCP, candidates[0].Daemon, candidates[1].MCP, candidates[1].Daemon}
	rewrite := strings.NewReplacer("$HOME/App/relay-mcp", paths[0], "$HOME/App/relayd", paths[1], "$HOME/.local/share/relay/bin/relay-mcp-verified", paths[2], "$HOME/.local/share/relay/bin/relayd-verified", paths[3])
	for i, record := range records {
		for bit, path := range paths {
			mode := os.FileMode(0600)
			if record.Mask&(1<<bit) != 0 {
				mode = 0700
			}
			if err := os.Chmod(path, mode); err != nil {
				t.Fatal(err)
			}
		}
		plan, err := Prepare(credential, candidates, record.Args, []string{"RELAY_MCP_OWNER_PID=42", "RELAY_MCP_CALLER_TOKEN=stale", "RELAY_MCP_BACKEND=stale", "RELAY_MCP_DAEMON=/stale"})
		if record.Result.Executable == "" {
			if err == nil {
				t.Fatalf("canonical refusal accepted: %d", i)
			}
			continue
		}
		// Deliberate change from the pinned corpus: stdio argv no longer carries
		// --use-relay-token (the caller token authenticates); the corpus is untouched.
		wantArgs := record.Result.Args
		if !needsInstallationToken(record.Args) {
			wantArgs = append([]string{wantArgs[0]}, wantArgs[2:]...)
		}
		if err != nil || plan.Executable != rewrite.Replace(record.Result.Executable) || !reflect.DeepEqual(plan.Args, wantArgs) {
			t.Fatalf("canonical bootstrap selection/arguments differ: %d %v", i, err)
		}
		got := map[string]string{}
		for _, field := range plan.Environment {
			key, value, ok := strings.Cut(field, "=")
			if !ok {
				t.Fatal("environment field corrupted")
			}
			got[key] = value
		}
		want := map[string]string{}
		for key, value := range record.Result.Environment {
			want[key] = rewrite.Replace(value)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("canonical bootstrap environment differs: %d", i)
		}
	}
}
