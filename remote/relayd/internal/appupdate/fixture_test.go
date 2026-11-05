package appupdate

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func put(t *testing.T, p string, b []byte, mode os.FileMode) {
	t.Helper()
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(p, b, mode); e != nil {
		t.Fatal(e)
	}
}
func escaped(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&apos;", "\r", "&#13;").Replace(s)
}

func plistStrings(m map[string]string) []byte {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><plist version="1.0"><dict>`)
	for k, v := range m {
		b.WriteString("<key>" + escaped(k) + "</key><string>" + escaped(v) + "</string>")
	}
	b.WriteString("</dict></plist>")
	return []byte(b.String())
}
func fixtureCopy(src, dst string) error {
	info, e := os.Lstat(src)
	if e != nil {
		return e
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, e := os.Readlink(src)
		if e != nil {
			return e
		}
		return os.Symlink(target, dst)
	}
	if info.IsDir() {
		if e = os.MkdirAll(dst, info.Mode().Perm()); e != nil {
			return e
		}
		entries, e := os.ReadDir(src)
		if e != nil {
			return e
		}
		for _, d := range entries {
			if e = fixtureCopy(filepath.Join(src, d.Name()), filepath.Join(dst, d.Name())); e != nil {
				return e
			}
		}
		return nil
	}
	in, e := os.Open(src)
	if e != nil {
		return e
	}
	defer in.Close()
	if e = os.MkdirAll(filepath.Dir(dst), 0700); e != nil {
		return e
	}
	out, e := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if e != nil {
		return e
	}
	_, e = io.Copy(out, in)
	closeErr := out.Close()
	if e == nil {
		e = closeErr
	}
	return e
}

type fakeWatcher struct {
	registered             []int
	events                 [][]int
	registerErr, errorWait error
	onWait                 func()
	closed                 bool
}

func (w *fakeWatcher) Register(pid int) error {
	w.registered = append(w.registered, pid)
	return w.registerErr
}
func (w *fakeWatcher) Wait(_ int, _ time.Duration) ([]int, error) {
	if w.onWait != nil {
		w.onWait()
	}
	if w.errorWait != nil {
		return nil, w.errorWait
	}
	if len(w.events) == 0 {
		return nil, nil
	}
	r := w.events[0]
	w.events = w.events[1:]
	return r, nil
}
func (w *fakeWatcher) Close() error { w.closed = true; return nil }

type fixture struct {
	t               *testing.T
	e               *Engine
	root, candidate string
	workspace, live map[string]any
	body            atomic.Value
	ui              []int
	ident           map[int]string
	calls           []Command
	watch           *fakeWatcher
	onQuit          func()
	onCopy          func(string, string)
	sign            func(string) error
	dittoFail       bool
	dittoCorrupt    bool
	opened          int
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, root: root, candidate: filepath.Join(root, "candidate/Relay.app"), ident: map[int]string{100: "kernel-provider-100", 200: "kernel-supervisor-200", 300: "kernel-worker-300", 400: "kernel-shell-400"}, watch: &fakeWatcher{}}
	f.workspace = map[string]any{"panes": []any{map[string]any{"id": "PANE"}}, "tabs": []any{map[string]any{"id": "TAB", "splitRatios": []any{"A", jsonNumber("0.3"), "B", jsonNumber("0.7")}}}, "sessionNames": []any{"S", "Session"}, "selectedTabID": "TAB", "activePaneID": "PANE"}
	f.live = map[string]any{"selectedPaneID": "PANE", "sessions": []any{map[string]any{"tabs": []any{map[string]any{"id": "TAB", "panes": []any{map[string]any{"id": "PANE"}}}}}}}
	f.publish()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Token") != "private-fixture-token" {
			http.Error(w, "auth", 401)
			return
		}
		w.Write(f.body.Load().([]byte))
	}))
	t.Cleanup(server.Close)
	f.e = &Engine{Config: Config{Home: filepath.Join(root, "home"), Installed: filepath.Join(root, "Applications/Relay.app"), TempRoot: filepath.Join(root, "tmp"), LockRoot: filepath.Join(root, "locks"), APIURL: server.URL, UID: os.Getuid()}, Now: func() time.Time { return time.Unix(1800000000, 0) }, Client: server.Client(), Watch: func() (Watcher, error) { return f.watch, nil }}
	for _, p := range []string{f.e.Config.TempRoot, f.e.Config.LockRoot} {
		if e := os.MkdirAll(p, 0700); e != nil {
			t.Fatal(e)
		}
	}
	f.e.Kernel = func(pid int) (string, error) {
		id, ok := f.ident[pid]
		if !ok {
			return "", errors.New("fixture process absent")
		}
		return id, nil
	}
	f.e.Run = f.run
	for path, data := range map[string]string{f.e.Config.Installed: "old", f.candidate: "new"} {
		put(t, filepath.Join(path, "Contents/MacOS/Relay"), []byte(data), 0700)
		put(t, filepath.Join(path, "Contents/MacOS/relayd"), []byte("daemon"), 0700)
		put(t, filepath.Join(path, "Contents/Info.plist"), plistStrings(map[string]string{"CFBundleIdentifier": "dev.relay.terminal"}), 0600)
	}
	f.saveWorkspace(true)
	put(t, filepath.Join(f.e.support(), "AgentDrafts/draft.txt"), []byte("private draft"), 0600)
	put(t, filepath.Join(f.e.support(), "caller-control-v1.json"), []byte(`{"owner":"fixture","audit":[1,2]}`), 0600)
	put(t, filepath.Join(f.e.Config.Home, ".local/state/relay/workers/worker.json"), []byte(`{"worker_pid":300,"shell_pid":400}`), 0600)
	return f
}
func jsonNumber(s string) any {
	v, e := parseJSON([]byte(s))
	if e != nil {
		panic(e)
	}
	return v
}
func (f *fixture) publish() { f.body.Store(jsonData(f.live)) }
func (f *fixture) saveWorkspace(shared bool) {
	put(f.t, f.e.preferences(), plistStrings(map[string]string{"relay.workspace.v1": string(jsonData(f.workspace)), "relay.side-panel-token.v1": "private-fixture-token"}), 0600)
	p := filepath.Join(f.e.support(), "Workspace/workspace-v1.json")
	if shared {
		put(f.t, p, jsonData(f.workspace), 0600)
	} else {
		os.Remove(p)
	}
}
func (f *fixture) run(c Command) ([]byte, error) {
	f.calls = append(f.calls, c)
	a := c.Args
	switch a[0] {
	case "/bin/ps":
		var b strings.Builder
		for _, pid := range f.ui {
			fmt.Fprintf(&b, "%d %s\n", pid, filepath.Join(f.e.Config.Installed, "Contents/MacOS/Relay"))
		}
		b.WriteString("100 /fixture/bin/codex\n300 /fixture/bin/relayd\n400 /bin/zsh\n")
		return []byte(b.String()), nil
	case "/usr/bin/codesign":
		if f.sign != nil {
			return nil, f.sign(a[len(a)-1])
		}
		return nil, nil
	case "/bin/cp":
		src, dst := a[len(a)-2], a[len(a)-1]
		e := fixtureCopy(src, dst)
		if f.onCopy != nil {
			f.onCopy(src, dst)
		}
		return nil, e
	case "/usr/bin/xattr":
		return nil, nil
	case "/usr/bin/ditto":
		if f.dittoFail {
			return nil, errors.New("fixture copy failed")
		}
		e := fixtureCopy(a[1], a[2])
		if f.dittoCorrupt {
			put(f.t, filepath.Join(a[2], "Contents/MacOS/Relay"), []byte("wrong"), 0700)
		}
		return nil, e
	case "/usr/bin/osascript":
		if f.onQuit != nil {
			f.onQuit()
		} else {
			f.ui = nil
		}
		return nil, nil
	case "/usr/bin/open":
		f.opened++
		return nil, nil
	default:
		if filepath.Base(a[0]) == "relayd" && len(a) > 1 && a[1] == "live-status" {
			return []byte("RELAYD_LIVE\t200\n"), nil
		}
		return nil, fmt.Errorf("unexpected fixture command: %v", a)
	}
}
func (f *fixture) stage() string {
	f.t.Helper()
	r, e := f.e.Stage(StageOptions{Candidate: f.candidate, UIClosed: true})
	if e != nil {
		f.t.Fatal(e)
	}
	return r["root"].(string)
}
func (f *fixture) applied() string {
	f.t.Helper()
	root := f.stage()
	if _, e := f.e.Apply(root); e != nil {
		f.t.Fatal(e)
	}
	return root
}
func (f *fixture) binary() string {
	b, _ := os.ReadFile(filepath.Join(f.e.Config.Installed, "Contents/MacOS/Relay"))
	return string(b)
}
