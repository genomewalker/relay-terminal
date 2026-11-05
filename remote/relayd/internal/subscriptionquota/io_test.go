package subscriptionquota

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testReader(t testing.TB) *Reader {
	t.Helper()
	r := &Reader{home: t.TempDir(), uid: uint32(os.Getuid()), env: func(string) (string, bool) { return "", false }, now: func() time.Time { return fixtureNow }, platform: "linux", client: &http.Client{}, usageURL: "https://quota.invalid/usage", connect: openReadSocket}
	r.credentials = r.readCredentials
	return r
}
func putPrivate(t testing.TB, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, mustJSON(t, value), 0600); err != nil {
		t.Fatal(err)
	}
}
func shortDir(t testing.TB) string {
	t.Helper()
	path, err := os.MkdirTemp("/tmp", "qs-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(path) })
	return path
}
func setIdentities(t testing.TB, r *Reader) {
	t.Helper()
	putPrivate(t, filepath.Join(r.home, ".codex/auth.json"), map[string]any{"tokens": map[string]any{"account_id": "codex-account-☃"}, "access_token": "never-export-token"})
	putPrivate(t, filepath.Join(r.home, ".claude.json"), map[string]any{"oauthAccount": map[string]any{"accountUuid": "claude-account", "organizationUuid": "claude-org", "emailAddress": "never-export@example.invalid"}})
}

func TestPrivateFilesFailClosed(t *testing.T) {
	r := testReader(t)
	path := filepath.Join(r.home, "private.json")
	putPrivate(t, path, map[string]any{"observed": true})
	if _, err := privateFile(path, Limit, r.uid); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(path, Limit, r.uid+1); err == nil {
		t.Fatal("foreign owner admitted")
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(path, Limit, r.uid); err == nil {
		t.Fatal("public file admitted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(r.home, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(link, Limit, r.uid); err == nil {
		t.Fatal("symlink admitted")
	}
	if _, err := privateFile(r.home, Limit, r.uid); err == nil {
		t.Fatal("directory admitted")
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte(" "), Limit+1), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(path, Limit, r.uid); err == nil {
		t.Fatal("oversize private file admitted")
	}
}

// The real private-file admission path is checked after every state transition.
// Two labelled writers interleave private/public/symlink updates, length <=3.
func TestBoundedPrivateFileAdmissionInterleavings(t *testing.T) {
	r := testReader(t)
	path := filepath.Join(r.home, "observation.json")
	outside := filepath.Join(r.home, "target.json")
	putPrivate(t, outside, map[string]any{"safe": false})
	states, sequences := 0, 0
	for depth := 1; depth <= 3; depth++ {
		count := 1
		for i := 0; i < depth; i++ {
			count *= 6
		}
		for encoded := 0; encoded < count; encoded++ {
			sequences++
			n := encoded
			for step := 0; step < depth; step++ {
				symbol := n % 6
				n /= 6
				operation := symbol % 3
				_ = os.Remove(path)
				if operation == 2 {
					if err := os.Symlink(outside, path); err != nil {
						t.Fatal(err)
					}
				} else {
					putPrivate(t, path, map[string]any{"safe": true})
					if operation == 1 {
						if err := os.Chmod(path, 0644); err != nil {
							t.Fatal(err)
						}
					}
				}
				for _, uid := range []uint32{r.uid, r.uid + 1} {
					_, err := privateFile(path, Limit, uid)
					want := operation == 0 && uid == r.uid
					if (err == nil) != want {
						t.Fatalf("file admission changed at actor=%d op=%d uid=%d", symbol/3, operation, uid)
					}
					states++
				}
			}
		}
	}
	if sequences != 258 || states != 1452 {
		t.Fatalf("bound changed: %d %d", sequences, states)
	}
	t.Logf("quota file admission: alphabet=6 (3 operations x 2 actors), depth<=3 sequences=%d checked-transitions=%d", sequences, states)
}

func TestAccountScopesAndOverridesNeverExportIdentity(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	if got := r.accountScope("codex"); got != identityDigest([]any{"codex", "codex-account-☃"}) {
		t.Fatal("Codex account identity changed")
	}
	if got := r.accountScope("claude"); got != identityDigest([]any{"claude", "claude-account", "claude-org"}) {
		t.Fatal("Claude account identity changed")
	}
	override := filepath.Join(r.home, "override")
	r.env = func(key string) (string, bool) {
		if key == "CODEX_HOME" || key == "CLAUDE_CONFIG_DIR" {
			return override, true
		}
		return "", false
	}
	putPrivate(t, filepath.Join(override, "auth.json"), map[string]any{"tokens": map[string]any{"account_id": "different"}})
	putPrivate(t, filepath.Join(override, ".claude.json"), map[string]any{"oauthAccount": map[string]any{"accountUuid": "different", "organizationUuid": "org"}})
	if r.accountScope("codex") != identityDigest([]any{"codex", "different"}) || r.accountScope("claude") != identityDigest([]any{"claude", "different", "org"}) {
		t.Fatal("account override lost")
	}
}

func TestPrivateFileSnapshotRejectsReplacedInode(t *testing.T) {
	r := testReader(t)
	a, b := filepath.Join(r.home, "first.json"), filepath.Join(r.home, "second.json")
	putPrivate(t, a, map[string]any{"x": 1})
	putPrivate(t, b, map[string]any{"x": 1})
	if err := os.Chtimes(a, fixtureNow, fixtureNow); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(b, fixtureNow, fixtureNow); err != nil {
		t.Fatal(err)
	}
	first, err := os.Stat(a)
	if err != nil {
		t.Fatal(err)
	}
	second, err := os.Stat(b)
	if err != nil {
		t.Fatal(err)
	}
	if !privateSnapshotMatches(first, first, first, r.uid) {
		t.Fatal("unchanged private snapshot refused")
	}
	if privateSnapshotMatches(first, second, first, r.uid) || privateSnapshotMatches(first, first, second, r.uid) {
		t.Fatal("changed file inode was admitted")
	}
}

func TestClaudeUsageUsesReadOnlyTLSAndNeverRedirects(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	credentials := map[string]any{"claudeAiOauth": map[string]any{"accessToken": "synthetic-access-token", "scopes": []any{"user:profile"}, "subscriptionType": "max"}}
	r.credentials = func(context.Context) ([]byte, error) { return mustJSON(t, credentials), nil }
	var requests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		if req.Method != "GET" || req.URL.Path != "/usage" || req.Header.Get("Authorization") != "Bearer synthetic-access-token" || req.Header.Get("anthropic-beta") != "oauth-2025-04-20" || req.Header.Get("User-Agent") != "Relay/0.5.2" {
			t.Error("usage request changed")
		}
		raw, _ := io.ReadAll(req.Body)
		if len(raw) != 0 {
			t.Error("usage request submitted a body")
		}
		w.Write([]byte(`{"five_hour":{"utilization":25,"resets_at":"2026-10-25T08:30:00Z"}}`))
	}))
	defer server.Close()
	r.client = server.Client()
	r.usageURL = server.URL + "/usage"
	value, err := r.claudeUsage(context.Background())
	if err != nil || value == nil || requests.Load() != 1 {
		t.Fatalf("usage read failed: %v", err)
	}
	encoded := mustJSON(t, value)
	if bytes.Contains(encoded, []byte("synthetic-access-token")) || bytes.Contains(encoded, []byte("never-export@")) {
		t.Fatal("credential/identity leaked")
	}
	object(credentials["claudeAiOauth"])["scopes"] = []any{"other"}
	if value, err := r.claudeUsage(context.Background()); err != nil || value != nil || requests.Load() != 1 {
		t.Fatal("unscoped token was sent")
	}
	object(credentials["claudeAiOauth"])["scopes"] = []any{"user:profile"}
	var redirected atomic.Int32
	destination := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) { redirected.Add(1) }))
	defer destination.Close()
	redirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, destination.URL, http.StatusFound)
	}))
	defer redirect.Close()
	r.client = redirect.Client()
	r.usageURL = redirect.URL
	if _, err := r.claudeUsage(context.Background()); err == nil || redirected.Load() != 0 {
		t.Fatal("usage credential followed redirect")
	}
}

func TestReadCombinesBoundedCachesWithCurrentIdentity(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	dir := filepath.Join(r.home, ".local/share/relay/claude-status")
	for i := 0; i < 20; i++ {
		path := filepath.Join(dir, fmt.Sprintf("session-%02d.json", i))
		putPrivate(t, path, map[string]any{"session_id": fmt.Sprintf("session-%d", i), "account_scope": "old-scope", "rate_limits": map[string]any{}, "captured_at": "2026-10-25T07:00:00Z", "secret": "discard-me"})
		when := fixtureNow.Add(time.Duration(i) * time.Second)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
	}
	putPrivate(t, filepath.Join(dir, "ABC-123.json"), map[string]any{"pane_id": "abc-123", "session_id": "pane-report", "account_scope": "pane-scope", "captured_at": "2026-10-25T07:00:00Z"})
	putPrivate(t, filepath.Join(dir, "def.json"), map[string]any{"pane_id": "wrong", "session_id": "wrong-pane"})
	panes := []string{"ABC-123", "def", "../escape"}
	data, err := r.Read(context.Background(), panes)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if json.Unmarshal(data, &rows) != nil || len(rows) != 19 {
		t.Fatalf("cache bounds changed: %s", data)
	}
	if object(rows[0]["observation"])["session_id"] != "session-19" || object(rows[15]["observation"])["session_id"] != "session-4" || object(rows[16]["observation"])["session_id"] != "pane-report" {
		t.Fatal("newest-first/session/pane behavior changed")
	}
	if bytes.Contains(data, []byte("discard-me")) || bytes.Contains(data, []byte("never-export")) || bytes.Contains(data, []byte("wrong-pane")) {
		t.Fatal("cache projection leaked extra or wrong-pane fields")
	}
	for i, provider := range []string{"codex", "claude"} {
		row := rows[len(rows)-2+i]
		if row["provider"] != provider || row["identity_only"] != true || row["account_scope"] != r.accountScope(provider) {
			t.Fatal("current identity rows missing")
		}
	}
	putPrivate(t, filepath.Join(dir, "aaa.json"), map[string]any{"pane_id": "aaa", "session_id": "beyond-cap"})
	panes = make([]string, 129)
	for i := 0; i < 128; i++ {
		panes[i] = "invalid/path"
	}
	panes[128] = "aaa"
	data, err = r.Read(context.Background(), panes)
	if err != nil || bytes.Contains(data, []byte("beyond-cap")) {
		t.Fatal("pane count bound lost")
	}
}

func TestStatusCapturePrivateAtomicAndCommandForwarding(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	raw := []byte("{\"session_id\":\"abcdef-1234\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":1800000000}},\"secret\":\"not-cached\"}\n")
	var stdout, stderr bytes.Buffer
	code, err := r.RunStatusline(context.Background(), base64.StdEncoding.EncodeToString([]byte("cat; printf fixture-error >&2; exit 7")), bytes.NewReader(raw), &stdout, &stderr)
	if err != nil || code != 7 || !bytes.Equal(stdout.Bytes(), raw) || stderr.String() != "fixture-error" {
		t.Fatalf("status command forwarding changed: code=%d err=%v", code, err)
	}
	path := filepath.Join(r.home, ".local/share/relay/claude-status/session-abcdef-1234.json")
	value, err := privateFile(path, Limit, r.uid)
	if err != nil {
		t.Fatal(err)
	}
	if value["account_scope"] != r.accountScope("claude") || value["session_id"] != "abcdef-1234" || value["captured_at"] != captureTime(fixtureNow) || value["secret"] != nil {
		t.Fatal("status capture contract changed")
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("status cache not private")
	}
	if err := os.Chmod(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := r.CaptureStatus(raw); err == nil {
		t.Fatal("public status directory accepted")
	}
	stdout.Reset()
	stderr.Reset()
	invalid := []byte("not JSON\n")
	if code, err := r.RunStatusline(context.Background(), "Y2F0", bytes.NewReader(invalid), &stdout, &stderr); err != nil || code != 0 || !bytes.Equal(stdout.Bytes(), invalid) {
		t.Fatal("failed capture prevented user command")
	}
	stdout.Reset()
	large := bytes.Repeat([]byte("x"), Limit+8)
	if code, err := r.RunStatusline(context.Background(), "Y2F0", bytes.NewReader(large), &stdout, &stderr); err != nil || code != 0 || !bytes.Equal(stdout.Bytes(), large[:Limit+1]) {
		t.Fatal("legacy bounded statusline stdin prefix changed")
	}
}

func readClientFrame(r io.Reader) (byte, []byte, error) {
	var h [2]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return 0, nil, err
	}
	if h[1]&0x80 == 0 {
		return 0, nil, errors.New("client frame is unmasked")
	}
	n := uint64(h[1] & 127)
	if n == 126 {
		var b [2]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, nil, err
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	} else if n == 127 {
		var b [8]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, nil, err
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	if n > Limit {
		return 0, nil, errors.New("oversize client frame")
	}
	var mask [4]byte
	if _, err := io.ReadFull(r, mask[:]); err != nil {
		return 0, nil, err
	}
	data := make([]byte, n)
	if _, err := io.ReadFull(r, data); err != nil {
		return 0, nil, err
	}
	for i := range data {
		data[i] ^= mask[i%4]
	}
	return h[0] & 15, data, nil
}

func quotaServer(t *testing.T, result map[string]any) (string, <-chan []string) {
	t.Helper()
	path := filepath.Join(shortDir(t), "control.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	done := make(chan []string, 1)
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		r := bufio.NewReader(conn)
		request, err := http.ReadRequest(r)
		if err != nil {
			t.Error(err)
			return
		}
		conn.Write(upgrade(request.Header.Get("Sec-WebSocket-Key")))
		methods := []string{}
		for len(methods) < 3 {
			opcode, raw, err := readClientFrame(r)
			if err != nil {
				t.Error(err)
				return
			}
			if opcode == 10 {
				continue
			}
			value, err := decodeObject(raw, Limit)
			if err != nil {
				t.Error(err)
				return
			}
			method := text(value["method"])
			methods = append(methods, method)
			switch method {
			case "initialize":
				conn.Write(frame(9, []byte("quota-ping")))
				conn.Write(frame(1, []byte(`{"id":"1","result":{"wrong":true}}`)))
				conn.Write(frame(1, []byte(`{"id":999,"result":{"wrong":true}}`)))
				conn.Write(frame(1, []byte(`{"id":1,"result":{}}`)))
			case "initialized":
			case "account/rateLimits/read":
				conn.Write(frame(1, mustJSON(t, map[string]any{"id": 2, "result": result})))
			default:
				t.Errorf("unexpected provider method %q", method)
				return
			}
		}
		done <- methods
	}()
	return path, done
}

func TestCodexExistingSocketReadsOnlyWhitelistedRPCs(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	result := map[string]any{"rateLimits": map[string]any{"primary": map[string]any{"usedPercent": 25}}, "rateLimitsByLimitId": map[string]any{}, "rateLimitResetCredits": map[string]any{"availableCount": 2}, "access_token": "not-exported"}
	path, done := quotaServer(t, result)
	r.env = func(k string) (string, bool) {
		if k == "CODEX_APP_SERVER_CONTROL_SOCKET" {
			return path, true
		}
		return "", false
	}
	data, err := r.Read(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if json.Unmarshal(data, &rows) != nil || len(rows) != 3 {
		t.Fatalf("missing socket observation: %s", data)
	}
	obs := object(rows[0]["observation"])
	if rows[0]["provider"] != "codex" || len(obs) != 3 || obs["access_token"] != nil || rows[0]["account_scope"] != r.accountScope("codex") {
		t.Fatal("socket projection/account scope changed")
	}
	select {
	case methods := <-done:
		if !reflect.DeepEqual(methods, []string{"initialize", "initialized", "account/rateLimits/read"}) {
			t.Fatalf("provider was launched/used beyond observation: %v", methods)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("socket server did not finish")
	}
	client, server := net.Pipe()
	s := &readSocket{ctx: context.Background(), conn: client, reader: bufio.NewReader(client)}
	defer s.close()
	go func() {
		defer server.Close()
		if _, _, err := readClientFrame(server); err == nil {
			_, _ = server.Write(frame(1, []byte(`{"id":3,"result":{}}`)))
		}
	}()
	if _, err := s.rpc(3, "thread/start", map[string]any{}); err == nil {
		t.Fatal("non-observation RPC admitted")
	}
}

func TestSocketPrivateOwnerSymlinkPeerAndInodeFences(t *testing.T) {
	dir := shortDir(t)
	path := filepath.Join(dir, "socket")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Getuid())
	if _, _, err := privateSocket(path, uid); err != nil {
		t.Fatal(err)
	}
	if _, _, err := privateSocket(path, uid+1); err == nil {
		t.Fatal("foreign socket owner admitted")
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, _, err := privateSocket(path, uid); err == nil {
		t.Fatal("public socket admitted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "alias")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, _, err := privateSocket(link, uid); err != nil || got != canonical {
		t.Fatal("private owned socket link refused")
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := privateSocket(link, uid); err == nil {
		t.Fatal("unsafe socket symlink parent admitted")
	}
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if checkPeer(conn.(*net.UnixConn), uid) != nil || checkPeer(conn.(*net.UnixConn), uid+1) == nil {
		t.Fatal("kernel peer UID fence lost")
	}
	peer, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	peer.Close()
	conn.Close()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		peer, err := listener.Accept()
		if err != nil {
			return
		}
		defer peer.Close()
		_ = peer.SetDeadline(time.Now().Add(time.Second))
		request, err := http.ReadRequest(bufio.NewReader(peer))
		if err != nil {
			return
		}
		_, _ = peer.Write(upgrade(request.Header.Get("Sec-WebSocket-Key")))
	}()
	var replacement net.Listener
	client, err := openReadSocketWithDial(context.Background(), path, uid, func(ctx context.Context, address string) (net.Conn, error) {
		c, e := net.Dial("unix", address)
		if e != nil {
			return nil, e
		}
		if e = os.Remove(address); e != nil {
			return nil, e
		}
		replacement, e = net.Listen("unix", address)
		if e != nil {
			return nil, e
		}
		os.Chmod(address, 0600)
		return c, nil
	})
	if replacement != nil {
		defer replacement.Close()
	}
	if client != nil {
		client.close()
	}
	if err == nil {
		t.Fatal("replaced socket inode admitted")
	}
	<-serverDone
}

func TestSocketCancellationBoundsHandshake(t *testing.T) {
	path := filepath.Join(shortDir(t), "stall")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	os.Chmod(path, 0600)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, err = http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			return
		}
		cancel()
		io.Copy(io.Discard, conn)
	}()
	var calls atomic.Int32
	started := time.Now()
	_, err = openReadSocketWithDial(ctx, path, uint32(os.Getuid()), func(ctx context.Context, address string) (net.Conn, error) {
		c, e := net.Dial("unix", address)
		calls.Add(1)
		return c, e
	})
	if err == nil || calls.Load() != 1 || time.Since(started) >= time.Second {
		t.Fatal("canceled handshake was admitted")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancellation did not close socket promptly")
	}
}

func TestCaptureCannotWriteThroughDirectorySymlink(t *testing.T) {
	r := testReader(t)
	outside := t.TempDir()
	// Keep the target private so only the symlink/anchoring fence can refuse
	// this write; a public target would let the permission fence mask a bug.
	if err := os.Chmod(outside, 0700); err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(r.home, ".local/share/relay")
	if err := os.MkdirAll(parent, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(parent, "claude-status")); err != nil {
		t.Fatal(err)
	}
	if err := r.CaptureStatus([]byte(`{"session_id":"abcdef"}`)); err == nil {
		t.Fatal("status directory symlink admitted")
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("status write escaped directory")
	}
}

func TestCaptureIdentifierCannotEscapeDirectory(t *testing.T) {
	r := testReader(t)
	for _, id := range []string{"../escape", "a/b", strings.Repeat("a", 111)} {
		raw := mustJSON(t, map[string]any{"session_id": id})
		if err := r.CaptureStatus(raw); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(r.home, ".local")); !os.IsNotExist(err) {
		t.Fatal("invalid identifier wrote state")
	}
}
