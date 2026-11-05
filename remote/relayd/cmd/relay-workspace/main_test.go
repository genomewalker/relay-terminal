package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const (
	tabID  = "AAAAAAAA-0000-4000-8000-000000000001"
	paneID = "BBBBBBBB-0000-4000-8000-000000000002"
	pane2  = "cccccccc-0000-4000-8000-000000000003"
)

type recorded struct {
	method, path string
	header       http.Header
	body         string
}

type fakeRelay struct {
	t        *testing.T
	mu       sync.Mutex
	requests []recorded
	handle   func(path string, body map[string]any) (int, string)
}

func (f *fakeRelay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.requests = append(f.requests, recorded{r.Method, r.URL.Path, r.Header.Clone(), string(data)})
	f.mu.Unlock()
	var body map[string]any
	if len(data) > 0 {
		if err := json.Unmarshal(data, &body); err != nil {
			f.t.Errorf("request body is not JSON: %s", data)
		}
	}
	status, reply := f.handle(r.URL.Path, body)
	w.WriteHeader(status)
	_, _ = io.WriteString(w, reply)
}

const stateReply = `{"sessions":[{"tabs":[{"id":"` + tabID + `","panes":[{"id":"` + paneID +
	`","connection":"connected","phase":"running"}]},{"id":"dddddddd-0000-4000-8000-000000000004","panes":[{"id":"` + pane2 +
	`","connection":"lost","phase":"idle"},{"id":"` + pane2 + `","connection":"lost","phase":"idle"}]}]}]}`

// writeHelper is a fake relay-mcp that prints the token headers.
func writeHelper(t *testing.T, script string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "relay-mcp")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

type harness struct {
	relay          *fakeRelay
	workspace      *workspace
	stdout, stderr *bytes.Buffer
	env            map[string]string
}

func newHarness(t *testing.T, handle func(path string, body map[string]any) (int, string)) *harness {
	t.Helper()
	relay := &fakeRelay{t: t, handle: handle}
	server := httptest.NewServer(relay)
	t.Cleanup(server.Close)
	h := &harness{relay: relay, stdout: &bytes.Buffer{}, stderr: &bytes.Buffer{}, env: map[string]string{}}
	counter := 0
	h.workspace = &workspace{
		baseURL: server.URL,
		helper: writeHelper(t, `[ "$1 $2" = "--use-relay-token --print-http-headers" ] || exit 9
printf '{"Authorization": "Bearer tok-1", "X-Relay-Caller-Token": "caller-1"}'`),
		getenv: func(key string) string { return h.env[key] },
		stdin:  strings.NewReader(""),
		stdout: h.stdout,
		stderr: h.stderr,
		newHex: func() string { counter++; return fmt.Sprintf("%032x", counter) },
		client: socketTimeoutClient(socketTimeout),
	}
	return h
}

func (h *harness) run(args ...string) int { return h.workspace.run(args) }

func stateHandler(next func(path string, body map[string]any) (int, string)) func(string, map[string]any) (int, string) {
	return func(path string, body map[string]any) (int, string) {
		if path == "/api/state" {
			return 200, stateReply
		}
		return next(path, body)
	}
}

func refuseAll(t *testing.T) func(string, map[string]any) (int, string) {
	return func(path string, _ map[string]any) (int, string) {
		t.Errorf("unexpected request %s", path)
		return 500, "{}"
	}
}

func expectUsage(t *testing.T, h *harness, code int, message string) {
	t.Helper()
	if code != 2 || !strings.Contains(h.stderr.String(), "relay-workspace: error: "+message+"\n") ||
		!strings.HasPrefix(h.stderr.String(), "usage: relay-workspace") {
		t.Fatalf("exit %d, stderr %q; want usage error %q", code, h.stderr.String(), message)
	}
}

func TestContextWithHostNeedsNoRelayLookup(t *testing.T) {
	h := newHarness(t, refuseAll(t))
	if code := h.run("--host", "dandy-07", "--directory", "/w/x", "context"); code != 0 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	if got := h.stdout.String(); got != `{"host": "dandy-07", "directory": "/w/x", "binding": "explicit_cli"}`+"\n" {
		t.Fatalf("context %q", got)
	}
}

func TestHostDirectoryMustBeAbsolute(t *testing.T) {
	for _, directory := range []string{"relative", "/a\x00b"} {
		h := newHarness(t, refuseAll(t))
		expectUsage(t, h, h.run("--host", "h", "--directory", directory, "context"), "--directory must be an absolute path")
	}
}

func TestContextForTabSendsTokenHeadersAndPrintsReply(t *testing.T) {
	h := newHarness(t, stateHandler(func(path string, body map[string]any) (int, string) {
		if path != "/api/workspace/context" || body["tab_id"] != tabID {
			t.Errorf("context request %s %v", path, body)
		}
		return 200, `{"host": "dandy-07", "directory": "/home/é", "z": 1.0, "big": 123456789012345678901234567890}`
	}))
	if code := h.run("context", "--tab", strings.ToLower(tabID)); code != 0 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	if got := h.stdout.String(); got != `{"host": "dandy-07", "directory": "/home/\u00e9", "z": 1.0, "big": 123456789012345678901234567890}`+"\n" {
		t.Fatalf("context %q", got)
	}
	last := h.relay.requests[len(h.relay.requests)-1]
	if last.method != http.MethodPost || last.header.Get("X-Relay-Token") != "tok-1" ||
		last.header.Get("X-Relay-Caller-Token") != "caller-1" || last.header.Get("Content-Type") != "application/json" {
		t.Fatalf("headers %v", last.header)
	}
	if first := h.relay.requests[0]; first.method != http.MethodGet || first.path != "/api/state" || first.body != "" {
		t.Fatalf("state lookup %+v", first)
	}
}

func TestCallerTokenFromEnvironmentOverridesHelper(t *testing.T) {
	h := newHarness(t, stateHandler(func(string, map[string]any) (int, string) { return 200, `{"host": "h", "directory": "/"}` }))
	h.env["RELAY_CALLER_TOKEN"] = "caller-env"
	if code := h.run("--tab", tabID, "context"); code != 0 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	if got := h.relay.requests[0].header.Get("X-Relay-Caller-Token"); got != "caller-env" {
		t.Fatalf("caller token %q", got)
	}
}

func TestPanePassedAsTabResolvesItsTab(t *testing.T) {
	h := newHarness(t, stateHandler(func(path string, body map[string]any) (int, string) {
		if body["tab_id"] != tabID {
			t.Errorf("tab_id %v", body["tab_id"])
		}
		return 200, `{"host": "h", "directory": "/"}`
	}))
	if code := h.run("--tab", "{urn:uuid:"+strings.ToLower(paneID)+"}", "context"); code != 0 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
}

func TestPaneAndTabLookupRefusals(t *testing.T) {
	for _, c := range []struct {
		args    []string
		message string
	}{
		{[]string{"--pane", "not-a-uuid", "context"}, "An exact pane or tab UUID is required"},
		{[]string{"--pane", "eeeeeeee-0000-4000-8000-000000000009", "context"}, "Pane is absent or ambiguous in the current Relay workspace"},
		{[]string{"--pane", pane2, "context"}, "Pane is absent or ambiguous in the current Relay workspace"},
		{[]string{"--pane", tabID, "context"}, "Pane is absent or ambiguous in the current Relay workspace"},
		{[]string{"--tab", tabID, "screen"}, "screen requires --pane; a tab can contain several terminals"},
		{[]string{"--host", "h", "screen"}, "screen requires --pane with an existing terminal UUID"},
		{[]string{"--pane", paneID, "screen", "extra"}, "screen takes no additional arguments"},
	} {
		h := newHarness(t, stateHandler(refuseAll(t)))
		expectUsage(t, h, h.run(c.args...), c.message)
	}
}

func TestScreenAnnotatesViewportAndMarksEmptyScreens(t *testing.T) {
	for _, c := range []struct{ reply, want string }{
		{`{"text": "$ ls", "rows": 2}`, `{"text": "$ ls", "rows": 2, "tab_id": "` + tabID + `", "connection": "connected", "phase": "running", "untrusted_output": true}`},
		{`{"text": "", "tab_id": "x"}`, `{"text": "", "tab_id": "` + tabID + `", "connection": "connected", "phase": "running", "untrusted_output": true, ` +
			`"availability": "empty_or_unmounted_viewport", "message": "No rendered screen is available; this does not prove the worker is stuck. No input was sent."}`},
	} {
		h := newHarness(t, stateHandler(func(path string, _ map[string]any) (int, string) {
			if path != "/api/panes/"+paneID+"/viewport" {
				t.Errorf("viewport path %s", path)
			}
			return 200, c.reply
		}))
		if code := h.run("--pane", strings.ToLower(paneID), "screen"); code != 0 {
			t.Fatalf("exit %d: %s", code, h.stderr)
		}
		if got := h.stdout.String(); got != c.want+"\n" {
			t.Fatalf("screen\n got %s\nwant %s", got, c.want)
		}
	}
}

func hostHandler(t *testing.T, result func(body map[string]any) string) func(string, map[string]any) (int, string) {
	return func(path string, body map[string]any) (int, string) {
		if path != "/api/host/request" {
			t.Errorf("unexpected path %s", path)
			return 404, "missing"
		}
		return 200, `{"result": ` + result(body) + `}`
	}
}

func TestRequestAddsCapturedTargetAndPrintsResult(t *testing.T) {
	var sent string
	h := newHarness(t, hostHandler(t, func(map[string]any) string { return `{"ok": true, "n": [1, 2.5]}` }))
	if code := h.run("--host", "dandy-07", "--directory", "/w", "request", `{"operation": "file_stat", "host": "spoof", "path": "/w/a"}`); code != 0 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	sent = h.relay.requests[0].body
	if sent != `{"operation": "file_stat", "host": "dandy-07", "path": "/w/a", "cwd": "/w", "request_id": "rpc-00000000000000000000000000000001"}` {
		t.Fatalf("sent %s", sent)
	}
	if h.stdout.String() != `{"ok": true, "n": [1, 2.5]}`+"\n" {
		t.Fatalf("stdout %q", h.stdout)
	}
}

func TestRequestReadsStdinAndRefusesBadInput(t *testing.T) {
	h := newHarness(t, hostHandler(t, func(body map[string]any) string {
		if body["operation"] != "capabilities" {
			t.Errorf("body %v", body)
		}
		return `"done"`
	}))
	h.workspace.stdin = strings.NewReader(`{"operation":"capabilities"}`)
	if code := h.run("--host", "h", "request"); code != 0 || h.stdout.String() != "\"done\"\n" {
		t.Fatalf("exit %d stdout %q stderr %q", code, h.stdout, h.stderr)
	}

	h = newHarness(t, refuseAll(t))
	expectUsage(t, h, h.run("--host", "h", "request", "[1]"), "request requires a JSON object")
	h = newHarness(t, refuseAll(t))
	expectUsage(t, h, h.run("--host", "h", "request", "{}", "{}"), "request takes one JSON object or reads stdin")

	h = newHarness(t, refuseAll(t))
	h.workspace.stdin = strings.NewReader(`{"a":"` + strings.Repeat("x", requestLimit) + `"}`)
	if code := h.run("--host", "h", "request"); code != 1 || h.stderr.String() != "Relay: Request too large\n" {
		t.Fatalf("oversized request: exit %d %q", code, h.stderr)
	}
	h = newHarness(t, refuseAll(t))
	if code := h.run("--host", "h", "request", "{"); code != 1 || !strings.HasPrefix(h.stderr.String(), "Relay: ") {
		t.Fatalf("malformed request: exit %d %q", code, h.stderr)
	}
}

func TestImageWritesDecodedBytesAndRefusesBadData(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', 0, 1, 2}
	h := newHarness(t, stateHandler(func(path string, body map[string]any) (int, string) {
		if path == "/api/workspace/context" {
			return 200, `{"host": "h", "directory": "/"}`
		}
		if path != "/api/workspace/image" || body["tab_id"] != tabID || body["path"] != "/w/plot.png" {
			t.Errorf("image request %s %v", path, body)
		}
		return 200, `{"data": "` + base64.StdEncoding.EncodeToString(png) + `"}`
	}))
	if code := h.run("--tab", tabID, "image", "/w/plot.png"); code != 0 || !bytes.Equal(h.stdout.Bytes(), png) {
		t.Fatalf("exit %d stdout %x stderr %s", code, h.stdout.Bytes(), h.stderr)
	}
	for _, data := range []string{"AAA", "AA\nAA", "AA*A"} {
		h := newHarness(t, stateHandler(func(path string, _ map[string]any) (int, string) {
			if path == "/api/workspace/context" {
				return 200, `{"host": "h", "directory": "/"}`
			}
			return 200, `{"data": "` + strings.ReplaceAll(data, "\n", `\n`) + `"}`
		}))
		if code := h.run("--tab", tabID, "image", "/p"); code != 1 || h.stdout.Len() != 0 {
			t.Fatalf("invalid base64 %q accepted: exit %d", data, code)
		}
	}
	h = newHarness(t, refuseAll(t))
	expectUsage(t, h, h.run("--host", "h", "image", "/p"), "image requires --tab with a captured workspace context")
	h = newHarness(t, stateHandler(func(string, map[string]any) (int, string) { return 200, `{"host": "h", "directory": "/"}` }))
	expectUsage(t, h, h.run("--tab", tabID, "image"), "image requires one path")
}

// execRelay scripts the exec admission and the status replies.
func execRelay(t *testing.T, admitted string, statuses []string) (*harness, *[]map[string]any) {
	var bodies []map[string]any
	h := newHarness(t, nil)
	h.relay.handle = hostHandler(t, func(body map[string]any) string {
		bodies = append(bodies, body)
		if body["operation"] == "exec" {
			return admitted
		}
		if len(statuses) == 0 {
			t.Fatal("status polled after the job finished")
		}
		next := statuses[0]
		statuses = statuses[1:]
		return next
	})
	return h, &bodies
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func TestExecStreamsOutputUntilAnEmptyFinalStatus(t *testing.T) {
	h, bodies := execRelay(t, `{"state": "running"}`, []string{
		`{"stdout": "` + b64("out-1\n") + `", "stdout_offset": 6, "stderr": null, "stderr_offset": 0, "job": {"state": "running"}}`,
		`{"stdout": "` + b64("out-2\n") + `", "stdout_offset": 12, "stderr": "` + b64("err\n") + `", "stderr_offset": 4, "job": {"state": "exited", "exit_code": 3}}`,
		// Output still arriving after exit keeps the loop polling.
		`{"stdout": "", "stdout_offset": 12, "stderr": "` + b64("late\n") + `", "stderr_offset": 9, "job": {"state": "exited", "exit_code": 3}}`,
		`{"stdout": "", "stdout_offset": 12, "stderr_offset": 9, "job": {"state": "exited", "exit_code": 3}}`,
	})
	if code := h.run("--host", "dandy-07", "--directory", "/w", "exec", "--", "ls", "-la"); code != 3 {
		t.Fatalf("exit %d: %s", code, h.stderr)
	}
	if h.stdout.String() != "out-1\nout-2\n" {
		t.Fatalf("stdout %q", h.stdout)
	}
	announce := `{"job_id": "job-00000000000000000000000000000001", "host": "dandy-07", "directory": "/w", "binding": "explicit_cli"}` + "\n"
	if h.stderr.String() != announce+"err\nlate\n" {
		t.Fatalf("stderr %q", h.stderr)
	}
	start := h.relay.requests[0].body
	if start != `{"operation": "exec", "job_id": "job-00000000000000000000000000000001", "argv": ["ls", "-la"], "host": "dandy-07", "cwd": "/w", "request_id": "rpc-00000000000000000000000000000002"}` {
		t.Fatalf("exec request %s", start)
	}
	if status := h.relay.requests[2].body; status != `{"operation": "status", "job_id": "job-00000000000000000000000000000001", "wait_millis": 15000, "stdout_offset": 6, "stderr_offset": 0, "host": "dandy-07", "cwd": "/w", "request_id": "rpc-00000000000000000000000000000004"}` {
		t.Fatalf("status request %s", status)
	}
	if len(*bodies) != 5 {
		t.Fatalf("%d host requests", len(*bodies))
	}
}

func TestExecExitStatusFollowsJobExitCode(t *testing.T) {
	for _, c := range []struct {
		job  string
		code int
	}{
		{`{"state": "exited", "exit_code": 0}`, 0},
		{`{"state": "failed"}`, 1},
		{`{"state": "exited", "exit_code": null}`, 0},
		{`{"state": "exited", "exit_code": 256}`, 0},
		{`{"state": "exited", "exit_code": -1}`, 255},
	} {
		h, _ := execRelay(t, `{"state": "exited"}`, []string{`{"stdout_offset": 0, "stderr_offset": 0, "job": ` + c.job + `}`})
		if code := h.run("--host", "h", "exec", "true"); code != c.code {
			t.Errorf("%s: exit %d, want %d", c.job, code, c.code)
		}
	}
}

func TestExecRefusesUnadmittedAndUnknownOutcomes(t *testing.T) {
	h, _ := execRelay(t, `{"state": "refused"}`, nil)
	if code := h.run("--host", "h", "exec", "true"); code != 1 ||
		!strings.HasSuffix(h.stderr.String(), "Relay: Execution was not admitted; inspect job job-00000000000000000000000000000001\n") {
		t.Fatalf("exit %d stderr %q", code, h.stderr)
	}
	h, _ = execRelay(t, `{"state": "running"}`, []string{`{"stdout_offset": 0, "stderr_offset": 0, "job": {"state": "unknown_after_daemon_restart"}}`})
	if code := h.run("--host", "h", "exec", "true"); code != 1 ||
		!strings.HasSuffix(h.stderr.String(), "Relay: Outcome unknown; inspect job job-00000000000000000000000000000001; do not replay\n") {
		t.Fatalf("exit %d stderr %q", code, h.stderr)
	}
	h = newHarness(t, refuseAll(t))
	expectUsage(t, h, h.run("--host", "h", "exec"), "exec requires an executable and arguments")
	h, _ = execRelay(t, `{"state": "running"}`, nil)
	h.relay.handle = func(path string, _ map[string]any) (int, string) {
		if path == "/api/state" {
			return 200, stateReply
		}
		return 200, `{"host": "h", "directory": "/", "job_id": "x"}`
	}
	if code := h.run("--tab", tabID, "exec", "true"); code != 1 || !strings.Contains(h.stderr.String(), "multiple values for keyword argument 'job_id'") {
		t.Fatalf("context carrying job_id: exit %d %q", code, h.stderr)
	}
}

func TestRelayFailuresAreReportedOnce(t *testing.T) {
	for _, c := range []struct {
		status        int
		reply, stderr string
	}{
		{403, "caller paused", "Relay: Relay HTTP 403: caller paused\n"},
		{200, `{"error": "tab is gone"}`, "Relay: tab is gone\n"},
		{200, `[1]`, "Relay: 'list' object has no attribute 'get'\n"},
		{200, `{"result": 1}`, "Relay: 'host'\n"},
	} {
		h := newHarness(t, stateHandler(func(string, map[string]any) (int, string) { return c.status, c.reply }))
		if code := h.run("--tab", tabID, "request", "{}"); code != 1 || h.stderr.String() != c.stderr {
			t.Errorf("%d %s: exit %d stderr %q", c.status, c.reply, code, h.stderr)
		}
	}
	h := newHarness(t, func(string, map[string]any) (int, string) {
		return 200, `{"x": "` + strings.Repeat("a", responseLimit) + `"}`
	})
	if code := h.run("--tab", tabID, "context"); code != 1 || h.stderr.String() != "Relay: Response exceeded CLI limit\n" {
		t.Fatalf("oversized response: exit %d %q", code, h.stderr)
	}
}

func TestHelperFailureStopsBeforeAnyRequest(t *testing.T) {
	h := newHarness(t, refuseAll(t))
	h.workspace.helper = writeHelper(t, "echo denied >&2; exit 4")
	if code := h.run("--host", "h", "context"); code != 1 ||
		!strings.Contains(h.stderr.String(), "denied\nRelay: Command '['") || !strings.Contains(h.stderr.String(), "returned non-zero exit status 4.") {
		t.Fatalf("exit %d stderr %q", code, h.stderr)
	}
	h = newHarness(t, refuseAll(t))
	h.workspace.helper = writeHelper(t, `printf '{"X-Relay-Caller-Token": "c"}'`)
	if code := h.run("--host", "h", "context"); code != 1 || h.stderr.String() != "Relay: 'Authorization'\n" {
		t.Fatalf("exit %d stderr %q", code, h.stderr)
	}
}

func TestArgumentParsing(t *testing.T) {
	for _, c := range []struct {
		args    []string
		message string
	}{
		{[]string{"context"}, "one of the arguments --tab --pane --host is required"},
		{[]string{"--host", "h"}, "the following arguments are required: operation"},
		{[]string{"--host", "h", "--tab", tabID, "context"}, "argument --tab: not allowed with argument --host"},
		{[]string{"--host", "h", "reboot"}, "argument operation: invalid choice: 'reboot' (choose from 'context', 'screen', 'request', 'exec', 'image')"},
		{[]string{"--host", "h", "exec", "ls", "-la"}, "unrecognized arguments: -la"},
		{[]string{"--host"}, "argument --host: expected one argument"},
		{[]string{"--host", "--pane", "x", "context"}, "argument --host: expected one argument"},
	} {
		h := newHarness(t, refuseAll(t))
		expectUsage(t, h, h.run(c.args...), c.message)
	}
	h := newHarness(t, refuseAll(t))
	if code := h.run("-h"); code != 0 || !strings.Contains(h.stdout.String(), "Exact Relay pane UUID; resolves its existing tab") {
		t.Fatalf("help: exit %d %q", code, h.stdout)
	}
	h = newHarness(t, refuseAll(t))
	if code := h.run("--ho=h", "--dir", "/x", "context"); code != 0 || !strings.Contains(h.stdout.String(), `"directory": "/x"`) {
		t.Fatalf("abbreviated options: exit %d %q %q", code, h.stdout, h.stderr)
	}
}

func TestPythonValueModel(t *testing.T) {
	escaped := strings.ReplaceAll(`"/u2028/ud83d/ude00/u007f"`, "/", "\x5c")
	for lexeme, want := range map[string]string{
		escaped: escaped,
		"1.0":   "1.0", "1e5": "100000.0", "1e16": "1e+16", "0.0001": "0.0001", "0.00001": "1e-05", "-0.0": "-0.0",
		"1.5e300": "1.5e+300", "123.456": "123.456",
		`{"b": 1, "a": [], "b": 2}`: `{"b": 2, "a": []}`, "-12345678901234567890123": "-12345678901234567890123", "1e400": "Infinity",
	} {
		value, err := decodeJSON([]byte(lexeme))
		if err != nil {
			t.Fatal(err)
		}
		if got := string(encodeJSON(value)); got != want {
			t.Errorf("%s encoded %s, want %s", lexeme, got, want)
		}
	}
	for _, value := range []any{nil, false, "", 0.0, []any{}, newObject()} {
		if truthy(value) {
			t.Errorf("%#v is truthy", value)
		}
	}
	if id, ok := canonicalUUID("{" + paneID + "}"); !ok || id != strings.ToLower(paneID) {
		t.Fatalf("uuid %q %v", id, ok)
	}
	if _, ok := canonicalUUID(strings.Replace(paneID, "B", "G", 1)); ok {
		t.Fatal("non-hex uuid accepted")
	}
}
