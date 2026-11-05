package helpercli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"unicode/utf8"
)

func fixture(t *testing.T, name string, v any) {
	t.Helper()
	b, e := os.ReadFile("testdata/" + name + "-oracle.json")
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, v); e != nil {
		t.Fatal(e)
	}
}
func sameJSON(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}
func TestSettingsOracle(t *testing.T) {
	var data struct {
		Current map[string]any
		Cases   []struct {
			Args   []string
			Update *string
			Calls  []map[string]any
			Stdout any `json:"stdout_json"`
			Stderr string
			Error  *string
		}
	}
	fixture(t, "settings", &data)
	for i, c := range data.Cases {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			var calls []map[string]any
			var out, errout bytes.Buffer
			deps := SettingsDependencies{UUID: func() (string, error) { return "00000000-0000-4000-8000-000000000001", nil }, ReadFile: func(string) ([]byte, error) {
				if c.Update == nil {
					return nil, errors.New("missing update")
				}
				return []byte(*c.Update), nil
			}, Request: func(_ context.Context, m string, p any, path string) (any, error) {
				calls = append(calls, map[string]any{"method": m, "path": path, "payload": p})
				if m == "GET" && path == "/api/settings" {
					return data.Current, nil
				}
				return map[string]any{"ok": true}, nil
			}}
			e := RunSettings(context.Background(), c.Args, &out, &errout, deps)
			if (e != nil) != (c.Error != nil) {
				t.Fatalf("oracle error differs: %v want %v", e, c.Error)
			}
			if len(calls) != len(c.Calls) || len(calls) > 0 && !sameJSON(calls, c.Calls) {
				t.Fatalf("oracle wire differs: %v want %v", calls, c.Calls)
			}
			if c.Error == nil {
				v, e := decodeJSON(out.Bytes(), maxDocument)
				if e != nil || !sameJSON(v, c.Stdout) {
					t.Fatalf("oracle output differs: %s %v", out.String(), e)
				}
				if errout.String() != c.Stderr {
					t.Fatalf("oracle receipt differs: %q want %q", errout.String(), c.Stderr)
				}
			}
		})
	}
}
func TestSettingsHTTP(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "token")
	os.WriteFile(helper, []byte("#!/bin/sh\n[ \"$1\" = --use-relay-token ] && [ \"$2\" = --print-http-headers ] || exit 7\nprintf '%s' '{\"Authorization\":\"Bearer private-token\"}'\n"), 0700)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("X-Relay-Token") != "private-token" || r.Header.Get("Content-Type") != "application/json" {
			t.Error("request authentication changed")
		}
		if r.URL.Path != "/api/settings" {
			t.Error("request path changed")
		}
		b, _ := io.ReadAll(r.Body)
		if r.Method == "POST" && string(b) != "{\"x\":true}" {
			t.Errorf("request payload changed: %s", b)
		}
		fmt.Fprint(w, `{"ok":true}`)
	}))
	defer server.Close()
	request := settingsHTTP(helper, server.URL, nil)
	for _, m := range []string{"GET", "POST"} {
		var p any
		if m == "POST" {
			p = map[string]any{"x": true}
		}
		v, e := request(context.Background(), m, p, "/api/settings")
		if e != nil || !sameJSON(v, map[string]any{"ok": true}) {
			t.Fatalf("HTTP failed %v %v", v, e)
		}
	}
	if calls != 2 {
		t.Fatal("request count changed")
	}
}
func TestSettingsHTTPBoundaries(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "token")
	os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s' '{\"Authorization\":\"Bearer private-token\"}'\n"), 0700)
	for _, mode := range []string{"reject", "redirect", "oversize", "truncated", "unknown"} {
		t.Run(mode, func(t *testing.T) {
			var calls, leaks atomic.Int32
			other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaks.Add(1); fmt.Fprint(w, `{}`) }))
			defer other.Close()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				switch mode {
				case "reject":
					w.WriteHeader(409)
					fmt.Fprint(w, strings.Repeat("x", 5000))
				case "redirect":
					http.Redirect(w, r, other.URL, 307)
				case "oversize":
					fmt.Fprintf(w, `{"x":"%s"}`, strings.Repeat("a", maxDocument+1))
				case "truncated":
					fmt.Fprint(w, `{"x":`)
				case "unknown":
					h, ok := w.(http.Hijacker)
					if !ok {
						t.Fatal("no hijacker")
					}
					c, _, _ := h.Hijack()
					c.Close()
				}
			}))
			defer server.Close()
			_, e := settingsHTTP(helper, server.URL, nil)(context.Background(), "POST", map[string]any{"x": true}, "/api/settings")
			if e == nil {
				t.Fatal("unsafe HTTP result accepted")
			}
			if calls.Load() != 1 || leaks.Load() != 0 {
				t.Fatalf("write replayed or token redirected: %d %d", calls.Load(), leaks.Load())
			}
			if mode == "reject" && len(e.Error()) > 4140 {
				t.Fatal("error body bound ignored")
			}
		})
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("durable receipt unavailable") }
func TestSettingsBoundedAuthority(t *testing.T) { // Real RunSettings: 8^3 sequences, 1 logical pane, 1 stable request ID.
	ops := []string{"read", "set", "update", "get-fail", "post-unknown", "receipt-fail", "file-fail", "bad-cli"}
	transitions := 0
	var walk func([]string, int)
	walk = func(seq []string, depth int) {
		if depth == 0 {
			return
		}
		for _, op := range ops {
			current := map[string]any{"instance": "pinned-instance", "revision": "pinned-revision", "values": map[string]any{}, "definitions": []any{}}
			posts := 0
			var out, receipt bytes.Buffer
			var ew io.Writer = &receipt
			args := []string{"set", "x", "true", "--request-id", "stable-id"}
			if op == "read" {
				args = []string{"get"}
			}
			if op == "update" || op == "file-fail" {
				args = []string{"update", "--file", "fixture", "--request-id", "stable-id"}
			}
			if op == "bad-cli" {
				args = []string{"--bad"}
			}
			if op == "receipt-fail" {
				ew = failWriter{}
			}
			deps := SettingsDependencies{UUID: randomUUID, ReadFile: func(string) ([]byte, error) {
				if op == "file-fail" {
					return nil, errors.New("read failed")
				}
				return []byte(`{"x":true}`), nil
			}, Request: func(_ context.Context, m string, p any, path string) (any, error) {
				if m == "GET" {
					if op == "get-fail" {
						return nil, errors.New("source unavailable")
					}
					return current, nil
				}
				posts++
				payload := p.(map[string]any)
				if payload["instance"] != "pinned-instance" || payload["expected_revision"] != "pinned-revision" || payload["request_id"] != "stable-id" {
					t.Fatal("write lost source or request identity")
				}
				if !strings.Contains(receipt.String(), "stable-id") || !strings.Contains(receipt.String(), "pinned-revision") {
					t.Fatal("dispatch preceded visible intent")
				}
				if op == "post-unknown" {
					return nil, errors.New("unknown effect")
				}
				return map[string]any{"ok": true}, nil
			}}
			_ = RunSettings(context.Background(), args, &out, ew, deps)
			allowed := op == "set" || op == "update" || op == "post-unknown"
			if posts > 1 || (!allowed && posts != 0) || (allowed && posts != 1) {
				t.Fatalf("authority or once-only violation %v/%s posts=%d", seq, op, posts)
			}
			transitions++
			walk(append(seq, op), depth-1)
		}
	}
	walk(nil, 3)
	if transitions != 584 {
		t.Fatalf("model bound changed: %d", transitions)
	}
	t.Log("8 operations, depth 3, 512 length-3 sequences, 584 checked transitions; production RunSettings with deterministic request/file adapters")
}
func TestWebsiteOracle(t *testing.T) {
	var cases []struct {
		Name, HTML string
		Gate       map[string]any
		Production bool
		Files      []string
		Cname      bool
		Error      *string
	}
	fixture(t, "website", &cases)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			root := t.TempDir()
			writeWebsite(t, root, c.HTML, c.Gate)
			for _, name := range c.Files {
				p := filepath.Join(root, name)
				os.MkdirAll(filepath.Dir(p), 0700)
				os.WriteFile(p, []byte("x"), 0600)
			}
			if c.Cname {
				os.WriteFile(filepath.Join(root, "CNAME"), []byte("x"), 0600)
			}
			e := ValidateWebsite(root, c.Production)
			if c.Error == nil && e != nil || c.Error != nil && (e == nil || e.Error() != *c.Error) {
				t.Fatalf("website oracle changed: %v want %v", e, c.Error)
			}
		})
	}
}

const previewHTML = `<html lang="en"><meta name="viewport"><meta name="robots" content="noindex"><div id="ok"></div></html>`

func writeWebsite(t *testing.T, root, raw string, gate map[string]any) {
	t.Helper()
	b, _ := json.Marshal(gate)
	if e := os.WriteFile(filepath.Join(root, "release-gate.json"), b, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, "index.html"), []byte(raw), 0600); e != nil {
		t.Fatal(e)
	}
}
func TestWebsiteBoundaryGuards(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside")
	os.WriteFile(outside, []byte("private"), 0600)
	os.Symlink(outside, filepath.Join(root, "escape"))
	gate := map[string]any{"domain": "relay.vaklab.dev", "productionReady": false}
	for _, suffix := range []string{`<a href="escape">`, `<a href="` + outside + `">`, `<a href="%2e%2e/outside">`, `<a href="#%6f%6b">`, `text < bad <script>alert(1)</script>`, `<img src="escape" alt="" width="1" height="1">`} {
		writeWebsite(t, root, previewHTML+suffix, gate)
		if e := ValidateWebsite(root, false); e == nil {
			t.Fatalf("private path or script accepted: %s", suffix)
		}
	}
}
func TestWebsiteBoundedGate(t *testing.T) {
	root := t.TempDir()
	states := 0
	keys := []string{"appVersion", "appCommit", "downloadURL", "notarizationStatus", "acceptanceRecord"}
	for mask := 0; mask < 32; mask++ {
		for _, production := range []bool{false, true} {
			for _, ready := range []bool{false, true} {
				for _, noindex := range []bool{false, true} {
					gate := map[string]any{"domain": "relay.vaklab.dev", "productionReady": ready}
					for i, key := range keys {
						if mask&(1<<i) != 0 {
							gate[key] = "yes"
						}
					}
					if mask&4 != 0 {
						gate["downloadURL"] = "https://github.com/genomewalker/relay-terminal/releases/download/v1/app"
					}
					raw := previewHTML
					if !noindex {
						raw = strings.ReplaceAll(raw, "noindex", "index")
					}
					writeWebsite(t, root, raw, gate)
					e := ValidateWebsite(root, production)
					allowed := !production && !ready && noindex || production && ready && !noindex && mask == 31
					if (e == nil) != allowed {
						t.Fatalf("publication gate weakened mask=%d prod=%v ready=%v noindex=%v err=%v", mask, production, ready, noindex, e)
					}
					states++
				}
			}
		}
	}
	if states != 256 {
		t.Fatal("gate bound changed")
	}
	t.Log("256 real validator states: 5 evidence bits x production x ready x noindex")
}
func TestMCPOracle(t *testing.T) {
	var cases []struct {
		Config              json.RawMessage
		Error               *string
		Token, Port, Caller *string
		Args                []string
	}
	fixture(t, "mcp", &cases)
	for i, c := range cases {
		b := []byte(c.Config)
		p, args, env, e := MCPBootstrap("/fixture", b, []string{"RELAY_MCP_CALLER_TOKEN=caller", "KEEP_ME=keep"})
		if (e != nil) != (c.Error != nil) {
			t.Fatalf("MCP oracle error differs case %d: %v", i, e)
		}
		if e == nil {
			m := envMap(env)
			if p != "/fixture/.local/bin/relay-mcp" || !reflect.DeepEqual(args, c.Args) || m["RELAY_MCP_TOKEN"] != *c.Token || m["RELAY_MCP_PORT"] != *c.Port || m["RELAY_MCP_CALLER_TOKEN"] != *c.Caller || m["KEEP_ME"] != "keep" {
				t.Fatalf("MCP oracle launch changed case %d", i)
			}
		}
	}
}
func envMap(env []string) map[string]string {
	m := map[string]string{}
	for _, s := range env {
		k, v, _ := strings.Cut(s, "=")
		m[k] = v
	}
	return m
}
func TestMCPBoundedEnvironment(t *testing.T) {
	states := 0
	for _, token := range []any{"secret", "", 123, nil, "a\x00b"} {
		for _, port := range []any{47471, "47472", true, nil, "a\x00b"} {
			for _, caller := range []string{"", "caller", "different"} {
				b, _ := json.Marshal(map[string]any{"token": token, "port": port})
				_, _, env, e := MCPBootstrap("/fixture", b, []string{"RELAY_MCP_TOKEN=old", "RELAY_MCP_PORT=old", "RELAY_MCP_CALLER_TOKEN=" + caller, "X=keep"})
				valid := token == "secret" || token == ""
				valid = valid && port != "a\x00b"
				if (e == nil) != valid {
					t.Fatal("bootstrap acceptance changed")
				}
				if e == nil {
					m := envMap(env)
					if len(env) != 4 || m["RELAY_MCP_CALLER_TOKEN"] != caller || m["X"] != "keep" || m["RELAY_MCP_TOKEN"] == "old" || m["RELAY_MCP_PORT"] == "old" {
						t.Fatal("caller identity lost or reserved environment duplicated")
					}
				}
				states++
			}
		}
	}
	if states != 75 {
		t.Fatal("bootstrap bound changed")
	}
	t.Log("75 actual bootstrap states, token x port x caller; no execution")
}
func TestMain(m *testing.M) {
	if os.Getenv("HELPERCLI_TEST_ROLE") == "bootstrap" {
		if os.Args[0] == "relay-mcp" {
			b, _ := json.Marshal(map[string]any{"pid": os.Getpid(), "args": os.Args, "env": envMap(os.Environ())})
			os.WriteFile(os.Getenv("HELPERCLI_TEST_OUTPUT"), b, 0600)
			os.Exit(0)
		}
		if e := RunMCPDesktop(); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(3)
		}
		os.Exit(4)
	}
	os.Exit(m.Run())
}
func TestMCPActualExec(t *testing.T) {
	home := t.TempDir()
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	os.MkdirAll(filepath.Join(home, ".local/bin"), 0700)
	os.Symlink(exe, filepath.Join(home, ".local/bin/relay-mcp"))
	os.WriteFile(filepath.Join(home, ".relay-mcp-desktop.json"), []byte(`{"token":"fixture","port":47471}`), 0600)
	out := filepath.Join(home, "result.json")
	cmd := exec.Command(exe)
	cmd.Env = []string{"HOME=" + home, "HELPERCLI_TEST_ROLE=bootstrap", "HELPERCLI_TEST_OUTPUT=" + out, "RELAY_MCP_CALLER_TOKEN=caller", "RELAY_MCP_TOKEN=old", "RELAY_MCP_PORT=old"}
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("fixture exec failed: %v %s", e, b)
	}
	b, e := os.ReadFile(out)
	if e != nil {
		t.Fatal(e)
	}
	var got struct {
		PID  int
		Args []string
		Env  map[string]string
	}
	json.Unmarshal(b, &got)
	if got.PID != cmd.Process.Pid || len(got.Args) != 1 || got.Args[0] != "relay-mcp" || got.Env["RELAY_MCP_CALLER_TOKEN"] != "caller" || got.Env["RELAY_MCP_TOKEN"] != "fixture" || got.Env["RELAY_MCP_PORT"] != "47471" {
		t.Fatalf("exec identity/env changed: %+v", got)
	}
}
func TestJSONStrict(t *testing.T) {
	for _, b := range []string{`{"x":1,"x":2}`, `{"x":`, `[] []`, `"\ud800"`, `"\udc00"`, string([]byte{0xff}), strings.Repeat("[", 66) + strings.Repeat("]", 66)} {
		if _, e := decodeJSON([]byte(b), maxDocument); e == nil {
			t.Fatalf("ambiguous JSON accepted: %q", b)
		}
	}
	if _, e := decodeJSON([]byte(`{"x":1}`), 2); e == nil {
		t.Fatal("JSON byte bound ignored")
	}
}
func TestHTMLScanner(t *testing.T) {
	p, e := parsePage(`<HTML><META name='viewport' content='a>b'><A HREF="a&amp;b">text</A><!-- <script> --><IMG src='x' alt='' width=1 height=2 /></HTML>`)
	if e != nil || len(p.links) != 2 || p.links[0] != "a&b" || p.metas["viewport"] != "a>b" || p.scripts != 0 {
		t.Fatalf("HTML semantics changed: %+v %v", p, e)
	}
	if _, e := parsePage(strings.Repeat("x", websiteLimit+1)); e == nil {
		t.Fatal("HTML byte bound ignored")
	}
}
func FuzzHelperJSON(f *testing.F) {
	for _, s := range []string{`{"x":1}`, `{"a":[true,null,"é"]}`, `{"x":1,"x":2}`, `{"x":`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		v, e := decodeJSON(b, 65536)
		if !utf8.Valid(b) && e == nil {
			t.Fatal("invalid JSON Unicode accepted")
		}
		if len(b) > 65536 && e == nil {
			t.Fatal("JSON byte bound ignored")
		}
		if e != nil {
			return
		}
		encoded, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		round, e := decodeJSON(encoded, maxDocument)
		if e != nil || !sameJSON(v, round) {
			t.Fatal("JSON round trip changed value")
		}
		wrapped := append(append([]byte(`{"value":`), encoded...), '}')
		if _, e = decodeJSON(wrapped[:len(wrapped)-1], maxDocument); e == nil {
			t.Fatal("truncated object accepted")
		}
	})
}
func FuzzHelperHTML(f *testing.F) {
	for _, s := range []string{"hello", "a&b", `x"> <script>`, "é", string([]byte{0xff})} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 65536 {
			return
		}
		raw := `<a href="` + html.EscapeString(s) + `">`
		p, e := parsePage(raw)
		if !utf8.ValidString(s) {
			if e == nil {
				t.Fatal("invalid HTML Unicode accepted")
			}
			return
		}
		if e != nil || len(p.links) != 1 || p.links[0] != s || p.scripts != 0 {
			t.Fatal("HTML attribute round trip changed value")
		}
	})
}
func FuzzHelperSettings(f *testing.F) {
	f.Add([]byte(`["set","x","true","--request-id","fixed"]`))
	f.Add([]byte(`["get"]`))
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > 65536 {
			return
		}
		var args []string
		if json.Unmarshal(b, &args) != nil || len(args) > 32 {
			return
		}
		posts := 0
		deps := SettingsDependencies{UUID: func() (string, error) { return "id", nil }, ReadFile: func(string) ([]byte, error) { return []byte(`{}`), nil }, Request: func(_ context.Context, m string, p any, path string) (any, error) {
			if m == "POST" {
				posts++
			}
			return map[string]any{"instance": "i", "revision": "r", "values": map[string]any{}, "definitions": []any{}}, nil
		}}
		_ = RunSettings(context.Background(), args, io.Discard, io.Discard, deps)
		if posts > 1 {
			t.Fatal("settings write replayed")
		}
		if _, e := parseSettings(args); e != nil && posts != 0 {
			t.Fatal("invalid CLI dispatched write")
		}
	})
}
func FuzzHelperMCP(f *testing.F) {
	f.Add([]byte(`{"token":"x","port":47471}`))
	f.Add([]byte(`{"token":null}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		p, args, env, e := MCPBootstrap("/fixture", b, []string{"RELAY_MCP_CALLER_TOKEN=exact", "X=keep"})
		if e != nil {
			return
		}
		if p != "/fixture/.local/bin/relay-mcp" || !reflect.DeepEqual(args, []string{"relay-mcp"}) || envMap(env)["RELAY_MCP_CALLER_TOKEN"] != "exact" || envMap(env)["X"] != "keep" {
			t.Fatal("bootstrap lost path or caller identity")
		}
	})
}
func TestSettingsJSONAndIntentFailures(t *testing.T) {
	posts := 0
	deps := SettingsDependencies{UUID: func() (string, error) { return "id", nil }, ReadFile: func(string) ([]byte, error) { return []byte(`{}`), nil }, Request: func(_ context.Context, m string, p any, path string) (any, error) {
		if m == "POST" {
			posts++
		}
		return map[string]any{"instance": "i", "revision": "r"}, nil
	}}
	e := RunSettings(context.Background(), []string{"set", "x", `{"k":1,"k":2}`}, io.Discard, io.Discard, deps)
	if e == nil || posts != 0 {
		t.Fatal("ambiguous JSON converted into a setting string")
	}
	deps.UUID = func() (string, error) { return "", errors.New("random unavailable") }
	if e = RunSettings(context.Background(), []string{"set", "x", "true"}, io.Discard, io.Discard, deps); e == nil || posts != 0 {
		t.Fatal("failed request ID admitted write")
	}
}
func FuzzWebsiteLink(f *testing.F) {
	root := f.TempDir()
	outside := filepath.Join(filepath.Dir(root), "private")
	if e := os.WriteFile(outside, []byte("private"), 0600); e != nil {
		f.Fatal(e)
	}
	f.Cleanup(func() { os.Remove(outside) })
	os.WriteFile(filepath.Join(root, "asset"), []byte("x"), 0600)
	for _, s := range []string{"asset", "../private", "%2e%2e/private", "#ok", "https://example.org"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 65536 {
			return
		}
		e := checkLink(root, s, map[string]bool{"ok": true})
		if e != nil {
			return
		}
		if strings.HasPrefix(s, "../") || strings.HasPrefix(s, "/../") {
			t.Fatal("local path escaped website root")
		}
		if s == "#missing" {
			t.Fatal("missing fragment accepted")
		}
	})
}
func TestSettingsUpdateSize(t *testing.T) {
	posts := 0
	deps := SettingsDependencies{UUID: randomUUID, ReadFile: func(string) ([]byte, error) { return []byte(`"` + strings.Repeat("x", 32767) + `"`), nil }, Request: func(_ context.Context, m string, p any, path string) (any, error) {
		if m == "POST" {
			posts++
		}
		return map[string]any{"instance": "i", "revision": "r"}, nil
	}}
	if e := RunSettings(context.Background(), []string{"update", "--file", "fixture"}, io.Discard, io.Discard, deps); e == nil || posts != 0 {
		t.Fatal("oversize update submitted")
	}
}
func TestSettingsHelperFailure(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "token")
	os.WriteFile(helper, []byte("#!/bin/sh\nexit 3\n"), 0700)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; fmt.Fprint(w, `{}`) }))
	defer server.Close()
	_, e := settingsHTTP(helper, server.URL, nil)(context.Background(), "POST", map[string]any{}, "/api/settings")
	if e == nil || calls != 0 {
		t.Fatal("failed auth helper dispatched request")
	}
}
func FuzzHelperHTMLSyntax(f *testing.F) {
	for _, s := range []string{`<meta name="viewport">`, `<a href='x'>`, `<a href="a&amp;b">`, `<!-- <script> -->`, `<img alt='' src=x width=1 height=1>`, `text < bad <script>`} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 65536 {
			return
		}
		p, e := parsePage(s)
		if e != nil {
			return
		}
		var out strings.Builder
		for id := range p.ids {
			fmt.Fprintf(&out, `<div id="%s">`, html.EscapeString(id))
		}
		for _, link := range p.links {
			fmt.Fprintf(&out, `<a href="%s">`, html.EscapeString(link))
		}
		for k, v := range p.metas {
			fmt.Fprintf(&out, `<meta name="%s" content="%s">`, html.EscapeString(k), html.EscapeString(v))
		}
		if p.scripts > 0 {
			out.WriteString(`<script>`)
		}
		q, e := parsePage(out.String())
		if e != nil || !reflect.DeepEqual(p, q) {
			t.Fatal("HTML projection round trip changed semantics")
		}
	})
}
func TestSettingsUsage(t *testing.T) {
	for _, args := range [][]string{{"--bad"}, {"set", "x", "true", "--request-id", "--bad"}, {"update", "--file"}} {
		e := RunSettings(context.Background(), args, io.Discard, io.Discard, DefaultSettingsDependencies())
		var usage *UsageError
		if !errors.As(e, &usage) {
			t.Fatal("CLI usage must retain exit-2 classification")
		}
	}
}

func TestSettingsHTTPAcceptsBoundedMaintenanceSnapshot(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s' '{\"Authorization\":\"Bearer private-token\"}'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Token") != "private-token" {
			t.Fatal("missing authentication")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"definitions": []any{map[string]any{"key": "miko_autonomy", "type": "string"}},
			"values":      map[string]any{"miko_autonomy": "autonomous"}, "instance": "instance", "revision": "revision",
			"agentMaintenance": map[string]any{"observations": strings.Repeat("x", 170000)},
		})
	}))
	defer server.Close()
	var out, diagnostics bytes.Buffer
	deps := SettingsDependencies{Request: settingsHTTP(helper, server.URL, nil), UUID: func() (string, error) { return "id", nil }, ReadFile: func(string) ([]byte, error) { return nil, errors.New("unexpected read") }}
	if err := RunSettings(context.Background(), []string{"schema"}, &out, &diagnostics, deps); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "miko_autonomy") || strings.Contains(out.String(), "observations") {
		t.Fatal("schema output contains monitoring data or is incomplete")
	}
}
