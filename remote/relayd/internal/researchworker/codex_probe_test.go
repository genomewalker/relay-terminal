package researchworker

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// The Codex shell-denial probe runs the real Codex binary offline. It never
// makes a model call: CODEX_HOME is an empty temporary directory, so no
// credentials exist, and `codex debug prompt-input` only renders what the
// model would be shown. Set RELAY_CODEX_BINARY to the real binary (not the
// Relay shim) to run it.
//
// What it proves: the planned flags take exec_command/write_stdin off the
// tools Codex describes to its model, and the remaining set is exactly
// CodexResidualTools. What it does not prove: that a running worker cannot
// reach a shell some other way. That needs one approved worker turn.

// offlineEnv drops every provider credential variable, so no request can be
// authenticated even if Codex tried one.
func offlineEnv(home string) []string {
	env := []string{"CODEX_HOME=" + home}
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if name == "CODEX_HOME" || strings.Contains(name, "API_KEY") || strings.Contains(name, "TOKEN") || strings.HasPrefix(name, "OPENAI_") || strings.HasPrefix(name, "CODEX_") {
			continue
		}
		env = append(env, entry)
	}
	return env
}

func codexBinary(t *testing.T) string {
	t.Helper()
	path := os.Getenv("RELAY_CODEX_BINARY")
	if path == "" {
		t.Skip("set RELAY_CODEX_BINARY to the real Codex binary to run the offline shell-denial probe")
	}
	if strings.Contains(path, "/relay/shims/") || !filepath.IsAbs(path) {
		t.Fatalf("RELAY_CODEX_BINARY must be the real absolute Codex binary, not %s", path)
	}
	return path
}

// probeArguments keeps the planner's --disable and -c options, so the probe
// checks exactly what a worker would be launched with.
func probeArguments(argv []string) []string {
	var out []string
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == "--disable" || argv[i] == "-c" {
			out = append(out, argv[i], argv[i+1])
			i++
		}
	}
	return out
}

var nestedTool = regexp.MustCompile("(?m)^### `([a-z_0-9]+)`")

type probeResult struct {
	Namespaces []string
	Nested     []string
	Sandbox    string
}

func promptInput(t *testing.T, binary string, arguments []string) probeResult {
	t.Helper()
	home, cwd := t.TempDir(), t.TempDir()
	command := exec.Command(binary, append(append([]string{"debug", "prompt-input"}, arguments...), "probe")...)
	command.Dir = cwd
	command.Env = offlineEnv(home)
	done := make(chan struct{})
	var out []byte
	var err error
	var stderr strings.Builder
	command.Stderr = &stderr
	go func() { out, err = command.Output(); close(done) }()
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		_ = command.Process.Kill()
		t.Fatal("prompt-input timed out")
	}
	if err != nil {
		t.Fatalf("prompt-input failed: %v: %.400s", err, stderr.String())
	}
	if dir := os.Getenv("RELAY_CODEX_PROBE_OUT"); dir != "" {
		_ = os.WriteFile(filepath.Join(dir, t.Name()+"-"+strings.Join(arguments[:min(2, len(arguments))], "")+".json"), out, 0o600)
	}
	var items []struct {
		Type    string `json:"type"`
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		Tools []struct {
			Name  string `json:"name"`
			Tools []struct {
				Name        string `json:"name"`
				Description string `json:"description"`
			} `json:"tools"`
		} `json:"tools"`
	}
	if json.Unmarshal(out, &items) != nil {
		t.Fatalf("unparseable prompt-input: %.200s", out)
	}
	var result probeResult
	for _, item := range items {
		for _, content := range item.Content {
			if m := regexp.MustCompile("sandbox_mode` is `([a-z-]+)`").FindStringSubmatch(content.Text); m != nil {
				result.Sandbox = m[1]
			}
		}
		for _, namespace := range item.Tools {
			result.Namespaces = append(result.Namespaces, namespace.Name)
			for _, tool := range namespace.Tools {
				result.Nested = append(result.Nested, namespace.Name+"."+tool.Name)
				if tool.Name == "exec" {
					for _, m := range nestedTool.FindAllStringSubmatch(tool.Description, -1) {
						result.Nested = append(result.Nested, "exec."+m[1])
					}
				}
			}
		}
	}
	sort.Strings(result.Nested)
	return result
}

func TestCodexShellDenialProbe(t *testing.T) {
	binary := codexBinary(t)
	if version, err := exec.Command(binary, "--version").Output(); err == nil {
		t.Logf("probing %s", strings.TrimSpace(string(version)))
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	p := basePolicy(ProviderCodex)
	readerLog := filepath.Join(t.TempDir(), "reader.log")
	p.Reader = Reader{Command: self, Args: []string{readerLog, fakeReaderArgument}, Tools: []string{"read", "search"}}
	launch, err := Plan(p, testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	// Positive control: without the plan the probe must see the shell, or the
	// absence below would mean nothing.
	control := promptInput(t, binary, nil)
	if !slices.Contains(control.Nested, "exec.exec_command") || !slices.Contains(control.Nested, "exec.write_stdin") {
		t.Fatalf("probe cannot see the default shell tools: %q", control.Nested)
	}
	restricted := promptInput(t, binary, append(probeArguments(launch.Argv), "-c", `sandbox_mode="read-only"`))
	for _, tool := range restricted.Nested {
		name := tool[strings.LastIndex(tool, ".")+1:]
		if strings.Contains(name, "exec_command") || strings.Contains(name, "write_stdin") || strings.Contains(name, "shell") || name == "view_image" || strings.Contains(name, "web_search") {
			t.Fatalf("restricted worker still offered %s", tool)
		}
	}
	var residual []string
	for _, tool := range restricted.Nested {
		if strings.HasPrefix(tool, "exec.") {
			residual = append(residual, strings.TrimPrefix(tool, "exec."))
		}
	}
	sort.Strings(residual)
	// prompt-input does not render MCP tools, so the reader's tools are not in
	// this list; only the reader's start-up is checked below.
	wantResidual := CodexResidualTools
	if !slices.Equal(residual, wantResidual) {
		t.Fatalf("Codex residual tools changed: got %q, want %q; update the plan's partial reasons", residual, wantResidual)
	}
	if !slices.Contains(restricted.Namespaces, "collaboration") || !slices.Contains(launch.Residual, "collaboration (spawn_agent and related)") {
		t.Fatalf("collaboration tools: offered=%v, reported=%v", slices.Contains(restricted.Namespaces, "collaboration"), launch.Residual)
	}
	calls, _ := os.ReadFile(readerLog)
	t.Logf("evidence reader calls: %q", strings.Fields(string(calls)))
	if !strings.Contains(string(calls), "initialize") {
		t.Fatal("the required evidence reader was not started")
	}
	if restricted.Sandbox != "read-only" {
		t.Fatalf("sandbox_mode rendered as %q", restricted.Sandbox)
	}
	t.Logf("restricted tools offered to the model: %q", restricted.Nested)
}

// Every -c key and --disable name in the plan is recognized by this Codex.
// --strict-config rejects unknown keys before any session starts; with an empty
// CODEX_HOME there are no credentials, and the required reader (/usr/bin/false)
// fails its handshake, so the run stops before any model call.
func TestCodexWorkerConfigIsRecognized(t *testing.T) {
	binary := codexBinary(t)
	p := basePolicy(ProviderCodex)
	p.Executable, p.Reader.Command, p.Cwd = binary, "/usr/bin/false", t.TempDir()
	launch, err := Plan(p, testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(launch.Argv[0], append(launch.Argv[1:], "probe")...)
	command.Env = offlineEnv(t.TempDir())
	command.Stdin = strings.NewReader("")
	timer := time.AfterFunc(60*time.Second, func() { _ = command.Process.Kill() })
	out, err := command.CombinedOutput()
	timer.Stop()
	text := string(out)
	if err == nil {
		t.Fatalf("worker run with a failing required reader succeeded: %.400s", text)
	}
	if strings.Contains(text, "unknown configuration field") || strings.Contains(text, "Unknown feature flag") || strings.Contains(text, "invalid transport") {
		t.Fatalf("plan uses options this Codex does not recognize: %.400s", text)
	}
	if !strings.Contains(text, "required MCP servers failed to initialize") || !strings.Contains(text, ReaderServer) {
		t.Fatalf("run did not stop at the required evidence reader: %.400s", text)
	}
}
