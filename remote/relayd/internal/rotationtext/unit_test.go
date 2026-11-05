package rotationtext

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// expectDraft runs fn and returns the DraftError code it raised ("" for none).
func expectDraft(t *testing.T, fn func()) (code string, unavailable bool) {
	t.Helper()
	defer func() {
		if value := recover(); value != nil {
			err, ok := value.(*draftError)
			if !ok {
				t.Fatalf("unexpected panic %v", value)
			}
			code, unavailable = err.code, err.unavailable
		}
	}()
	fn()
	return "", false
}

// withAPIServer points apiPost at a local TLS server for one test.
func withAPIServer(t *testing.T, handler http.HandlerFunc, configure func(*httptest.Server)) {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	if configure != nil {
		configure(server)
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	saved := apiTarget
	apiTarget.address, apiTarget.serverName, apiTarget.roots = server.Listener.Addr().String(), "example.com", roots
	t.Cleanup(func() { apiTarget = saved })
}

func TestAPIPostRequestShape(t *testing.T) {
	var seen *http.Request
	var body []byte
	withAPIServer(t, func(w http.ResponseWriter, r *http.Request) {
		seen, body = r, nil
		body, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "Application/JSON ; charset=utf-8")
		w.Write([]byte(`{"ok":true}`))
	}, nil)
	raw := apiPost(context.Background(), []byte(`{"q":1}`), fakeKey, 5*time.Second)
	if string(raw) != `{"ok":true}` || string(body) != `{"q":1}` {
		t.Fatalf("response %q body %q", raw, body)
	}
	if seen.Method != http.MethodPost || seen.URL.Path != "/v1/messages" || seen.Host != "api.anthropic.com" || seen.Proto != "HTTP/1.1" {
		t.Fatalf("request line %s %s %s %s", seen.Method, seen.URL.Path, seen.Host, seen.Proto)
	}
	want := map[string]string{"Content-Type": "application/json", "Anthropic-Version": "2023-06-01", "X-Api-Key": fakeKey,
		"Accept": "application/json", "Accept-Encoding": "identity", "Content-Length": "7"}
	for name, value := range want {
		if got := seen.Header.Get(name); got != value {
			t.Errorf("header %s = %q, want %q", name, got, value)
		}
	}
	if _, ok := seen.Header["User-Agent"]; ok {
		t.Error("User-Agent sent; http.client sends none")
	}
	if len(seen.Header) != len(want) {
		t.Errorf("unexpected header set: %v", seen.Header)
	}
}

func TestAPIPostOutcomes(t *testing.T) {
	cases := []struct {
		name    string
		handler http.HandlerFunc
		timeout time.Duration
		code    string
	}{
		{"status", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(529)
			w.Write([]byte(`{"error":"echo of submitted content"}`))
		}, time.Second, "api_http_529"},
		{"redirect not followed", func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "https://evil.example/", http.StatusFound)
		}, time.Second, "api_http_302"},
		{"content type", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`{}`))
		}, time.Second, "api_content_type"},
		{"missing content type", func(w http.ResponseWriter, r *http.Request) {
			w.Header()["Content-Type"] = nil
			w.Write([]byte(`{}`))
		}, time.Second, "api_content_type"},
		{"too large", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Write(make([]byte, maxResponse+1))
		}, 5 * time.Second, "response_too_large"},
		{"exactly max", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Write(make([]byte, maxResponse))
		}, 5 * time.Second, ""},
		{"slow body", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			w.(http.Flusher).Flush()
			time.Sleep(1500 * time.Millisecond)
		}, 300 * time.Millisecond, "request_outcome_unknown"},
		{"slow headers", func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(1500 * time.Millisecond)
		}, 300 * time.Millisecond, "request_outcome_unknown"},
		{"truncated", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Length", "100")
			w.Write([]byte(`{"partial"`))
		}, time.Second, "request_outcome_unknown"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withAPIServer(t, c.handler, nil)
			code, unavailable := expectDraft(t, func() { apiPost(context.Background(), []byte(`{}`), fakeKey, c.timeout) })
			if code != c.code || unavailable {
				t.Fatalf("code %q unavailable %v, want %q", code, unavailable, c.code)
			}
		})
	}
}

func TestAPIPostTransportFailures(t *testing.T) {
	t.Run("tls below 1.2", func(t *testing.T) {
		withAPIServer(t, func(w http.ResponseWriter, r *http.Request) { t.Error("request reached a TLS 1.1 server") },
			// The server must offer TLS 1.0-1.1 explicitly; Go servers default to 1.2.
			func(s *httptest.Server) {
				s.TLS = &tls.Config{MinVersion: tls.VersionTLS10, MaxVersion: tls.VersionTLS11}
			})
		if code, _ := expectDraft(t, func() { apiPost(context.Background(), nil, fakeKey, time.Second) }); code != "request_outcome_unknown" {
			t.Fatal(code)
		}
	})
	t.Run("untrusted certificate", func(t *testing.T) {
		withAPIServer(t, func(w http.ResponseWriter, r *http.Request) { t.Error("credential sent to an untrusted server") }, nil)
		apiTarget.roots = x509.NewCertPool()
		if code, _ := expectDraft(t, func() { apiPost(context.Background(), nil, fakeKey, time.Second) }); code != "request_outcome_unknown" {
			t.Fatal(code)
		}
	})
	t.Run("refused", func(t *testing.T) {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := listener.Addr().String()
		listener.Close()
		saved := apiTarget
		apiTarget.address = address
		defer func() { apiTarget = saved }()
		if code, _ := expectDraft(t, func() { apiPost(context.Background(), nil, fakeKey, time.Second) }); code != "request_outcome_unknown" {
			t.Fatal(code)
		}
	})
	t.Run("cancelled before connect", func(t *testing.T) {
		withAPIServer(t, func(w http.ResponseWriter, r *http.Request) { t.Error("request sent after cancellation") }, nil)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if code, _ := expectDraft(t, func() { apiPost(ctx, nil, fakeKey, time.Second) }); code != "request_outcome_unknown" {
			t.Fatal(code)
		}
	})
	t.Run("proxy environment ignored", func(t *testing.T) {
		withAPIServer(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`[]`))
		}, nil)
		t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
		t.Setenv("https_proxy", "http://127.0.0.1:1")
		if raw := apiPost(context.Background(), nil, fakeKey, time.Second); string(raw) != `[]` {
			t.Fatal(string(raw))
		}
	})
}

func TestContentType(t *testing.T) {
	for header, want := range map[string]string{"application/json": "application/json", " APPLICATION/JSON;x=1": "application/json",
		"application/json\x85": "application/json", "": "", "application/jsonx": "application/jsonx"} {
		if got := contentType([]string{header}); got != want {
			t.Errorf("%q -> %q, want %q", header, got, want)
		}
	}
	if got := contentType([]string{"application/json", "text/html"}); got != "application/json, text/html" {
		t.Errorf("joined headers: %q", got)
	}
}

func shell(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "script")
	writeScript(t, path, "#!/bin/sh\n"+body)
	return path
}

func TestRunCLI(t *testing.T) {
	env := []string{"PATH=/usr/bin:/bin"}
	t.Run("output and input", func(t *testing.T) {
		out := runCLI(context.Background(), []string{shell(t, "tr a-z A-Z")}, []byte("hello"), "/", 5*time.Second, env)
		if string(out) != "HELLO" {
			t.Fatal(string(out))
		}
	})
	t.Run("environment exact", func(t *testing.T) {
		out := runCLI(context.Background(), []string{shell(t, "/usr/bin/env")}, nil, "/", 5*time.Second, []string{"ONLY=1"})
		if !strings.Contains(string(out), "ONLY=1") || strings.Contains(string(out), "HOME=") {
			t.Fatal(string(out))
		}
	})
	t.Run("large input to a non-reader", func(t *testing.T) {
		out := runCLI(context.Background(), []string{shell(t, "printf done")}, make([]byte, 1<<20), "/", 5*time.Second, env)
		if string(out) != "done" {
			t.Fatal(string(out))
		}
	})
	cases := []struct {
		name, script string
		dir          string
		timeout      time.Duration
		code         string
		unavailable  bool
	}{
		{"exit status", "exit 3", "/", 5 * time.Second, "cli_request_failed", false},
		{"killed by signal", "kill -9 $$", "/", 5 * time.Second, "cli_request_failed", false},
		{"too large", "head -c 262145 /dev/zero", "/", 5 * time.Second, "response_too_large", false},
		{"timeout reading", "sleep 5", "/", 300 * time.Millisecond, "request_outcome_unknown", false},
		{"timeout after close", "exec >&-; sleep 5", "/", 300 * time.Millisecond, "request_outcome_unknown", false},
		{"bad cwd", "true", "/nonexistent-relay-dir", time.Second, "cli_start_failed", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			began := time.Now()
			code, unavailable := expectDraft(t, func() { runCLI(context.Background(), []string{shell(t, c.script)}, nil, c.dir, c.timeout, env) })
			if code != c.code || unavailable != c.unavailable {
				t.Fatalf("code %q unavailable %v", code, unavailable)
			}
			if time.Since(began) > 3*time.Second {
				t.Fatal("runCLI did not stop its child promptly")
			}
		})
	}
	t.Run("cancellation kills the child", func(t *testing.T) {
		marker := filepath.Join(t.TempDir(), "pid")
		ctx, cancel := context.WithCancel(context.Background())
		go func() {
			for i := 0; i < 100; i++ {
				if _, err := os.Stat(marker); err == nil {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}
			cancel()
		}()
		code, _ := expectDraft(t, func() {
			runCLI(ctx, []string{shell(t, "echo $$ > "+marker+"; sleep 30")}, nil, "/", 30*time.Second, env)
		})
		if code != "request_outcome_unknown" {
			t.Fatal(code)
		}
		data, _ := os.ReadFile(marker)
		pid := 0
		for _, c := range strings.TrimSpace(string(data)) {
			pid = pid*10 + int(c-'0')
		}
		if pid <= 1 || syscall.Kill(pid, 0) == nil {
			t.Fatalf("child %d still running after cancellation", pid)
		}
	})
}

func TestPathHelpers(t *testing.T) {
	for in, want := range map[string]string{"/a/b/": "/a/b", "/a//b/./c/.": "/a/b/c", "//a": "//a", "///a": "/a", "/": "/", "/a/../b": "/a/../b"} {
		if got := pathlibClean(in); got != want {
			t.Errorf("pathlibClean(%q) = %q, want %q", in, got, want)
		}
	}
	if pyJoin("/a/", "b") != "/a/b" || pyJoin("/a", "b") != "/a/b" {
		t.Error("pyJoin")
	}
	dir := t.TempDir()
	tool := filepath.Join(dir, "tool")
	writeScript(t, tool, "#!/bin/sh\n")
	t.Setenv("PATH", "/nonexistent:"+dir+":"+dir)
	if got := which("tool"); got != tool {
		t.Fatalf("which = %q", got)
	}
	t.Setenv("PATH", "")
	if which("tool") != "" {
		t.Fatal("empty PATH must find nothing")
	}
}

func TestVerifiedUserBus(t *testing.T) {
	// Unix socket paths are limited; keep the directory short and private.
	dir, err := os.MkdirTemp(os.Getenv("TMPDIR"), "b")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if len(dir) > 90 {
		t.Skip("temporary directory path too long for a unix socket")
	}
	os.Chmod(dir, 0o700)
	listener, err := net.Listen("unix", filepath.Join(dir, "bus"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if got := verifiedUserBus(dir); got != "unix:path="+dir+"/bus" {
		t.Fatalf("private bus: %q", got)
	}
	os.Chmod(dir, 0o750)
	if got := verifiedUserBus(dir); got != "" {
		t.Fatalf("group-readable runtime directory admitted: %q", got)
	}
	if verifiedUserBus(filepath.Join(dir, "missing")) != "" {
		t.Fatal("missing directory admitted")
	}
}

type codedError struct{ code string }

func (e codedError) Error() string { return e.code }
func (e codedError) Code() string  { return e.code }

func TestRunOperationBoundaries(t *testing.T) {
	store := newMemoryStore()
	open := func() (*Journal, error) { return OpenJournal(store, nil, nil) }
	if _, err := RunOperation(context.Background(), open, "rotate", []byte(`{}`)); err == nil {
		t.Fatal("unknown operation accepted")
	}
	out, err := RunOperation(context.Background(), open, "status", []byte(`{}`))
	if err != nil || !strings.HasSuffix(string(out), "\n") || !strings.Contains(string(out), `"status":"ready"`) || !store.closed {
		t.Fatalf("%s %v closed=%v", out, err, store.closed)
	}
	failing := func() (*Journal, error) { return nil, codedError{"journal_permissions"} }
	out, _ = RunOperation(context.Background(), failing, "status", []byte(`{}`))
	if string(out) != `{"code":"journal_permissions","status":"failed","v":1}`+"\n" {
		t.Fatal(string(out))
	}
	out, _ = RunOperation(context.Background(), func() (*Journal, error) { return nil, errors.New("disk") }, "status", []byte(`{}`))
	if string(out) != `{"code":"journal_or_backend_unavailable","status":"failed","v":1}`+"\n" {
		t.Fatal(string(out))
	}
	// Parsing precedes opening the journal, as in main().
	out, _ = RunOperation(context.Background(), failing, "status", []byte(`{`))
	if !strings.Contains(string(out), "invalid_json") {
		t.Fatal(string(out))
	}
	out, _ = RunOperation(context.Background(), failing, "status", make([]byte, 262145))
	if !strings.Contains(string(out), "request_too_large") {
		t.Fatal(string(out))
	}
}

func TestJournalStoreFailures(t *testing.T) {
	store := newMemoryStore()
	journal, err := OpenJournal(store, func(ctx context.Context, request any) any {
		r := request.(obj)
		return obj{"v": int64(1), "operation_id": r["operation_id"], "status": "draft", "provider": "anthropic_api", "model": apiModel,
			"binding": r["binding"], "source_sha256": sha256Hex(r["evidence"].(string)), "draft": validDraft(),
			"usage": obj{"input_tokens": parseJSON("1180591620717411303424"), "output_tokens": int64(1)}}
	}, func() time.Time { return time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	run := func(fn func() any) obj {
		var result obj
		func() {
			defer func() {
				if value := recover(); value != nil {
					draft, exception := recoverPy(value)
					result = obj{"draft": draft, "exception": exception}
				}
			}()
			result = obj{"ok": fn()}
		}()
		return result
	}
	run(func() any { return journal.Configure(opID, enabledSettings(nil), nil) })
	// A failed commit rolls back the configuration change.
	store.failNext = errors.New("disk full")
	result := run(func() any {
		return journal.Configure(opID2, enabledSettings(obj{"max_requests_per_day": int64(7)}), nil)
	})
	if result["exception"] == nil || store.InTransaction() {
		t.Fatalf("commit failure: %v", result)
	}
	if id, _, _, _ := store.Settings(); id != opID {
		t.Fatalf("rolled-back configuration persisted: %s", id)
	}
	if _, found, _ := store.ConfigurationChange(opID2); found {
		t.Fatal("rolled-back configuration change persisted")
	}
	// A charge beyond sqlite's INTEGER range fails the outcome update, leaving
	// the reservation pending for reconciliation exactly as Python does.
	result = run(func() any { return journal.Submit(context.Background(), submitRequest(opID3, "evidence")) })
	if result["exception"] == nil {
		t.Fatalf("overflowing charge accepted: %v", result)
	}
	status := run(func() any { return journal.Status(opID3) })["ok"].(obj)
	if status["status"] != "pending" || status["charged_microusd"] != int64(apiReservationMicroUSD) {
		t.Fatalf("overflow left %v", status)
	}
	// Lone surrogates cannot be stored, as sqlite3 cannot bind them.
	result = run(func() any { return journal.Configure(opID2, enabledSettings(obj{"codex_model": "ok"}), nil) })
	if result["ok"] == nil {
		t.Fatalf("plain configure failed: %v", result)
	}
	if code, _ := expectDraft(t, func() { journal.Configure(opID, enabledSettings(nil), "\xed\xa0\x80") }); code != "invalid_operation_id" {
		t.Fatal(code)
	}
}

func TestSurrogateHelpers(t *testing.T) {
	lone := "a\xed\xa0\x80b"
	if !hasSurrogate(lone) || hasSurrogate("aé\U0001F600") || pyLen(lone) != 3 || pyLen("é😀") != 2 {
		t.Fatal("surrogate accounting")
	}
	if code, _ := expectDraft(t, func() {}); code != "" {
		t.Fatal(code)
	}
	defer func() {
		if value := recover(); value != (pyException{"UnicodeEncodeError"}) {
			t.Fatalf("encode did not raise: %v", value)
		}
	}()
	encodeUTF8(lone)
}
