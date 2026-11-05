package codexmcphealth

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type fakeRuntime struct {
	o               Options
	start           string
	identity        Identity
	owns            bool
	loaded          []any
	thread          map[string]any
	calls           []string
	reloads, checks int
	changeAt        int
	change          string
	failReload      bool
	responses       map[string]map[string]any
	closed          bool
}

func newRuntime() *fakeRuntime {
	o := Options{PID: 12, Start: "123", Thread: "thread", Socket: "/private/control", Cwd: "/work", Server: "relayDesktopR"}
	return &fakeRuntime{o: o, start: o.Start, identity: Identity{1, 2}, owns: true, loaded: []any{o.Thread}, thread: map[string]any{"id": o.Thread, "cwd": o.Cwd, "status": map[string]any{"type": "idle"}}}
}
func (r *fakeRuntime) tick() {
	r.checks++
	if r.checks == r.changeAt {
		switch r.change {
		case "start":
			r.start = "different"
		case "inode":
			r.identity.Inode++
		}
	}
}
func (r *fakeRuntime) Validate(o Options) error {
	r.tick()
	if r.start != o.Start {
		return errors.New("changed")
	}
	return nil
}
func (r *fakeRuntime) Start(int) (string, error)                    { r.tick(); return r.start, nil }
func (r *fakeRuntime) PrivateSocket(string) (Identity, error)       { r.tick(); return r.identity, nil }
func (r *fakeRuntime) OwnsListener(int, string) (bool, error)       { r.tick(); return r.owns, nil }
func (r *fakeRuntime) Connect(context.Context, string) (RPC, error) { r.tick(); return r, nil }
func (r *fakeRuntime) Close() error                                 { r.closed = true; return nil }
func (r *fakeRuntime) Call(method string, params any) (map[string]any, error) {
	r.tick()
	r.calls = append(r.calls, method)
	if reply, ok := r.responses[method]; ok {
		return reply, nil
	}
	switch method {
	case "initialize":
		return map[string]any{}, nil
	case "thread/loaded/list":
		return map[string]any{"data": r.loaded}, nil
	case "thread/read":
		p, ok := params.(map[string]any)
		found := false
		for _, id := range r.loaded {
			if p["threadId"] == id {
				found = true
			}
		}
		if !ok || !found || p["includeTurns"] != false || len(p) != 2 {
			return nil, errors.New("unexpected read params")
		}
		return map[string]any{"thread": r.thread}, nil
	case "config/mcpServer/reload":
		r.reloads++
		if r.failReload {
			return nil, errors.New("ambiguous write")
		}
		return map[string]any{}, nil
	case "mcpServerStatus/list":
		if !reflect.DeepEqual(params, map[string]any{"threadId": r.o.Thread, "serverName": r.o.Server, "limit": 100, "detail": "toolsAndAuthOnly"}) {
			return nil, errors.New("unbounded status params")
		}
		return map[string]any{"data": []any{map[string]any{"name": "relayDesktopR", "tools": map[string]any{"one": map[string]any{}}, "runtimeStatus": "ready"}}}, nil
	}
	return nil, fmt.Errorf("forbidden method %s", method)
}
func TestHealthAuthorityBounded(t *testing.T) {
	states := 0
	for mask := 0; mask < 256; mask++ {
		r := newRuntime()
		r.o.Refresh = mask&1 != 0
		r.o.InspectLoaded = mask&2 != 0
		r.owns = mask&4 == 0
		if mask&8 != 0 {
			r.loaded = append(r.loaded, "other")
		}
		if mask&16 != 0 {
			r.thread["status"] = map[string]any{"type": "active"}
		}
		if mask&32 != 0 {
			r.thread["id"] = "different"
		}
		if mask&64 != 0 {
			r.thread["cwd"] = "/foreign"
		}
		if mask&128 != 0 {
			r.loaded = []any{}
		}
		_, _ = Inspect(context.Background(), r.o, r)
		want := r.o.Refresh && !r.o.InspectLoaded && mask&(4|8|16|32|64|128) == 0
		if (r.reloads == 1) != want {
			t.Fatalf("refresh authority state %08b: reloads=%d", mask, r.reloads)
		}
		if r.reloads > 1 {
			t.Fatal("refresh repeated")
		}
		for _, m := range r.calls {
			if strings.Contains(m, "turn/") || m == "thread/start" || m == "thread/resume" {
				t.Fatal("model operation")
			}
		}
		states++
	}
	t.Logf("real Inspect authority states=%d", states)
}
func TestHealthTwoActorIdentityInterleavings(t *testing.T) {
	states := 0
	for _, change := range []string{"start", "inode"} {
		for at := 1; at <= 12; at++ {
			r := newRuntime()
			r.o.Refresh = true
			r.change = change
			r.changeAt = at
			_, e := Inspect(context.Background(), r.o, r)
			lastRead := 10
			if change == "inode" {
				lastRead = 11
			}
			if at >= 3 && at <= lastRead && r.reloads != 0 {
				t.Fatalf("changed %s at step %d dispatched reload", change, at)
			}
			if at == 1 && change == "start" && e == nil {
				t.Fatal("initial source mismatch accepted")
			}
			if at == 12 && r.reloads == 0 {
				t.Fatal("positive control must reach final request")
			}
			states++
		}
	}
	t.Logf("two actors: inspector order versus one identity replacement, %d interleavings; trusts snapshot RPC values", states)
}
func TestHealthNoRetryAfterAmbiguousReload(t *testing.T) {
	r := newRuntime()
	r.o.Refresh = true
	r.failReload = true
	_, e := Inspect(context.Background(), r.o, r)
	if e == nil || r.reloads != 1 || !r.closed {
		t.Fatalf("ambiguous reload retried or connection leaked: %v %d %v", e, r.reloads, r.closed)
	}
	if r.calls[len(r.calls)-1] != "config/mcpServer/reload" {
		t.Fatal("continued after ambiguous mutation")
	}
}
func TestHealthInspectionLimit(t *testing.T) {
	for _, n := range []int{0, 100, 101} {
		r := newRuntime()
		r.o.InspectLoaded = true
		r.loaded = make([]any, n)
		for i := range r.loaded {
			r.loaded[i] = r.o.Thread
		}
		_, e := Inspect(context.Background(), r.o, r)
		if (e != nil) != (n > 100) {
			t.Fatalf("inventory bound %d: %v", n, e)
		}
		if r.reloads != 0 {
			t.Fatal("inspection mutated")
		}
	}
}
func TestPrivateSocketMetadata(t *testing.T) {
	root, e := os.MkdirTemp("/tmp", "mcp-health-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "sock")
	l, e := net.Listen("unix", path)
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	if e = os.Chmod(path, 0600); e != nil {
		t.Fatal(e)
	}
	r := NativeRuntime{}
	identity, e := r.PrivateSocket(path)
	if e != nil || identity.Inode == 0 {
		t.Fatalf("private socket: %v", e)
	}
	for _, mode := range []os.FileMode{0601, 0640, 0660, 0755} {
		if e = os.Chmod(path, mode); e != nil {
			t.Fatal(e)
		}
		if _, e = r.PrivateSocket(path); e == nil {
			t.Fatalf("public socket accepted: %o", mode)
		}
	}
	_ = os.Chmod(path, 0600)
	_ = os.Chmod(root, 0755)
	if _, e = r.PrivateSocket(path); e == nil {
		t.Fatal("public parent accepted")
	}
	_ = os.Chmod(root, 0700)
	link := filepath.Join(root, "link")
	if e = os.Symlink(path, link); e != nil {
		t.Fatal(e)
	}
	if _, e = r.PrivateSocket(link); e == nil {
		t.Fatal("symlink socket accepted")
	}
	regular := filepath.Join(root, "regular")
	_ = os.WriteFile(regular, []byte("x"), 0600)
	if _, e = r.PrivateSocket(regular); e == nil {
		t.Fatal("regular file accepted")
	}
}
func TestEndpointIdentity(t *testing.T) {
	for _, tc := range []struct {
		args []string
		env  map[string]string
		want string
		bad  bool
	}{{[]string{"codex", "--remote=unix:///a/control"}, nil, "/a/control", false}, {[]string{"codex", "--remote", "unix:///a%20b/control"}, nil, "/a%20b/control", false}, {[]string{"--remote=unix:///a", "--remote=unix:///b"}, nil, "", true}, {[]string{"--remote=tcp://localhost:2"}, nil, "", true}, {[]string{"--remote=unix://host/path"}, nil, "", true}, {[]string{"--remote=unix:///path?q=1"}, nil, "", true}, {nil, map[string]string{"HOME": "/home/u"}, "/home/u/.codex/app-server-control/app-server-control.sock", false}, {nil, map[string]string{"CODEX_HOME": "/private", "HOME": "/home/u"}, "/private/app-server-control/app-server-control.sock", false}} {
		got, e := ExpectedEndpoint(tc.args, tc.env)
		if (e != nil) != tc.bad || got != tc.want {
			t.Fatalf("endpoint %v: %q %v", tc.args, got, e)
		}
	}
}
func FuzzProcessParsers(f *testing.F) {
	f.Add("1 (codex) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 123", "unix:///tmp/a")
	f.Add("x", "unix://foreign/a")
	f.Fuzz(func(t *testing.T, stat, remote string) {
		if len(stat) > 16384 || len(remote) > 4096 {
			return
		}
		_, _ = ParseStart(stat)
		_, e := ExpectedEndpoint([]string{"--remote=" + remote, "--remote=unix:///other"}, nil)
		if e == nil {
			t.Fatal("ambiguous endpoints accepted")
		}
		got, e := ExpectedEndpoint([]string{"--remote=" + remote}, nil)
		if e == nil && (!strings.HasPrefix(strings.ToLower(remote), "unix:") || strings.Contains(got, "?")) {
			t.Fatal("non-Unix endpoint admitted")
		}
		if _, e := ParseStart("1 (x)"); e == nil {
			t.Fatal("truncated identity accepted")
		}
		inodes := ListenerInodes(stat, "/never-generated-target")
		for k := range inodes {
			if !strings.HasPrefix(k, "socket:[") {
				t.Fatal("invalid inode mapping")
			}
		}
	})
}

func TestProcessOwnershipAndListenerParse(t *testing.T) {
	for _, tc := range []struct {
		owner uint32
		exe   string
		want  bool
	}{{123, "/opt/codex", true}, {124, "/opt/codex", false}, {123, "/opt/other", false}, {123, "/opt/codex (deleted)", false}} {
		if ownedCodex(tc.owner, tc.exe, 123) != tc.want {
			t.Fatal("owned exact executable authority")
		}
	}
	stat := "12 (name ) with parenthesis) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 start-value"
	if value, e := ParseStart(stat); e != nil || value != "start-value" {
		t.Fatal("last-parenthesis start identity", value, e)
	}
	raw := "Num Ref Protocol Flags Type St Inode Path\n000: 2 0 00010000 0001 01 42 /tmp/a  b\n001: 2 0 00000000 0001 01 43 /tmp/a  b\n002: 2 0 00010000 0001 01 44 /tmp/other\n"
	got := ListenerInodes(raw, "/tmp/a  b")
	if len(got) != 1 || !got["socket:[42]"] {
		t.Fatal("listener path/flag/inode selection", got)
	}
	if _, e := ExpectedEndpoint([]string{"--remote=unix://user@/private"}, nil); e == nil {
		t.Fatal("authority URL accepted")
	}
}

func TestAmbiguousEndpointCannotFallBackToHome(t *testing.T) {
	for _, argv := range [][]string{{"codex", "--remote=unix:///first", "--remote=unix:///second"}, {"codex", "--remote", "unix:///first", "--remote=unix:///second"}} {
		if got, e := ExpectedEndpoint(argv, map[string]string{"HOME": "/home/owned", "CODEX_HOME": "/private/owned"}); e == nil {
			t.Fatalf("ambiguous endpoint silently fell back to source HOME: %s", got)
		}
	}
}
