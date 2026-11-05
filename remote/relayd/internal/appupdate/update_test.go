package appupdate

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestPrimaryOracle(t *testing.T) {
	raw, e := os.ReadFile("testdata/oracle.json")
	if e != nil {
		t.Fatal(e)
	}
	v, e := parseJSON(raw)
	if e != nil {
		t.Fatal(e)
	}
	cases := v.([]any)
	if len(cases) != 22 {
		t.Fatal("primary fixture count changed")
	}
	for _, v := range cases {
		c := v.(map[string]any)
		t.Run(c["kind"].(string)+"/"+c["name"].(string), func(t *testing.T) {
			args := c["args"].([]any)
			var value any
			var err error
			switch c["kind"] {
			case "layout":
				value, err = Layout(args[0].(map[string]any))
			case "normalized_focus":
				value = NormalizedFocus(args[0].(map[string]any))
			case "live_focus":
				value, err = LiveFocus(args[0].(map[string]any))
			case "pane_ids":
				var p []string
				p, err = PaneIDs(args[0].(map[string]any))
				a := []any{}
				for _, s := range p {
					a = append(a, s)
				}
				value = a
			case "audit":
				err = AuditContinuity(args[0], args[1])
				value = true
			}
			if (err == nil) != c["ok"].(bool) {
				t.Fatalf("primary acceptance differs: %v", err)
			}
			if err == nil && !equal(value, c["value"]) {
				t.Fatalf("primary value differs: got=%v want=%v", value, c["value"])
			}
		})
	}
}
func TestOriginalProcessSelection(t *testing.T) {
	f := newFixture(t)
	f.e.Run = func(Command) ([]byte, error) {
		return []byte("1 " + f.e.Config.Installed + "/Contents/MacOS/Relay\n2 " + f.e.Config.Installed + "/Contents/MacOS/relayd\n3 /tmp/Other.app/Contents/MacOS/Relay\n"), nil
	}
	p, e := f.e.AppPIDs(f.e.Config.Installed)
	if e != nil || !reflect.DeepEqual(p, []int{1}) {
		t.Fatal("worker or unrelated UI selected", p, e)
	}
}
func TestOriginalAbsentQuit(t *testing.T) {
	f := newFixture(t)
	if e := f.e.Quit(f.e.Config.Installed, time.Second); e != nil {
		t.Fatal(e)
	}
	for _, c := range f.calls {
		if c.Args[0] != "/bin/ps" {
			t.Fatal("absent quit launched or signalled process")
		}
	}
}
func TestAbsentRestartLaunches(t *testing.T) {
	f := newFixture(t)
	if _, e := f.e.Restart(RestartOptions{Timeout: 1}); e != nil {
		t.Fatal(e)
	}
	if f.opened != 1 {
		t.Fatal("successful restart must launch even when initially absent")
	}
	for _, c := range f.calls {
		if c.Args[0] == "/usr/bin/osascript" {
			t.Fatal("absent restart asked UI to quit")
		}
	}
}
func TestQuitEvents(t *testing.T) {
	for _, mode := range []string{"exit", "timeout", "replacement", "registration_gone", "registration_error"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			f.ui = []int{10}
			f.onQuit = func() {}
			f.watch.events = [][]int{{10}}
			f.watch.onWait = func() { f.ui = nil }
			want := true
			switch mode {
			case "timeout":
				f.watch.events = nil
				want = false
			case "replacement":
				f.watch.onWait = func() { f.ui = []int{11} }
				want = false
			case "registration_gone":
				f.watch.registerErr = os.ErrProcessDone
				f.onQuit = func() { f.ui = nil }
			case "registration_error":
				f.watch.registerErr = errors.New("fixture")
				want = false
			}
			err := f.e.Quit(f.e.Config.Installed, time.Second)
			if (err == nil) != want {
				t.Fatal("quit event outcome changed", err)
			}
			if !f.watch.closed {
				t.Fatal("process event handle leaked")
			}
			if f.opened != 0 {
				t.Fatal("quit helper opened app")
			}
			for _, c := range f.calls {
				if c.Args[0] == "/usr/bin/osascript" {
					if c.Timeout != 3*time.Second || !strings.Contains(strings.Join(c.Args, " "), `tell application id "dev.relay.terminal" to quit`) {
						t.Fatal("graceful quit command changed")
					}
				}
			}
		})
	}
}
func TestFullPrivateLifecycle(t *testing.T) {
	for _, shared := range []bool{true, false} {
		t.Run(map[bool]string{true: "shared", false: "preferences"}[shared], func(t *testing.T) {
			f := newFixture(t)
			f.saveWorkspace(shared)
			r, e := f.e.Stage(StageOptions{Candidate: f.candidate})
			if e != nil {
				t.Fatal(e)
			}
			root := r["root"].(string)
			if f.binary() != "old" {
				t.Fatal("stage mutated installed app")
			}
			b, e := f.e.baseline(root)
			if e != nil || len(b.Identities) != 4 {
				t.Fatal("kernel identity set lost", e)
			}
			if _, e = f.e.Apply(root); e != nil {
				t.Fatal(e)
			}
			if f.binary() != "new" {
				t.Fatal("apply did not install staged bytes")
			}
			if _, e = f.e.Verify(root); e != nil {
				t.Fatal(e)
			}
			for _, n := range []string{"baseline.json", "quit-state.json", "applied.json", "verified.json", "before-preferences.plist", "quit-preferences.plist"} {
				s, e := os.Stat(filepath.Join(root, n))
				if e != nil || s.Mode().Perm() != 0600 {
					t.Fatal("receipt privacy changed", n, e)
				}
			}
			old, _ := os.ReadFile(filepath.Join(root, "previous-Relay.app/Contents/MacOS/Relay"))
			if string(old) != "old" {
				t.Fatal("previous bundle not preserved")
			}
			for _, c := range f.calls {
				if c.Args[0] == "/usr/bin/open" || c.Args[0] == "/usr/bin/osascript" || strings.Contains(c.Args[0], "kill") {
					t.Fatal("preservation helper controlled a process")
				}
			}
		})
	}
}
func TestStageGuards(t *testing.T) {
	for _, mode := range []string{"panes", "focus", "duplicate", "identifier", "override", "clone", "signature", "ui_open"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			o := StageOptions{Candidate: f.candidate}
			switch mode {
			case "panes":
				f.live["sessions"] = []any{}
				f.publish()
			case "focus":
				f.live["selectedPaneID"] = "OTHER"
				f.publish()
			case "duplicate":
				f.workspace["panes"] = append(f.workspace["panes"].([]any), map[string]any{"id": "pane"})
				f.saveWorkspace(true)
			case "identifier":
				put(t, filepath.Join(f.candidate, "Contents/Info.plist"), plistStrings(map[string]string{"CFBundleIdentifier": "other"}), 0600)
			case "override":
				put(t, filepath.Join(f.candidate, "Contents/Info.plist"), plistStrings(map[string]string{"CFBundleIdentifier": "dev.relay.terminal", "RelayDefaultsSuite": "isolated"}), 0600)
			case "clone":
				f.onCopy = func(src, dst string) {
					if src == f.candidate {
						put(t, filepath.Join(dst, "Contents/MacOS/Relay"), []byte("changed"), 0700)
					}
				}
			case "signature":
				f.sign = func(string) error { return errors.New("bad signature") }
			case "ui_open":
				f.ui = []int{10}
				o.UIClosed = true
			}
			if _, e := f.e.Stage(o); e == nil {
				t.Fatal("unsafe stage accepted")
			}
			if f.binary() != "old" {
				t.Fatal("rejected stage changed installed bytes")
			}
		})
	}
}
func TestApplyGuardsAndRollback(t *testing.T) {
	for _, mode := range []string{"installed", "staged", "ui", "identity", "panes", "authority", "copy", "signature", "copied_hash", "replay"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			root := f.stage()
			want := "old"
			switch mode {
			case "installed":
				put(t, filepath.Join(f.e.Config.Installed, "Contents/MacOS/Relay"), []byte("foreign"), 0700)
				want = "foreign"
			case "staged":
				put(t, filepath.Join(root, "Relay.app/Contents/MacOS/Relay"), []byte("changed"), 0700)
			case "ui":
				f.ui = []int{10}
			case "identity":
				f.ident[100] = "reused-pid"
			case "panes":
				f.workspace["panes"] = []any{map[string]any{"id": "OTHER"}}
				f.saveWorkspace(true)
			case "authority":
				os.Remove(filepath.Join(f.e.support(), "Workspace/workspace-v1.json"))
			case "copy":
				f.dittoFail = true
			case "signature":
				f.sign = func(p string) error {
					if p == f.e.Config.Installed {
						return errors.New("installed signature rejected")
					}
					return nil
				}
			case "copied_hash":
				f.dittoCorrupt = true
			case "replay":
				if _, e := f.e.Apply(root); e != nil {
					t.Fatal(e)
				}
				want = "new"
			}
			if _, e := f.e.Apply(root); e == nil {
				t.Fatal("unsafe or repeated apply accepted")
			}
			if f.binary() != want {
				t.Fatal("apply failure changed or failed to restore previous bundle", f.binary())
			}
		})
	}
}
func TestVerifyContinuity(t *testing.T) {
	for _, mode := range []string{"drafts", "layout", "owner", "audit", "identity", "hash", "panes", "authority"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			root := f.applied()
			switch mode {
			case "drafts":
				put(t, filepath.Join(f.e.support(), "AgentDrafts/draft.txt"), []byte("changed"), 0600)
			case "layout":
				f.workspace["sessionNames"] = []any{"S", "renamed"}
				f.saveWorkspace(true)
			case "owner":
				put(t, filepath.Join(f.e.support(), "caller-control-v1.json"), []byte(`{"owner":"foreign","audit":[1,2]}`), 0600)
			case "audit":
				put(t, filepath.Join(f.e.support(), "caller-control-v1.json"), []byte(`{"owner":"fixture","audit":[2,1]}`), 0600)
			case "identity":
				f.ident[200] = "changed"
			case "hash":
				put(t, filepath.Join(f.e.Config.Installed, "Contents/MacOS/Relay"), []byte("changed"), 0700)
			case "panes":
				f.live["sessions"] = []any{}
				f.publish()
			case "authority":
				os.Remove(filepath.Join(f.e.support(), "Workspace/workspace-v1.json"))
			}
			if _, e := f.e.Verify(root); e == nil {
				t.Fatal("continuity failure verified")
			}
			if _, e := os.Stat(filepath.Join(root, "verified.json")); !os.IsNotExist(e) {
				t.Fatal("failed verification wrote success receipt")
			}
		})
	}
}
func TestRestartCandidateCASRollback(t *testing.T) {
	for _, mode := range []string{"valid", "candidate_change", "installed_change", "signature"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			f.ui = []int{10}
			f.onQuit = func() {
				f.ui = nil
				if mode == "candidate_change" {
					put(t, filepath.Join(f.candidate, "Contents/MacOS/Relay"), []byte("changed"), 0700)
				}
				if mode == "installed_change" {
					put(t, filepath.Join(f.e.Config.Installed, "Contents/MacOS/Relay"), []byte("foreign"), 0700)
				}
			}
			if mode == "signature" {
				f.sign = func(p string) error {
					if p == f.e.Config.Installed && f.binary() == "new" {
						return errors.New("new signature bad")
					}
					return nil
				}
			}
			_, e := f.e.Restart(RestartOptions{Candidate: f.candidate, Timeout: 1})
			if (e == nil) != (mode == "valid") {
				t.Fatal("restart CAS/rollback outcome changed", e)
			}
			want := "old"
			if mode == "valid" {
				want = "new"
			}
			if mode == "installed_change" {
				want = "foreign"
			}
			if f.binary() != want {
				t.Fatal("restart failed to preserve expected installed bundle")
			}
			if (f.opened == 1) != (mode == "valid") {
				t.Fatal("failed candidate update launched")
			}
		})
	}
}
func TestRestartPreservationTraceRecovery(t *testing.T) {
	for _, failure := range []bool{false, true} {
		f := newFixture(t)
		root := f.stage()
		f.ui = []int{10}
		f.dittoFail = failure
		trace := filepath.Join(root, "terminal-replay-trace.log")
		_, e := f.e.Restart(RestartOptions{Preservation: root, Trace: trace, Timeout: 1})
		if (e != nil) != failure {
			t.Fatal("preserving restart outcome changed", e)
		}
		if f.opened != 1 {
			t.Fatal("success or verified-original recovery did not reopen")
		}
		s, e := os.Stat(trace)
		if e != nil || s.Mode().Perm() != 0600 {
			t.Fatal("replay trace privacy changed")
		}
		last := f.calls[len(f.calls)-1].Args
		if !failure && !reflect.DeepEqual(last, []string{"/usr/bin/open", "-a", f.e.Config.Installed, "--env", "RELAY_REPLAY_TRACE=1", "--stderr", trace}) {
			t.Fatal("trace launch binding changed")
		}
		want := "new"
		if failure {
			want = "old"
		}
		if f.binary() != want {
			t.Fatal("preserving restart rollback failed")
		}
	}
}
func TestTraceAndTimeoutBounds(t *testing.T) {
	for _, mode := range []string{"outside", "wrong_name", "existing", "symlink", "low_timeout", "high_timeout"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			root := f.stage()
			o := RestartOptions{Preservation: root, Trace: filepath.Join(root, "terminal-replay-trace.log"), Timeout: 1}
			switch mode {
			case "outside":
				o.Trace = filepath.Join(f.root, "terminal-replay-trace.log")
			case "wrong_name":
				o.Trace = filepath.Join(root, "other.log")
			case "existing":
				put(t, o.Trace, []byte("keep"), 0600)
			case "symlink":
				os.Symlink(filepath.Join(f.root, "absent"), o.Trace)
			case "low_timeout":
				o.Timeout = 0
			case "high_timeout":
				o.Timeout = 61
			}
			if _, e := f.e.Restart(o); e == nil {
				t.Fatal("unsafe trace/timeout accepted")
			}
			if f.binary() != "old" || f.opened != 0 {
				t.Fatal("rejected trace/timeout mutated or launched")
			}
		})
	}
}
func TestPrivateLocksAndReceipts(t *testing.T) {
	f := newFixture(t)
	root := f.stage()
	lock, e := lockFile(f.e.globalLock(), f.e.Config.UID)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = f.e.Apply(root); e == nil {
		t.Fatal("concurrent owner bypassed lock")
	}
	lock.Close()
	os.Remove(f.e.globalLock())
	target := filepath.Join(f.root, "foreign-lock")
	put(t, target, []byte("keep"), 0600)
	if e = os.Symlink(target, f.e.globalLock()); e != nil {
		t.Fatal(e)
	}
	if _, e = f.e.Apply(root); e == nil {
		t.Fatal("nofollow lock accepted symlink")
	}
	b, _ := os.ReadFile(target)
	if string(b) != "keep" {
		t.Fatal("foreign lock overwritten")
	}
	os.Remove(f.e.globalLock())
	os.Chmod(root, 0755)
	if _, e = f.e.Apply(root); e == nil {
		t.Fatal("public receipt accepted")
	}
	os.Chmod(root, 0700)
	baseline := filepath.Join(root, "baseline.json")
	raw, _ := os.ReadFile(baseline)
	os.Remove(baseline)
	put(t, target, raw, 0600)
	os.Symlink(target, baseline)
	if _, e = f.e.Apply(root); e == nil {
		t.Fatal("nofollow receipt accepted symlink")
	}
}
func TestParsersStrict(t *testing.T) {
	for _, s := range []string{`{"x":1,"x":2}`, `{} {}`, `{"x":`, strings.Repeat("[", 66) + "0" + strings.Repeat("]", 66), `{"n":1e99999}`, "{\"x\":\"\xff\"}"} {
		if _, e := parseJSON([]byte(s)); e == nil {
			t.Fatal("unsafe JSON accepted")
		}
	}
	if _, e := parseJSON([]byte(`{"padding":"` + strings.Repeat("x", maxState) + `"}`)); e == nil {
		t.Fatal("JSON byte bound ignored")
	}
	for _, s := range []string{`<plist><dict><key>x</key><string>a</string><key>x</key><string>b</string></dict></plist>`, `<plist><dict><key>x</key></dict></plist>`, `<plist><dict/></plist><plist><dict/></plist>`} {
		if _, e := parsePlist([]byte(s)); e == nil {
			t.Fatal("unsafe plist accepted")
		}
	}
	if _, e := parseProcesses([]byte("1 /a\n1 /b")); e == nil {
		t.Fatal("ambiguous process listing accepted")
	}
}
func TestCLIUsage(t *testing.T) {
	for _, c := range []struct {
		kind string
		args []string
	}{{"bad", nil}, {"preserve", nil}, {"preserve", []string{"apply"}}, {"restart", []string{"--timeout", "0"}}} {
		var b bytes.Buffer
		if CLI(c.kind, c.args, &b, &b) != 2 {
			t.Fatal("CLI usage must exit two")
		}
	}
	for _, kind := range []string{"restart", "preserve"} {
		var b bytes.Buffer
		if CLI(kind, []string{"--help"}, &b, &b) != 0 {
			t.Fatal("help must succeed")
		}
	}
}
func TestWorkerSlotsAndNativeReceipt(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.e.Config.Home, ".local/state/relay/workers/empty.json"), []byte(`{"worker_pid":0,"shell_pid":null}`), 0600)
	root := f.stage()
	b, e := f.e.baseline(root)
	if e != nil || len(b.Identities) != 4 {
		t.Fatal("empty worker slots changed tracked identities")
	}
	b.Version = 1
	os.Remove(filepath.Join(root, "baseline.json"))
	if e = writeRecord(filepath.Join(root, "baseline.json"), b); e != nil {
		t.Fatal(e)
	}
	if _, e = f.e.Apply(root); e == nil {
		t.Fatal("legacy identity receipt accepted")
	}
}
func TestReceiptRootBounds(t *testing.T) {
	for _, mode := range []string{"prefix", "parent", "external_link"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			root := f.stage()
			moved := filepath.Join(f.e.Config.TempRoot, "wrong-prefix")
			if mode != "prefix" {
				moved = filepath.Join(f.root, filepath.Base(root))
			}
			if e := os.Rename(root, moved); e != nil {
				t.Fatal(e)
			}
			if mode == "external_link" {
				if e := os.Symlink(moved, root); e != nil {
					t.Fatal(e)
				}
			} else {
				root = moved
			}
			if _, e := f.e.Apply(root); e == nil {
				t.Fatal("receipt root escaped private namespace")
			}
			if f.binary() != "old" {
				t.Fatal("invalid root changed installed app")
			}
		})
	}
}
