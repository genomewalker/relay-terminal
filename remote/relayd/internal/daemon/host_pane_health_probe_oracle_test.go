package daemon

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Primary reference captured from the original interpreter with all 241 cases
// passing. The runtime source is archived outside the maintained release tree.
//
//go:embed testdata/host_pane_health_probe/reference.json
var phProbeReference []byte

//go:embed testdata/host_pane_health_probe/linux-reference.json
var phProbeLinuxReference []byte

type phOracleCase struct {
	Call    string         `json:"call,omitempty"`
	Args    []any          `json:"args,omitempty"`
	Reader  map[string]any `json:"reader,omitempty"`
	Globals map[string]any `json:"globals,omitempty"`
	Servers any            `json:"servers,omitempty"`
	Probe   string         `json:"probe,omitempty"`
	Daemon  string         `json:"daemon,omitempty"`
}

type phOracleResult struct {
	Value   *string `json:"value"`
	Raised  string  `json:"raised"`
	Message string  `json:"message"`
}

// The Darwin capture used an aliased /tmp HOME. Its resolved-home values
// therefore contain /private$PROBE_HOME. Bind that captured physical-home
// marker independently, before binding the literal HOME marker. The pinned
// primary corpus and every byte comparison remain unchanged.
func phProbeBindHome(text, home, physicalHome string) string {
	return strings.NewReplacer("/private$PROBE_HOME", physicalHome, "$PROBE_HOME", home).Replace(text)
}

func TestProbeReferenceHomeRebinding(t *testing.T) {
	for _, home := range []string{"/tmp/probe-home", "/private/tmp/probe-home"} {
		got := phProbeBindHome(`literal=$PROBE_HOME;resolved=/private$PROBE_HOME/.codex`, home, "/private/tmp/probe-home")
		want := "literal=" + home + ";resolved=/private/tmp/probe-home/.codex"
		if got != want {
			t.Fatal("captured physical home rebound twice", got, want)
		}
	}
}

// phRunOracle retains the original comparison contract using primary outputs.
// Only temporary paths and revision metadata are rebound; unknown inputs fail.
func phRunOracle(t *testing.T, cases []phOracleCase) []phOracleResult {
	t.Helper()
	keyOf := func(c phOracleCase) string {
		data, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		// The original oracle decoded marshalled input. Canonicalize that same
		// boundary, including invalid UTF-8 replacement, without float rounding.
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		var value any
		if err := decoder.Decode(&value); err != nil {
			t.Fatal(err)
		}
		data, err = json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	reference, expectedSHA := phProbeReference, "0c8340042b720f3e95f1917809cefdd9c9462c80cd507ea2de3267a9e02b5539"
	if runtime.GOOS == "linux" {
		reference, expectedSHA = phProbeLinuxReference, "5691eb6e1a5bf21647050bab4125ae7b8107ea73d2c9e98f789a20d001185bd5"
	}
	if got := fmt.Sprintf("%x", sha256.Sum256(reference)); got != expectedSHA {
		t.Fatal("probe primary reference drifted")
	}
	var rows []struct {
		Case   phOracleCase   `json:"case"`
		Result phOracleResult `json:"result"`
	}
	if err := json.Unmarshal(reference, &rows); err != nil {
		t.Fatal(err)
	}
	index := map[string]phOracleResult{}
	for _, row := range rows {
		key := keyOf(row.Case)
		if before, ok := index[key]; ok && !phSameOutcome(before, row.Result) {
			t.Fatalf("ambiguous reference %s", key)
		}
		index[key] = row.Result
	}
	home := os.Getenv("HOME")
	physicalHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	results := make([]phOracleResult, len(cases))
	for i, c := range cases {
		key := strings.ReplaceAll(keyOf(c), home, "$PROBE_HOME")
		value, ok := index[key]
		if !ok {
			t.Fatalf("uncaptured primary case %s", key)
		}
		if value.Value != nil {
			text := phProbeBindHome(*value.Value, home, physicalHome)
			if strings.Contains(text, "$PROBE_REVISION") {
				path, ok := c.Args[0].(string)
				if !ok {
					t.Fatal("revision case has no path")
				}
				info, err := os.Stat(path)
				if err != nil {
					t.Fatal(err)
				}
				st, ok := info.Sys().(*syscall.Stat_t)
				if !ok {
					t.Fatal("no native stat metadata")
				}
				preimage := fmt.Sprintf("%d:%d:%d:%d", st.Dev, st.Ino, info.Size(), info.ModTime().UnixNano())
				text = strings.ReplaceAll(text, "$PROBE_REVISION", fmt.Sprintf("%x", sha256.Sum256([]byte(preimage))))
			}
			value.Value = &text
		}
		value.Message = phProbeBindHome(value.Message, home, physicalHome)
		results[i] = value
	}
	if len(cases) != len(rows) {
		t.Fatalf("reference case count %d != %d", len(cases), len(rows))
	}
	return results
}

func phKindName(kind phKind) string {
	return map[phKind]string{phOSError: "OSError", phValueError: "ValueError", phUnbound: "Unbound", phTimeout: "Timeout",
		phKeyError: "KeyError", phAttributeError: "AttributeError", phTypeError: "TypeError", phIndexError: "IndexError",
		phRuntimeError: "RuntimeError"}[kind]
}

// phEvaluate runs one case natively, catching exceptions the way the oracle
// reports them.
func phEvaluate(t *testing.T, c phOracleCase) (result phOracleResult) {
	t.Helper()
	defer func() {
		if recovered := recover(); recovered != nil {
			exception := phExceptionOf(recovered)
			if exception == nil {
				panic(recovered)
			}
			result = phOracleResult{Raised: phKindName(exception.kind), Message: exception.msg}
		}
	}()
	data, _ := json.Marshal(c.Args)
	decoded, err := pyDecode(data)
	if err != nil {
		t.Fatal(err)
	}
	var args []any
	if list, ok := decoded.(*pyList); ok {
		args = list.items
	}
	r := phFakeReader(t, c)
	value := phDispatch(t, r, c, args)
	text := string(pyEncode(value, pyEncodeOptions{itemSep: ", ", keySep: ": "}))
	return phOracleResult{Value: &text}
}

func phTestStrings(v any) []string {
	var result []string
	for _, item := range pyMustList(v).items {
		result = append(result, pyMustString(item))
	}
	return result
}

func phOptionalString(v any) string {
	if v == nil {
		return ""
	}
	return pyMustString(v)
}

func phNone(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func phStringList(values []string) *pyList {
	list := &pyList{items: []any{}}
	for _, value := range values {
		list.items = append(list.items, value)
	}
	return list
}

func phVersionValue(v phVersion) any {
	if v == nil {
		return nil
	}
	list := &pyList{items: []any{}}
	for _, part := range v {
		if part.IsInt64() {
			list.items = append(list.items, part.Int64())
		} else {
			list.items = append(list.items, new(big.Int).Set(part))
		}
	}
	return list
}

func phEntriesValue(entries []phMCPEntry) any {
	if entries == nil {
		return nil
	}
	list := &pyList{items: []any{}}
	for _, entry := range entries {
		list.items = append(list.items, pyListOf(entry.command, phStringList(entry.args)))
	}
	return list
}

func phEntriesOf(v any) []phMCPEntry {
	var entries []phMCPEntry
	for _, item := range pyMustList(v).items {
		pair := pyMustList(item).items
		entries = append(entries, phMCPEntry{command: pyMustString(pair[0]), args: phTestStrings(pair[1])})
	}
	return entries
}

func phPid(v any) int64 {
	value, ok := pyInt(v)
	if !ok {
		panic("pid fixture must be an int")
	}
	return value
}

// phFakeReader applies the same fixture overrides oracle.py applies.
func phFakeReader(t *testing.T, c phOracleCase) *phReader {
	r := newPHReader(nil)
	spec, _ := pyFromGo(c.Reader)
	if object, ok := spec.(*pyObject); ok && c.Reader != nil {
		if rows, ok := object.Lookup("inventory"); ok {
			r.inventory = func() *phProcesses {
				processes := &phProcesses{rows: map[int64]phProcess{}}
				for _, row := range pyMustList(rows).items {
					items := pyMustList(row).items
					processes.set(phPid(items[0]), phProcess{parent: phPid(items[1]), name: pyMustString(items[2])})
				}
				return processes
			}
		}
		if table, ok := object.Lookup("identity"); ok {
			r.identity = func(pid any) string {
				for _, row := range pyMustList(table).items {
					items := pyMustList(row).items
					if pyStr(items[0]) == pyStr(pid) {
						return pyMustString(items[1])
					}
				}
				phRaise(phUnbound, "Process owner changed.")
				return ""
			}
		}
		if responses, ok := object.Lookup("run"); ok {
			r.run = func(args []string, timeout float64) string {
				for _, item := range pyMustList(responses).items {
					response := pyMustObject(item)
					if !phEqualWords(phTestStrings(response.Get("argv")), args) {
						continue
					}
					if response.Get("timeout") == true {
						phRaise(phTimeout, "timed out")
					}
					if code, _ := pyInt(response.Get("rc")); code != 0 && code != 1 {
						phRaise(phUnbound, "Process discovery is unavailable.")
					}
					return pyMustString(response.Get("out"))
				}
				phRaise(phOSError, "[Errno 2] No such file or directory")
				return ""
			}
		}
	}
	globals, _ := pyFromGo(c.Globals)
	if object, ok := globals.(*pyObject); ok && c.Globals != nil {
		if table, ok := object.Lookup("arguments"); ok {
			r.arguments = func(pid int64) []string {
				for _, row := range pyMustList(table).items {
					items := pyMustList(row).items
					if pyStr(items[0]) == pyStr(pid) {
						if items[1] == "invalid" {
							phRaise(phValueError, "Process arguments exceed the maintenance limit.")
						}
						if items[1] == nil {
							break
						}
						return phTestStrings(items[1])
					}
				}
				phRaise(phOSError, "[Errno 2] No such file or directory")
				return nil
			}
		}
		if cwd, ok := object.Lookup("cwd"); ok {
			r.cwd = func(int64) string { return pyMustString(cwd) }
		}
	}
	return r
}

func phDispatch(t *testing.T, r *phReader, c phOracleCase, args []any) any {
	t.Helper()
	switch c.Call {
	case "shlex.quote":
		return phShlexQuote(pyMustString(args[0]))
	case "shlex.split":
		return phStringList(phShlexSplit(pyMustString(args[0])))
	case "os.path.normpath":
		return phNormpath(pyMustString(args[0]))
	case "os.path.realpath":
		return phRealpath(pyMustString(args[0]))
	case "os.path.expanduser":
		return phExpanduser(pyMustString(args[0]))
	case "str.splitlines":
		return phStringList(phSplitLines(pyMustString(args[0])))
	case "str.split":
		limit := int64(-1)
		if len(args) > 1 {
			limit, _ = pyInt(args[1])
		}
		return phStringList(phSplit(pyMustString(args[0]), int(limit)))
	case "str.strip":
		return phStrip(pyMustString(args[0]))
	case "pathlib":
		path := pyMustString(args[0])
		return pyListOf(phPath(path), phName(path), phParent(path), phStringList(phParents(path)), phSuffix(path))
	case "codex_resume_command":
		return phCodexResumeCommand(phTestStrings(args[0]), pyMustString(args[1]), args[2], phTestStrings(args[3]),
			phOptionalString(args[4]), r.isLinux, true)
	case "claude_resume_command":
		return phClaudeResumeCommand(phTestStrings(args[0]), pyMustString(args[1]), phTestStrings(args[2]), phOptionalString(args[3]))
	case "account_command":
		return phAccountCommand(pyMustString(args[0]), pyMustString(args[1]), pyMustString(args[2]))
	case "account_label_dir":
		return phAccountLabelDir(pyMustString(args[0]), pyMustString(args[1]))
	case "same_account":
		return phSameAccount(pyMustString(args[0]), pyMustString(args[1]), pyMustString(args[2]))
	case "account_root":
		return phMaintenanceAccountRoot(pyMustString(args[0]), pyMustString(args[1]))
	case "path_version_str":
		return phVersionValue(phPathVersion(pyMustString(args[0]), pyMustString(args[1])))
	case "install_root":
		return phNone(phInstallRoot(pyMustString(args[0]), pyMustString(args[1])))
	case "mcp_entries":
		var root *string
		if len(args) > 1 && args[1] != nil {
			text := pyMustString(args[1])
			root = &text
		}
		return phEntriesValue(append([]phMCPEntry{}, phMCPEntries(args[0], root)...))
	case "script_interpreter":
		return phNone(phScriptInterpreter(pyMustString(args[0])))
	case "mcp_server_process":
		return phMCPServerProcess(phTestStrings(args[0]), phEntriesOf(args[1]))
	case "notification_texts":
		return phStringList(phNotificationTexts(args[0]))
	case "notification_tag":
		return phNotificationTag(pyMustString(args[0]), pyMustString(args[1]))
	case "codex_in_flight":
		return phCodexInFlight(args[0])
	case "newer_installed":
		versions := phAgentVersions{running: pyGet(args[0], "running_version", nil), installed: pyGet(args[0], "installed_version", nil)}
		return phNewerInstalled(versions)
	case "pinned_codex_command":
		return phPinnedCodexCommand(pyMustString(args[0]), args[1])
	case "metadata":
		return r.metadata(pyMustString(args[0]), pyMustString(args[1]))
	case "codex_lifecycle":
		if value := phCodexLifecycle(args[0]); value != nil {
			return value
		}
		return nil
	case "provider":
		return phNone(r.provider(pyMustString(args[0])))
	case "stock_proxy_identity":
		return phNone(phStockProxyIdentity(args[0]))
	case "tail_evidence":
		lifecycle, context, revision := r.tailEvidence(pyMustString(args[0]), pyMustString(args[1]))
		return pyListOf(lifecycle, context, revision)
	case "subagent_work":
		return phSubagentWork(phOptionalString(args[0]), args[1])
	case "subagent_lifecycle":
		events := phSubagentLifecycle(pyMustString(args[0]), phTestStrings(args[1]))
		object := newPyObject()
		for _, id := range phTestStrings(args[1]) {
			object.Set(id, phStringList(events[id]))
		}
		return object
	case "background_shell_work":
		servers := func() ([]phMCPEntry, bool) { return nil, false }
		if c.Servers != nil {
			value, _ := pyFromGo(c.Servers)
			servers = func() ([]phMCPEntry, bool) { return phEntriesOf(value), true }
		}
		return r.backgroundShellWork(phPid(args[0]), servers)
	case "harness_status":
		return r.harnessStatus(phPid(args[0]), pyMustString(args[1]))
	case "background_agent_jobs":
		return r.backgroundAgentJobs(phPid(args[0]), pyMustString(args[1]))
	case "kernel_start":
		return r.kernelStart(args[0])
	case "recovery_owner":
		return r.recoveryOwner(pyMustString(args[0]), phPid(args[1]), pyMustString(args[2]), args[3], pyMustString(args[4]))
	case "configured_mcp_commands":
		return phEntriesValue(r.configuredMCPCommands(phPid(args[0]), pyMustString(args[1]), phTestStrings(args[2])))
	case "exact_claude_transcript":
		return r.exactClaudeTranscript(pyMustString(args[0]), phOptionalString(args[1]))
	case "exact_codex_transcript":
		return r.exactCodexTranscript(pyMustString(args[0]), phOptionalString(args[1]))
	case "worker_observation":
		return r.workerObservation(pyMustString(args[0]), pyMustString(args[1]))
	case "image_version":
		return phVersionValue(r.imageVersion(pyMustString(args[0]), pyMustString(args[1])))
	case "installed_update":
		return r.installedUpdate(phPid(args[0]), pyMustString(args[1]))
	}
	t.Fatalf("no native dispatch for %s", c.Call)
	return nil
}

func phWrite(t *testing.T, path string, data string, mode os.FileMode) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	return path
}

func phJSONLines(rows ...any) string {
	var builder strings.Builder
	for _, row := range rows {
		if text, ok := row.(string); ok {
			builder.WriteString(text + "\n")
			continue
		}
		data, _ := json.Marshal(row)
		builder.Write(data)
		builder.WriteString("\n")
	}
	return builder.String()
}

type phObject = map[string]any

// phOracleCases builds fixtures under home and the cases that read them.
func phOracleCases(t *testing.T, home string) []phOracleCase {
	var cases []phOracleCase
	add := func(call string, args ...any) { cases = append(cases, phOracleCase{Call: call, Args: args}) }

	for _, text := range []string{"", "plain", "a b", "it's", "x=1", "~/a", "a\tb", "émoji", "-flag", "@%+=:,./-_", "$HOME", "a\"b"} {
		add("shlex.quote", text)
	}
	for _, text := range []string{"a b c", "RELAY_CLAUDE_BIN=/x/y /usr/bin/relayd agent claude", "'a b' c", `"a \" b"`,
		`a\ b`, "'unterminated", `trailing\`, `"q\$x"`, "  ", "''", `a'b'"c"d`, `env -u X /bin/x`} {
		add("shlex.split", text)
	}
	for _, text := range []string{"", "/", "//", "///", "//a//b", "/a/./b/../c", "a/../..", "../a", "/..", "/a/b/", "./"} {
		add("os.path.normpath", text)
	}
	for _, text := range []string{"~", "~/x", "~nonexistent-relay-user/x", "x~", "~/"} {
		add("os.path.expanduser", text)
	}
	for _, text := range []string{"a\nb\r\nc\rd", "a\x1cb\x85c d", "trailing\n", "", "\n\n"} {
		add("str.splitlines", text)
	}
	add("str.split", "  12  34 56   comm with  spaces  ", 3)
	add("str.split", "a　b\x1fc", -1)
	add("str.strip", "　 x \x1c")
	for _, text := range []string{"/", "//a/b", "/a/b/c.jsonl", "a/b", ".", "", "/a/.jsonl", "/a/b.", "/a//b/./c/"} {
		add("pathlib", text)
	}

	// Resume commands: only reviewed launch options are replayed.
	context := phObject{"approval_policy": "never", "sandbox_policy": phObject{"type": "danger-full-access"},
		"cwd": "/work/dir", "model": "gpt-5.5", "effort": "high"}
	add("codex_resume_command", []string{"codex", "--profile", "p", "-m", "x", "--search", "-c", "model_provider=\"o\"", "resume", "abc"},
		"session-1", context, []string{"/bin/relayd", "agent", "codex"}, nil, true)
	add("codex_resume_command", []string{"codex", "--remote", "unix:///s"}, "session-1", context, []string{"/r"}, "unix:///s", true)
	add("codex_resume_command", []string{"codex", "--remote", "unix:///other"}, "session-1", context, []string{"/r"}, "unix:///s", true)
	add("codex_resume_command", []string{"codex", "prompt text"}, "session-1", context, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex", "-c", "evil=1"}, "session-1", context, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex", "--profile"}, "session-1", context, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "bad session", context, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "always", "sandbox_policy": "read-only", "cwd": "/w"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "on-request", "sandbox_policy": "read-only", "cwd": "rel"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "on-request",
		"sandbox_policy": phObject{"type": "workspace-write", "writable_roots": []string{"/a"}}, "cwd": "/w"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "on-request",
		"sandbox_policy": phObject{"type": "danger-full-access", "extra": 1}, "cwd": "/w"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "untrusted",
		"sandbox_policy": phObject{"type": "workspace-write"}, "cwd": "/w d", "model": "bad model", "effort": "", "reasoning_effort": "low"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "never", "sandbox_policy": "danger-full-access",
		"cwd": "/w\x01"}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", []any{}, []string{"/r"}, nil, true)
	add("codex_resume_command", []string{"codex"}, "s", phObject{"approval_policy": "never", "sandbox_policy": "danger-full-access",
		"cwd": "/" + strings.Repeat("d", 8200)}, []string{"/r"}, nil, true)
	add("claude_resume_command", []string{"claude", "--model", "opus", "--effort=high", "--resume", "old", "-c", "--verbose",
		"--allowedTools", "Bash"}, "session-2", []string{"/bin/relayd", "agent", "claude"}, "/home/u/.local/share/claude/versions/2.1.0")
	add("claude_resume_command", []string{"claude", "--model"}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude", "--model", "--verbose"}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude", "--model="}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude", "--resume=bad id"}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude", "--continue=x"}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude", "hello"}, "s", []string{"/r"}, nil)
	add("claude_resume_command", []string{"claude"}, "s", []string{"/r"}, "relative")
	add("claude_resume_command", []string{"claude", "--settings", "it's"}, "s", []string{"/r"}, "/a b")
	add("account_command", "RELAY_CLAUDE_BIN=/a /bin/relayd agent claude", "claude", "")
	add("account_command", "/bin/relayd agent codex", "codex", "/home/x/.codex-2")
	add("account_command", "relayd agent codex", "codex", "")
	add("account_command", "/bin/relayd", "codex", "/a/../b")
	add("account_command", "'unterminated", "codex", "")
	add("account_label_dir", "", "claude")
	add("account_label_dir", home+"/.claude-two", "claude")
	add("account_label_dir", home+"/.codex", "codex")
	add("account_label_dir", "/elsewhere/acct", "codex")
	add("same_account", "claude", "", home+"/.claude")
	add("same_account", "codex", "", home+"/.codex")
	add("account_root", "codex", "")
	for _, path := range []string{"/x/claude/versions/2.1.300", "/x/codex/1.2.3-alpha/bin/codex", "/x/node/20.1.0/bin/node",
		"/x/versions/10.0.0/a", "/x/claude/1.2", "relative/codex/0.1.0"} {
		add("path_version_str", path, "claude")
		add("path_version_str", path, "codex")
	}
	for _, path := range []string{"/s/claude/versions/2.1.0", "/s/claude/versions/.nfs00ab", "/n/lib/node_modules/@openai/codex/vendor/x/codex",
		"/h/.local/share/relay/bin/native-codex-0.5/codex", "/h/.local/share/relay/bin/native-codex/codex", "/usr/bin/codex"} {
		add("install_root", path, "claude")
		add("install_root", path, "codex")
	}
	add("mcp_entries", phObject{"mcpServers": phObject{"a": phObject{"command": "~/bin/s", "args": []string{"${CLAUDE_PLUGIN_ROOT}/x"}},
		"b": phObject{"url": "http://x"}, "c": "bad"}}, "/plugins/p")
	add("mcp_entries", phObject{"mcpServers": phObject{"a": phObject{"command": "s", "args": []any{1}}}}, nil)
	add("mcp_entries", phObject{"mcpServers": []any{}}, nil)
	add("mcp_entries", []any{}, nil)
	add("mcp_entries", phObject{"mcpServers": nil}, nil)
	add("mcp_entries", phObject{"mcpServers": phObject{"a": phObject{"command": "s", "args": "x"}}}, nil)
	script := phWrite(t, filepath.Join(home, "scripts", "server.py"), "#!/usr/bin/env -S python3.12 -u\nprint(1)\n", 0o755)
	direct := phWrite(t, filepath.Join(home, "scripts", "direct.js"), "#!/usr/local/bin/node --flag\n", 0o755)
	plain := phWrite(t, filepath.Join(home, "scripts", "plain"), "no shebang\n", 0o755)
	empty := phWrite(t, filepath.Join(home, "scripts", "empty"), "#!\n", 0o755)
	for _, path := range []string{script, direct, plain, empty, filepath.Join(home, "scripts"), filepath.Join(home, "missing")} {
		add("script_interpreter", path)
	}
	entries := []any{[]any{script, []string{"--stdio"}}, []any{"uvx", []string{"tool"}}, []any{"/opt/srv", []string{}}}
	for _, argv := range [][]string{{"python3.12", script, "--stdio"}, {"/usr/bin/python3.12", script, "--stdio"}, {"python3", script, "--stdio"},
		{"uvx", "tool"}, {"/x/uvx", "tool"}, {"/opt/srv"}, {"claude", "x"}, {}, {"node", direct}, {"/x/Codex.exe"}} {
		add("mcp_server_process", argv, entries)
	}
	add("notification_texts", phObject{"type": "user", "origin": phObject{"kind": "task-notification"}, "message": phObject{"content": "x"}})
	add("notification_texts", phObject{"type": "user", "origin": phObject{"kind": "task-notification"},
		"message": phObject{"content": []any{phObject{"type": "text", "text": "a"}, phObject{"type": "image"}, "s", phObject{"type": "text", "text": 3}}}})
	add("notification_texts", phObject{"type": "user", "origin": nil, "message": phObject{"content": "x"}})
	add("notification_texts", phObject{"type": "assistant", "origin": "bad"})
	add("notification_texts", phObject{"type": "user", "origin": "bad"})
	add("notification_texts", phObject{"type": "user", "origin": phObject{"kind": "task-notification"}, "message": []any{1}})
	add("notification_tag", "task-id", "<task-id>  ab </task-id>")
	add("notification_tag", "status", "<status></status><status>x\ny</status>")
	add("notification_tag", "status", "<status>"+strings.Repeat("x", 129)+"</status>")
	for _, row := range []any{phObject{"type": "response_item", "payload": phObject{}}, phObject{"type": "event_msg", "payload": phObject{"type": "agent_message"}},
		phObject{"type": "event_msg", "payload": phObject{"type": "token_count"}}, phObject{"type": "event_msg", "payload": []any{}},
		phObject{"type": "event_msg", "payload": phObject{"type": []any{}}}, phObject{"type": "response_item"}} {
		add("codex_in_flight", row)
	}
	add("newer_installed", phObject{"running_version": "2.1.9", "installed_version": "2.1.10"})
	add("newer_installed", phObject{"running_version": "2.1.10", "installed_version": "2.1.10"})
	add("newer_installed", phObject{"running_version": nil, "installed_version": "2.1.10"})
	add("pinned_codex_command", "resume", "/a b/codex")
	add("pinned_codex_command", "resume", nil)
	add("pinned_codex_command", "resume", "rel")

	// Discovery: transcript metadata and Codex lifecycle.
	uuid := "0b5c1c6a-1111-4222-8333-444455556666"
	claude := phWrite(t, filepath.Join(home, "t", "claude.jsonl"), phJSONLines(phObject{"isSidechain": true, "sessionId": "x"},
		"not json", phObject{"type": "user", "sessionId": uuid}), 0o600)
	codexMeta := phWrite(t, filepath.Join(home, "t", "codex.jsonl"), phJSONLines(phObject{"type": "session_meta", "payload": phObject{"id": uuid}}), 0o600)
	codexSub := phWrite(t, filepath.Join(home, "t", "codex-sub.jsonl"), phJSONLines(phObject{"type": "session_meta", "payload": phObject{"id": uuid, "source": phObject{}}}), 0o600)
	codexBad := phWrite(t, filepath.Join(home, "t", "codex-bad.jsonl"), phJSONLines(phObject{"type": "session_meta", "payload": []any{}}), 0o600)
	shared := phWrite(t, filepath.Join(home, "t", "shared.jsonl"), phJSONLines(phObject{"sessionId": uuid}), 0o644|0o020)
	listRow := phWrite(t, filepath.Join(home, "t", "list.jsonl"), phJSONLines([]any{1}), 0o600)
	link := filepath.Join(home, "t", "link.jsonl")
	_ = os.Symlink(claude, link)
	for _, path := range []string{claude, codexMeta, codexSub, codexBad, shared, listRow, link, filepath.Join(home, "t", "missing.jsonl")} {
		add("metadata", path, "claude")
		add("metadata", path, "codex")
	}
	for _, row := range []any{
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05.123Z", "payload": phObject{"type": "task_complete"}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": "turn_aborted"}},
		phObject{"type": "event_msg", "timestamp": "2026-1-2T3:4:5z", "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": "2026-02-30T03:04:05Z", "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": "2999-01-02T03:04:05Z", "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:60Z", "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05.1234567Z", "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": 5, "payload": phObject{"type": "task_started"}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": []any{}}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": "other"}},
		phObject{"type": "response_item", "payload": phObject{"type": "task_started"}},
	} {
		add("codex_lifecycle", row)
	}
	for _, name := range []string{"claude", "/usr/bin/Codex.EXE", "node", "codex/", "/x/y/claude.exe", "/missing/2.1.0"} {
		add("provider", name)
	}
	revision := strings.Repeat("a", 64)
	proxy := phObject{"proxy_pid": 2, "proxy_start": 3, "control_device": 4, "control_inode": 5, "connection": 6, "selection": 7, "control_socket": "/s"}
	endpoint := phObject{"socket": "/e", "daemon_pid": 9, "daemon_start": 10}
	add("stock_proxy_identity", phObject{"source": "stock_app_server_proxy", "stock_proxy": proxy, "native_endpoint": endpoint, "revision": revision})
	add("stock_proxy_identity", phObject{"source": "stock_app_server_proxy", "stock_proxy": proxy, "native_endpoint": []any{}, "revision": revision})
	add("stock_proxy_identity", phObject{"source": "stock_app_server_proxy", "stock_proxy": "x", "native_endpoint": endpoint})
	add("stock_proxy_identity", phObject{"source": "stock_app_server_proxy", "stock_proxy": proxy, "native_endpoint": endpoint, "revision": 5})
	add("stock_proxy_identity", phObject{"source": "stock_app_server_proxy", "stock_proxy": proxy, "native_endpoint": phObject{"socket": "/e", "daemon_pid": true, "daemon_start": 10}, "revision": revision})
	add("stock_proxy_identity", phObject{"source": "other"})

	// Tail evidence for both providers.
	tails := map[string]string{
		"claude-quiet.jsonl": phJSONLines(phObject{"type": "user", "message": phObject{"content": "hi"}},
			phObject{"type": "assistant", "message": phObject{"stop_reason": "end_turn"}}, "", "{bad"),
		"claude-active.jsonl": phJSONLines(phObject{"type": "assistant", "message": phObject{"stop_reason": "tool_use"}},
			phObject{"type": "assistant", "isSidechain": true, "message": phObject{"stop_reason": "end_turn"}}),
		"claude-duration.jsonl": phJSONLines(phObject{"type": "user", "message": phObject{"content": []any{}}},
			phObject{"type": "system", "subtype": "turn_duration"}, phObject{"type": "user", "message": "text"}),
		"claude-list.jsonl": phJSONLines([]any{1}),
		"codex.jsonl": phJSONLines(phObject{"type": "turn_context", "payload": phObject{"cwd": "/w", "approval_policy": "never"}},
			phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": "task_complete"}}),
		"codex-work.jsonl": phJSONLines(phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": "task_complete"}},
			phObject{"type": "response_item", "payload": phObject{"type": "message"}}),
	}
	for name, content := range tails {
		path := phWrite(t, filepath.Join(home, "tails", name), content, 0o600)
		add("tail_evidence", path, "claude")
		add("tail_evidence", path, "codex")
	}
	fresh := phWrite(t, filepath.Join(home, "tails", "fresh.jsonl"), tails["codex.jsonl"], 0o600)
	now := time.Now()
	_ = os.Chtimes(fresh, now, now)
	add("tail_evidence", fresh, "codex")
	add("tail_evidence", phWrite(t, filepath.Join(home, "tails", "shared.jsonl"), "{}\n", 0o664), "claude")
	big := phWrite(t, filepath.Join(home, "tails", "big.jsonl"), strings.Repeat("x", 5<<20)+"\n"+phJSONLines(
		phObject{"type": "assistant", "message": phObject{"stop_reason": "end_turn"}}), 0o600)
	add("tail_evidence", big, "claude")

	// Subagent lifecycle beside a main transcript.
	session := "5d0b8a4e-1111-4222-8333-444455556666"
	project := filepath.Join(home, ".claude", "projects", "p")
	main := phWrite(t, filepath.Join(project, session+".jsonl"), phJSONLines(
		phObject{"type": "assistant", "message": phObject{"content": []any{phObject{"type": "tool_use", "name": "Agent", "id": "call-1"},
			phObject{"type": "tool_use", "name": "TaskStop", "id": "stop-1", "input": phObject{"task_id": "a2"}}}}},
		phObject{"type": "user", "toolUseResult": phObject{"agentId": "a1", "status": "async_launched"},
			"message": phObject{"content": []any{phObject{"type": "tool_result", "tool_use_id": "call-1"}}}},
		phObject{"type": "user", "toolUseResult": phObject{"agentId": "a2", "status": "teammate_spawned"},
			"message": phObject{"content": []any{phObject{"type": "tool_result", "tool_use_id": "x"}}}},
		phObject{"type": "user", "toolUseResult": phObject{"task_id": "a2"},
			"message": phObject{"content": []any{phObject{"type": "tool_result", "tool_use_id": "stop-1"}}}},
		phObject{"type": "user", "origin": phObject{"kind": "task-notification"},
			"message": phObject{"content": "<task-notification><task-id>a3</task-id><status>weird</status></task-notification>"}},
	), 0o600)
	for _, id := range []string{"a1", "a2", "a3"} {
		phWrite(t, filepath.Join(project, session, "subagents", "agent-"+id+".jsonl"), "{}\n", 0o600)
	}
	add("subagent_lifecycle", main, []string{"a1", "a2", "a3", "a4"})
	add("subagent_work", main, session)
	add("subagent_work", main, 5)
	add("subagent_work", nil, session)
	add("subagent_work", claude, session)
	done := "6e1c9b5f-1111-4222-8333-444455556666"
	doneMain := phWrite(t, filepath.Join(project, done+".jsonl"), phJSONLines(
		phObject{"type": "assistant", "message": phObject{"content": []any{phObject{"type": "tool_use", "name": "Task", "id": "c"}}}},
		phObject{"type": "user", "toolUseResult": phObject{"agentId": "b1", "status": "completed"},
			"message": phObject{"content": []any{phObject{"type": "tool_result", "tool_use_id": "c"}}}}), 0o600)
	phWrite(t, filepath.Join(project, done, "subagents", "agent-b1.jsonl"), "{}\n", 0o600)
	add("subagent_work", doneMain, done)
	none := "7f2d0c60-1111-4222-8333-444455556666"
	noneMain := phWrite(t, filepath.Join(project, none+".jsonl"), "{}\n", 0o600)
	add("subagent_work", noneMain, none)
	badMessage := "8a3e1d71-1111-4222-8333-444455556666"
	badMain := phWrite(t, filepath.Join(project, badMessage+".jsonl"), phJSONLines(
		phObject{"type": "user", "message": []any{"agentId"}}), 0o600)
	phWrite(t, filepath.Join(project, badMessage, "subagents", "agent-z.jsonl"), "{}\n", 0o600)
	add("subagent_work", badMain, badMessage)

	// Exact transcript lookup by authenticated session.
	add("exact_claude_transcript", session, filepath.Join(home, ".claude"))
	add("exact_claude_transcript", "bad id", filepath.Join(home, ".claude"))
	add("exact_claude_transcript", uuid, filepath.Join(home, ".claude"))
	codexHome := filepath.Join(home, ".codex")
	phWrite(t, filepath.Join(codexHome, "sessions", "2026", "01", "rollout-x-"+uuid+".jsonl"), phJSONLines(
		phObject{"type": "session_meta", "payload": phObject{"id": uuid}}), 0o600)
	phWrite(t, filepath.Join(codexHome, "sessions", ".hidden", "rollout-y-"+uuid+".jsonl"), phJSONLines(
		phObject{"type": "session_meta", "payload": phObject{"id": uuid}}), 0o600)
	add("exact_codex_transcript", uuid, codexHome)
	add("exact_codex_transcript", session, codexHome)

	// Process observations through a fixture reader.
	inventory := []any{[]any{100, 1, "relayd"}, []any{200, 100, "bash"}, []any{300, 200, "claude"},
		[]any{310, 300, "node"}, []any{311, 310, "python3"}, []any{320, 300, "uvx"}, []any{330, 320, "zsh"}, []any{400, 1, "claude"}}
	shellCase := phOracleCase{Call: "background_shell_work", Args: []any{300}, Reader: phObject{"inventory": inventory}}
	cases = append(cases, shellCase)
	quietInventory := []any{[]any{200, 100, "bash"}, []any{300, 200, "claude"}, []any{310, 300, "node"}, []any{311, 310, "python3"}}
	for _, servers := range []any{nil, []any{[]any{"node", []string{"server.js"}}}, []any{[]any{"node", []string{"other.js"}}}} {
		cases = append(cases, phOracleCase{Call: "background_shell_work", Args: []any{300}, Servers: servers,
			Reader:  phObject{"inventory": quietInventory},
			Globals: phObject{"arguments": []any{[]any{310, []string{"node", "server.js"}}}}})
	}
	cases = append(cases, phOracleCase{Call: "background_shell_work", Args: []any{300}, Servers: []any{},
		Reader: phObject{"inventory": quietInventory}, Globals: phObject{"arguments": []any{[]any{310, "invalid"}}}})
	cases = append(cases, phOracleCase{Call: "background_shell_work", Args: []any{300},
		Reader: phObject{"inventory": []any{[]any{300, 200, "claude"}, []any{310, 999, "bash"}}}})
	loop := []any{[]any{300, 200, "claude"}, []any{310, 311, "node"}, []any{311, 310, "node"}}
	cases = append(cases, phOracleCase{Call: "background_shell_work", Args: []any{300}, Reader: phObject{"inventory": loop}})

	sessions := filepath.Join(home, ".claude", "sessions")
	phWrite(t, filepath.Join(sessions, "300.json"), `{"pid":300,"procStart":"777","status":"busy","kind":"interactive"}`, 0o600)
	phWrite(t, filepath.Join(sessions, "500.json"), `{"pid":500,"procStart":555,"status":"idle","kind":"bg"}`, 0o600)
	phWrite(t, filepath.Join(sessions, "510.json"), `{"pid":510,"procStart":510,"kind":"bg"}`, 0o600)
	phWrite(t, filepath.Join(sessions, "520.json"), `{"pid":520,"procStart":520,"kind":"bg"}`, 0o600)
	phWrite(t, filepath.Join(sessions, "530.json"), `{"pid":true,"procStart":1,"kind":"bg"}`, 0o600)
	harnessReader := phObject{"identity": []any{[]any{300, "linux:777"}, []any{500, "linux:555"}, []any{510, "linux:1"}, []any{520, "linux:520"}},
		"inventory": []any{[]any{300, 200, "claude"}, []any{500, 1, "claude"}, []any{510, 1, "claude"}, []any{520, 300, "claude"}}}
	cases = append(cases, phOracleCase{Call: "harness_status", Args: []any{300, ""}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "harness_status", Args: []any{500, ""}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "harness_status", Args: []any{301, ""}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "background_agent_jobs", Args: []any{300, ""}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "background_agent_jobs", Args: []any{300, filepath.Join(home, "missing-account")}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "kernel_start", Args: []any{300}, Reader: harnessReader})
	cases = append(cases, phOracleCase{Call: "kernel_start", Args: []any{"x"}, Reader: harnessReader})
	return cases
}

// TestPaneHealthNativeProbeMatchesPythonOracle evaluates the same fixtures
// against captured canonical outputs and requires identical JSON.
func TestPaneHealthNativeProbeMatchesPythonOracle(t *testing.T) {
	home := t.TempDir()
	phCompareProbeReference(t, home)
}

func TestPaneHealthProbeReferencePhysicalHome(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	phCompareProbeReference(t, home)
}

func phCompareProbeReference(t *testing.T, home string) {
	t.Helper()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, ".local", "state"))
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	t.Setenv("CODEX_HOME", "")
	os.Unsetenv("CODEX_HOME")
	cases := phOracleCases(t, home)
	expected := phRunOracle(t, cases)
	mismatches := 0
	for i, c := range cases {
		actual := phEvaluate(t, c)
		want := expected[i]
		if !phSameOutcome(want, actual) {
			mismatches++
			data, _ := json.Marshal(c)
			t.Errorf("case %d %s\n  args   %.400s\n  python %s\n  go     %s", i, c.Call, data, phDescribe(want), phDescribe(actual))
		}
	}
	t.Logf("%d oracle cases on %s, %d mismatches", len(cases), runtime.GOOS, mismatches)
}

func phDescribe(result phOracleResult) string {
	if result.Value != nil {
		return *result.Value
	}
	return fmt.Sprintf("raised %s: %s", result.Raised, result.Message)
}

// phSameOutcome compares values byte for byte and exceptions by class. Our
// own raise messages must match too; OSError and JSON/codec messages are
// formatted by Python's runtime and are never surfaced by the controller.
func phSameOutcome(want, got phOracleResult) bool {
	if (want.Value == nil) != (got.Value == nil) {
		return false
	}
	if want.Value != nil {
		return *want.Value == *got.Value
	}
	if want.Raised != got.Raised {
		return false
	}
	generic := got.Raised == "OSError" || got.Raised == "TypeError" || got.Raised == "AttributeError" ||
		got.Raised == "KeyError" || got.Raised == "IndexError" || got.Raised == "Timeout" ||
		got.Message == "Expecting value" || strings.HasPrefix(got.Message, "'utf-8' codec")
	return generic || want.Message == got.Message
}

func TestProbeReferenceComparatorRejectsChangedValuesAndExceptions(t *testing.T) {
	a, b := `{"bound":true}`, `{"bound":false}`
	for _, pair := range [][2]phOracleResult{
		{{Value: &a}, {Value: &b}},
		{{Value: &a}, {Raised: "ValueError", Message: "bad"}},
		{{Raised: "ValueError", Message: "bad"}, {Raised: "TypeError", Message: "bad"}},
		{{Raised: "ValueError", Message: "bad"}, {Raised: "ValueError", Message: "other"}},
	} {
		if phSameOutcome(pair[0], pair[1]) {
			t.Fatal("changed probe primary result was hidden")
		}
	}
	if !phSameOutcome(phOracleResult{Value: &a}, phOracleResult{Value: &a}) {
		t.Fatal("equal probe values rejected")
	}
}
