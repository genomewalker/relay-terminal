package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const phTestPane = "a1b2c3d4-0000-4000-8000-000000000001"

var phUUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// phScriptedReader is a reader whose process observations are fixtures and
// whose daemon replies come from a table keyed by the subcommand.
func phScriptedReader(replies map[string][]string) *phReader {
	r := newPHReader(context.Background())
	r.isLinux = true
	calls := map[string]int{}
	r.run = func(args []string, timeout float64) string {
		name := args[1]
		values, ok := replies[name]
		if !ok {
			phRaise(phOSError, "No such file or directory")
		}
		index := calls[name]
		calls[name]++
		if index >= len(values) {
			index = len(values) - 1
		}
		return values[index]
	}
	r.rootForPane = func(string) int64 { return 100 }
	r.identity = func(pid any) string { return "linux:" + pyStr(pid) + "000" }
	return r
}

func phRaised(t *testing.T, body func()) *phException {
	t.Helper()
	var raised *phException
	func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				raised = phExceptionOf(recovered)
				if raised == nil {
					panic(recovered)
				}
			}
		}()
		body()
	}()
	return raised
}

func TestPaneHealthInspectShellOwnerFences(t *testing.T) {
	valid := `{"version": 1, "provider": "shell", "pane_id": "` + phTestPane + `", "process_id": 100, "shell_pid": 100, "process_start": 55, "shell_start": 55}`
	r := phScriptedReader(map[string][]string{"prompt-owner-binding": {valid}})
	proof := r.inspect(phTestPane, "/relayd")
	if got := string(pyCompact(proof)); got != `{"installed_update":false,"owner":{"pane_id":"`+phTestPane+`","process_id":100,"process_start":55,"provider":"shell","shell_pid":100,"shell_start":55,"version":1},"pane_id":"`+phTestPane+`","process_id":100,"process_start":55,"provider":"shell","version":1}` {
		t.Fatalf("shell proof = %s", got)
	}
	invalid := map[string]string{
		"pane":            strings.Replace(valid, phTestPane, "other", 1),
		"process":         strings.Replace(valid, `"process_id": 100`, `"process_id": 101`, 1),
		"shell":           strings.Replace(valid, `"shell_pid": 100`, `"shell_pid": 101`, 1),
		"bool start":      strings.Replace(valid, `"process_start": 55, "shell_start": 55`, `"process_start": true, "shell_start": true`, 1),
		"zero start":      strings.Replace(valid, `"process_start": 55, "shell_start": 55`, `"process_start": 0, "shell_start": 0`, 1),
		"float start":     strings.Replace(valid, `"process_start": 55, "shell_start": 55`, `"process_start": 55.0, "shell_start": 55.0`, 1),
		"different shell": strings.Replace(valid, `"shell_start": 55`, `"shell_start": 56`, 1),
	}
	for name, owner := range invalid {
		r := phScriptedReader(map[string][]string{"prompt-owner-binding": {owner}})
		if raised := phRaised(t, func() { r.inspect(phTestPane, "/relayd") }); raised == nil || raised.msg != "The native shell owner is invalid." {
			t.Fatalf("%s: raised %+v", name, raised)
		}
	}
	changed := phScriptedReader(map[string][]string{"prompt-owner-binding": {valid, strings.Replace(valid, `"version": 1`, `"version": 2`, 1)}})
	if raised := phRaised(t, func() { changed.inspect(phTestPane, "/relayd") }); raised == nil || raised.msg != "The native shell owner changed during inspection." {
		t.Fatalf("changed owner: %+v", raised)
	}
	moved := phScriptedReader(map[string][]string{"prompt-owner-binding": {valid}})
	roots := 0
	moved.rootForPane = func(string) int64 { roots++; return int64(99 + roots) }
	if raised := phRaised(t, func() { moved.inspect(phTestPane, "/relayd") }); raised == nil || raised.msg != "The native shell owner changed during inspection." {
		t.Fatalf("moved root: %+v", raised)
	}
	restarted := phScriptedReader(map[string][]string{"prompt-owner-binding": {valid}})
	starts := 0
	restarted.identity = func(any) string { starts++; return "linux:" + pyStr(int64(starts)) }
	if raised := phRaised(t, func() { restarted.inspect(phTestPane, "/relayd") }); raised == nil || raised.msg != "The native shell owner changed during inspection." {
		t.Fatalf("restarted shell: %+v", raised)
	}
	if raised := phRaised(t, func() { r.inspect("../pane", "/relayd") }); raised == nil || raised.msg != "Invalid pane identity." {
		t.Fatalf("pane identity: %+v", raised)
	}
}

func TestPaneHealthInspectAgentIdentityFences(t *testing.T) {
	owner := `{"version": 1, "provider": "claude", "pane_id": "` + phTestPane + `", "process_id": 200, "process_start": 77}`
	cases := []struct {
		name, owner, kernel, want string
	}{
		{"bool kernel start", owner, `{"process_start": true}`, "Native process identity is unavailable."},
		{"zero kernel start", owner, `{"process_start": 0}`, "Native process identity is unavailable."},
		{"text kernel start", owner, `{"process_start": "77"}`, "Native process identity is unavailable."},
		{"owner provider", strings.Replace(owner, `"claude"`, `"codex"`, 1), `{"process_start": 77}`, "The foreground prompt owner changed."},
		{"owner pid", strings.Replace(owner, `"process_id": 200`, `"process_id": 201`, 1), `{"process_start": 77}`, "The foreground prompt owner changed."},
		{"owner start", owner, `{"process_start": 78}`, "The foreground prompt owner changed."},
	}
	for _, c := range cases {
		r := phScriptedReader(map[string][]string{"prompt-owner-binding": {c.owner}, "agent-process-identity": {c.kernel}})
		r.agent = func(int64, string, string) (int64, string) { return 200, "claude" }
		r.accountOverride = func(int64, string) string { return "" }
		r.binding = func(string, string, int64, string) *pyObject {
			t.Fatalf("%s: binding read after a failed fence", c.name)
			return nil
		}
		if raised := phRaised(t, func() { r.inspect(phTestPane, "/relayd") }); raised == nil || raised.msg != c.want {
			t.Fatalf("%s: raised %+v", c.name, raised)
		}
	}
}

func phWriteManifest(t *testing.T, state string, record string) {
	t.Helper()
	phWrite(t, filepath.Join(state, "relay", "workers", phTestPane+".json"), record, 0o600)
}

func TestPaneHealthRecoveryOwnerFences(t *testing.T) {
	state := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	valid := `{"session_id": "` + phTestPane + `", "state": "running", "worker_pid": 10, "shell_pid": 20, "worker_start_time": 10000, "node_boot_id": "boot"}`
	reader := func() *phReader {
		r := phScriptedReader(nil)
		r.inventory = func() *phProcesses {
			processes := &phProcesses{rows: map[int64]phProcess{}}
			processes.set(10, phProcess{parent: 1, name: "relayd"})
			processes.set(20, phProcess{parent: 10, name: "bash"})
			processes.set(30, phProcess{parent: 20, name: "claude"})
			return processes
		}
		return r
	}
	phWriteManifest(t, state, valid)
	proof := reader().recoveryOwner(phTestPane, 30, "claude", int64(30000), "s")
	if got := string(pyEncode(proof, pyEncodeOptions{itemSep: ", ", keySep: ": "})); !strings.Contains(got, `"shell_start": 20000, "provider": "claude", "process_id": 30, "process_start": 30000, "session_id": "s", "transcript_identity": "input:`) ||
		!strings.HasSuffix(got, `, "input_only": true}`) {
		t.Fatalf("recovery proof = %s", got)
	}
	identity, _ := proof.Get("transcript_identity").(string)
	if len(identity) != len("input:")+48 {
		t.Fatalf("transcript identity = %q", identity)
	}
	if raised := phRaised(t, func() { reader().recoveryOwner(phTestPane, 30, "claude", int64(30001), "s") }); raised == nil || raised.msg != "The recovery process incarnation changed." {
		t.Fatalf("agent start: %+v", raised)
	}
	for name, record := range map[string]string{
		"stopped":      strings.Replace(valid, `"running"`, `"stopped"`, 1),
		"other pane":   strings.Replace(valid, phTestPane, "a1b2c3d4-0000-4000-8000-000000000002", 1),
		"worker start": strings.Replace(valid, `"worker_start_time": 10000`, `"worker_start_time": 10001`, 1),
	} {
		phWriteManifest(t, state, record)
		if raised := phRaised(t, func() { reader().recoveryOwner(phTestPane, 30, "claude", int64(30000), "s") }); raised == nil || raised.msg != "The recovery process incarnation changed." {
			t.Fatalf("%s: %+v", name, raised)
		}
	}
	phWriteManifest(t, state, strings.Replace(valid, `"shell_pid": 20`, `"shell_pid": 40`, 1))
	if raised := phRaised(t, func() { reader().recoveryOwner(phTestPane, 30, "claude", int64(30000), "s") }); raised == nil || raised.msg != "The recovery process left its pane." {
		t.Fatalf("left pane: %+v", raised)
	}
	// The agent still descends from the worker, but no longer from the shell.
	phWriteManifest(t, state, valid)
	escaped := reader()
	escaped.inventory = func() *phProcesses {
		processes := &phProcesses{rows: map[int64]phProcess{}}
		processes.set(10, phProcess{parent: 1, name: "relayd"})
		processes.set(20, phProcess{parent: 10, name: "bash"})
		processes.set(30, phProcess{parent: 10, name: "claude"})
		return processes
	}
	if raised := phRaised(t, func() { escaped.recoveryOwner(phTestPane, 30, "claude", int64(30000), "s") }); raised == nil || raised.msg != "The recovery process left its pane." {
		t.Fatalf("agent outside shell: %+v", raised)
	}
	phWriteManifest(t, state, strings.Replace(valid, `"node_boot_id": "boot"`, `"node_boot_id": ""`, 1))
	if raised := phRaised(t, func() { reader().recoveryOwner(phTestPane, 30, "claude", int64(30000), "s") }); raised == nil || raised.msg != "The worker boot identity is unavailable." {
		t.Fatalf("boot: %+v", raised)
	}
}

func TestPaneHealthWorkerObservationModes(t *testing.T) {
	state := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	// Off Linux the worker incarnation is the native start time of a real
	// process: this test's own. Linux compares /proc images, covered by the
	// live probe test.
	pid := int64(os.Getpid())
	start := int64(0)
	if !phPlatformLinux {
		start = newPHReader(context.Background()).kernelStart(pid)
	}
	worker, begun := pyStr(pid), pyStr(start)
	phWriteManifest(t, state, `{"worker_pid": `+worker+`, "worker_start_time": `+begun+`}`)
	observe := func(row string) string {
		r := phScriptedReader(map[string][]string{"upgrade-workers": {row}})
		r.isLinux = false
		r.identity = newPHReader(context.Background()).identity
		return string(pyCompact(r.workerObservation(phTestPane, "/relayd")))
	}
	unverified := `{"unavailable":"The exact running worker could not be verified.","update_state":"unverified","upgrade_mode":"unavailable"}`
	rows := map[string]string{
		`[{"session_id": "` + phTestPane + `", "result": "odd", "message": "` + strings.Repeat("é", 200) + `"}]`: `{"unavailable":"` + strings.Repeat("é", 160) + `","update_state":"unverified","upgrade_mode":"unavailable","worker_pid":null}`,
		`[{"session_id": "` + phTestPane + `", "result": "odd"}]`:                                                `{"unavailable":"The worker is unavailable.","update_state":"unverified","upgrade_mode":"unavailable","worker_pid":null}`,
		`[{"session_id": "` + phTestPane + `", "result": "current", "worker_pid": 1}]`:                           unverified,
		`[{"session_id": "other", "result": "current", "worker_pid": ` + worker + `}]`:                           unverified,
		`[]`: unverified,
		`[{"session_id": "` + phTestPane + `", "result": "current", "worker_pid": ` + worker + `}, {}]`: unverified,
	}
	if !phPlatformLinux {
		rows[`[{"session_id": "`+phTestPane+`", "result": "current", "worker_pid": `+worker+`}]`] = `{"update_state":"current","upgrade_mode":"in_place","worker_pid":` + worker + `,"worker_start":` + begun + `}`
		rows[`[{"session_id": "`+phTestPane+`", "result": "would_upgrade", "worker_pid": `+worker+`}]`] = `{"unavailable":"The loaded worker image has not been compared on this host.","update_state":"unverified","upgrade_mode":"in_place","worker_pid":` + worker + `,"worker_start":` + begun + `}`
		rows[`[{"session_id": "`+phTestPane+`", "result": "legacy", "worker_pid": `+worker+`}]`] = `{"update_state":"update_required","upgrade_mode":"restart_required","worker_pid":` + worker + `,"worker_start":` + begun + `}`
	}
	for row, want := range rows {
		if got := observe(row); got != want {
			t.Errorf("row %.80s\n got  %s\n want %s", row, got, want)
		}
	}
	phWriteManifest(t, state, `{"worker_pid": `+worker+`, "worker_start_time": `+pyStr(start+1)+`}`)
	if got := observe(`[{"session_id": "` + phTestPane + `", "result": "current", "worker_pid": ` + worker + `}]`); got != unverified {
		t.Fatalf("stale worker start: %s", got)
	}
}

func TestPaneHealthContextObservation(t *testing.T) {
	directory := t.TempDir()
	daemon := filepath.Join(directory, "relayd")
	reply := filepath.Join(directory, "reply")
	argv := filepath.Join(directory, "argv")
	phWrite(t, daemon, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \""+argv+"\"\ncat > \""+argv+".in\"\ncat \""+reply+"\"\nexit \"$(cat \""+reply+".rc\" 2>/dev/null || echo 0)\"\n", 0o700)
	observe := func(value string, rc string) string {
		phWrite(t, reply, value, 0o600)
		phWrite(t, reply+".rc", rc, 0o600)
		return string(pyCompact(newPHReader(context.Background()).contextObservation(phTestPane, daemon)))
	}
	unavailable := `{"enabled":false,"state":"unavailable","supported":false,"unavailable":"Native context status could not be verified."}`
	for _, c := range []struct{ reply, rc, want string }{
		{`{"v": 1, "enabled": true, "state": "idle", "generation": 3, "lifecycle": "x", "refresh_capability": null, "other": 1}`, "0",
			`{"enabled":true,"generation":3,"lifecycle":"x","refresh_capability":null,"state":"idle","supported":true}`},
		{`{"v": 1, "enabled": false}`, "0", `{"enabled":false,"state":"unavailable","supported":true}`},
		{`{"v": 1, "enabled": 1}`, "0", `{"enabled":false,"state":"unsupported_worker","supported":false}`},
		{`{"v": 2, "enabled": true}`, "0", `{"enabled":false,"state":"unsupported_worker","supported":false}`},
		{`{"v": true, "enabled": true}`, "0", `{"enabled":true,"state":"unavailable","supported":true}`},
		{`{"v": 1, "enabled": true}`, "1", unavailable},
		{`[1]`, "0", unavailable},
		{`not json`, "0", unavailable},
	} {
		if got := observe(c.reply, c.rc); got != c.want {
			t.Errorf("reply %s rc %s\n got  %s\n want %s", c.reply, c.rc, got, c.want)
		}
	}
	args, _ := os.ReadFile(argv)
	lines := strings.Split(strings.TrimSpace(string(args)), "\n")
	if len(lines) != 3 || lines[0] != "rotation-supervisor-rpc" || lines[1] != phTestPane || !phUUIDPattern.MatchString(lines[2]) {
		t.Fatalf("argv = %q", lines)
	}
	if input, _ := os.ReadFile(argv + ".in"); string(input) != `{"v": 1, "operation": "status"}` {
		t.Fatalf("stdin = %q", input)
	}
}

func TestPaneHealthProbeFallsBackToFixedReason(t *testing.T) {
	r := phScriptedReader(map[string][]string{"prompt-owner-binding": {"not json"}})
	proof := r.probe(phTestPane, filepath.Join(t.TempDir(), "missing"))
	want := `{"version": 1, "unavailable": "Native identity could not be verified on this host.", "worker": {"upgrade_mode": "unavailable", "update_state": "unverified", "unavailable": "The exact running worker could not be verified."}, "context": {"supported": false, "enabled": false, "state": "unavailable", "unavailable": "Native context status could not be verified."}}`
	if got := string(pyEncode(proof, pyEncodeOptions{itemSep: ", ", keySep: ": "})); got != want {
		t.Fatalf("probe = %s", got)
	}
}

func TestPaneHealthNativeBackendProbeSemantics(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	backend := newPaneHealthNativeBackend(ctx, t.TempDir(), "/relayd")
	backend.startText = func(context.Context, string) (*paneHealthTextBackend, error) {
		t.Fatal("a probe opened the text journal")
		return nil, nil
	}
	backend.probe = func(_ context.Context, pane, executable string) *pyObject {
		return pyObj("pane", pane, "daemon", executable, "big", int64(1)<<62, "text", "é ")
	}
	value, err := backend.Probe(phTestPane)
	if err != nil || string(pyCompact(value)) != `{"big":4611686018427387904,"daemon":"/relayd","pane":"`+phTestPane+`","text":"é "}` {
		t.Fatalf("probe = %s, %v", pyCompact(value), err)
	}
	backend.probe = func(context.Context, string, string) *pyObject { panic(&phException{kind: phValueError, msg: "boom"}) }
	var coded *paneHealthBackendError
	if _, err := backend.Probe(phTestPane); !errors.As(err, &coded) || coded.code != "" {
		t.Fatalf("panicking probe = %v", err)
	}
	backend.probe = func(context.Context, string, string) *pyObject {
		return pyObj("text", strings.Repeat("x", paneHealthBackendReplyLimit))
	}
	if _, err := backend.Probe(phTestPane); !errors.Is(err, errPaneHealthBackendLost) {
		t.Fatalf("oversized probe = %v", err)
	}
	backend.probe = func(context.Context, string, string) *pyObject { cancel(); return pyObj() }
	if _, err := backend.Probe(phTestPane); !errors.Is(err, errPaneHealthBackendLost) {
		t.Fatalf("cancelled during probe = %v", err)
	}
	backend.probe = func(context.Context, string, string) *pyObject { t.Fatal("probe after cancellation"); return nil }
	if _, err := backend.Probe(phTestPane); !errors.Is(err, errPaneHealthBackendLost) {
		t.Fatalf("cancelled before probe = %v", err)
	}
}

func TestPaneHealthNativeBackendStartsTextOnce(t *testing.T) {
	backend := newPaneHealthNativeBackend(context.Background(), t.TempDir(), "/relayd")
	starts := 0
	backend.startText = func(context.Context, string) (*paneHealthTextBackend, error) {
		starts++
		return nil, errors.New("text journal unavailable")
	}
	calls := []func() (any, error){
		func() (any, error) { return backend.ValidatePanes("h", "s", nil) },
		func() (any, error) { return backend.ValidateMessages(nil, "h", nil) },
		func() (any, error) { return backend.ValidateCalls(nil, nil) },
		func() (any, error) { return backend.Assess(pyObj()) },
		func() (any, error) { return backend.Status("op") },
	}
	for index, call := range calls {
		if _, err := call(); !errors.Is(err, errPaneHealthBackendLost) {
			t.Fatalf("call %d = %v", index, err)
		}
	}
	if starts != 1 {
		t.Fatalf("text start attempts = %d", starts)
	}
	backend.Close()
}

func TestPaneHealthRunCommandStatusTimeoutAndDecoding(t *testing.T) {
	script := filepath.Join(t.TempDir(), "run")
	phWrite(t, script, "#!/bin/sh\nprintf 'out\\377'\nexit \"$1\"\n", 0o700)
	r := newPHReader(context.Background())
	for _, code := range []string{"0", "1"} {
		if got := r.run([]string{script, code}, 5); got != "out�" {
			t.Fatalf("exit %s output = %q", code, got)
		}
	}
	if raised := phRaised(t, func() { r.run([]string{script, "2"}, 5) }); raised == nil || raised.kind != phUnbound {
		t.Fatalf("exit 2 = %+v", raised)
	}
	if raised := phRaised(t, func() { r.run([]string{"/bin/sleep", "10"}, 0.2) }); raised == nil || raised.kind != phTimeout {
		t.Fatalf("timeout = %+v", raised)
	}
	if raised := phRaised(t, func() { r.run([]string{script + ".missing"}, 5) }); raised == nil || raised.kind != phOSError {
		t.Fatalf("missing = %+v", raised)
	}
}

func TestPaneHealthPromptOwnerTreatsBlankOutputAsNoOwner(t *testing.T) {
	for raw, want := range map[string]string{" \n\t": "null", "null": "null", ` {"provider": "shell"} `: `{"provider":"shell"}`} {
		r := phScriptedReader(map[string][]string{"prompt-owner-binding": {raw}})
		if got := string(pyCompact(r.promptOwner("/relayd", phTestPane))); got != want {
			t.Fatalf("owner %q = %s", raw, got)
		}
	}
}
