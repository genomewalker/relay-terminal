package appupdate

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestBoundedInstallOwnership(t *testing.T) {
	transitions := 0
	for a := 0; a < 4; a++ {
		for b := 0; b < 4; b++ {
			for c := 0; c < 4; c++ {
				f := newFixture(t)
				root := f.stage()
				applied, verified, tampered := false, false, false
				for _, op := range []int{a, b, c} {
					before := f.binary()
					switch op {
					case 0:
						_, e := f.e.Apply(root)
						want := !applied && !tampered
						if (e == nil) != want {
							t.Fatal("bounded apply authority violated", a, b, c, op, e)
						}
						if want {
							applied = true
						}
					case 1:
						_, e := f.e.Verify(root)
						want := applied && !verified
						if (e == nil) != want {
							t.Fatal("bounded verification authority violated", a, b, c, e)
						}
						if want {
							verified = true
						}
					case 2:
						put(t, filepath.Join(root, "Relay.app/Contents/MacOS/Relay"), []byte("tampered"), 0700)
						tampered = true
					case 3:
						guard, e := lockFile(f.e.globalLock(), f.e.Config.UID)
						if e != nil {
							t.Fatal(e)
						}
						_, e = f.e.Apply(root)
						guard.Close()
						if e == nil {
							t.Fatal("bounded lock ownership bypassed")
						}
					}
					want := "old"
					if applied {
						want = "new"
					}
					if f.binary() != want {
						t.Fatal("bounded operation lost installed bytes", before, f.binary())
					}
					for pid, id := range f.ident {
						if id != fmt.Sprintf("kernel-%s-%d", map[int]string{100: "provider", 200: "supervisor", 300: "worker", 400: "shell"}[pid], pid) {
							t.Fatal("bounded operation altered process")
						}
					}
					transitions++
				}
			}
		}
	}
	if transitions != 192 {
		t.Fatal("bounded install depth reduced")
	}
	t.Log("4 operations, 64 length-3 sequences, 192 transitions against actual stage/apply/verify/locks")
}
func TestTwoActorUpdateInterleavings(t *testing.T) {
	schedules := [][]int{{0, 0, 1, 1}, {0, 1, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, 1}, {1, 0, 1, 0}, {1, 1, 0, 0}}
	transitions := 0
	for _, s := range schedules {
		f := newFixture(t)
		roots := [2]string{}
		stagedAt := [2]string{}
		for _, actor := range s {
			if roots[actor] == "" {
				stagedAt[actor] = f.binary()
				roots[actor] = f.stage()
			} else {
				before := f.binary()
				_, e := f.e.Apply(roots[actor])
				want := before == stagedAt[actor]
				if (e == nil) != want {
					t.Fatal("two-actor CAS ownership violated", s, e)
				}
				if e != nil && f.binary() != before {
					t.Fatal("rejected actor overwrote winner")
				}
			}
			if f.binary() != "old" && f.binary() != "new" {
				t.Fatal("partial installed bundle exposed")
			}
			transitions++
		}
	}
	if transitions != 24 {
		t.Fatal("interleaving bound changed")
	}
	t.Log("all 6 two-actor stage/apply interleavings; 24 transitions; actual global flock/CAS replacement")
}
func TestBoundedReceiptAuthority(t *testing.T) {
	states := 0
	for mode := 0; mode < 2; mode++ {
		for owner := 0; owner < 2; owner++ {
			for symlink := 0; symlink < 2; symlink++ {
				for held := 0; held < 2; held++ {
					f := newFixture(t)
					root := f.stage()
					if mode == 1 {
						os.Chmod(root, 0755)
					}
					if owner == 1 {
						f.e.Config.UID = os.Getuid() + 1
					}
					if symlink == 1 {
						p := filepath.Join(root, "baseline.json")
						b, _ := os.ReadFile(p)
						os.Remove(p)
						target := filepath.Join(f.root, "external-baseline")
						put(t, target, b, 0600)
						os.Symlink(target, p)
					}
					var guard *os.File
					if held == 1 {
						var e error
						guard, e = lockFile(f.e.globalLock(), os.Getuid())
						if e != nil {
							t.Fatal(e)
						}
					}
					_, e := f.e.Apply(root)
					if guard != nil {
						guard.Close()
					}
					want := mode == 0 && owner == 0 && symlink == 0 && held == 0
					if (e == nil) != want {
						t.Fatal("receipt authority matrix violated", mode, owner, symlink, held, e)
					}
					if !want && f.binary() != "old" {
						t.Fatal("invalid receipt mutated app")
					}
					states++
				}
			}
		}
	}
	if states != 16 {
		t.Fatal("receipt bound reduced")
	}
	t.Log("16 receipt states: privacy x owner x nofollow x competing global lock")
}
func TestStateHTTPBounds(t *testing.T) {
	f := newFixture(t)
	f.body.Store([]byte(`{"padding":"` + strings.Repeat("x", maxState) + `"}`))
	if _, e := f.e.state(); e == nil {
		t.Fatal("state HTTP byte bound ignored")
	}
	f.body.Store([]byte(`{"sessions":[],"sessions":[]}`))
	if _, e := f.e.state(); e == nil {
		t.Fatal("ambiguous HTTP state accepted")
	}
}
func TestFocusIsObservedSeparately(t *testing.T) {
	f := newFixture(t)
	root := f.applied()
	f.workspace["activePaneID"] = nil
	f.workspace["selectedTabID"] = nil
	f.saveWorkspace(true)
	f.live["selectedPaneID"] = nil
	f.publish()
	r, e := f.e.Verify(root)
	if e != nil {
		t.Fatal(e)
	}
	if r["focusRetained"] != false || r["savedFocusMatchesLive"] != true {
		t.Fatal("focus observation changed structural acceptance")
	}
}
func TestBundleContainment(t *testing.T) {
	f := newFixture(t)
	outside := filepath.Join(f.root, "external")
	put(t, outside, []byte("secret"), 0600)
	os.Symlink(outside, filepath.Join(f.candidate, "Contents/escape"))
	if _, e := Hashes(f.candidate); e == nil {
		t.Fatal("bundle path escaped root")
	}
}
func FuzzUpdateJSON(f *testing.F) {
	for _, s := range []string{`{"a":[1,true,null]}`, `{"a":1,"a":2}`, `{"a":`, "\xff"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		v, e := parseJSON(b)
		if e != nil {
			return
		}
		if len(b) > maxState {
			t.Fatal("state size bound ignored")
		}
		encoded := jsonData(v)
		round, e := parseJSON(encoded)
		if e != nil || !equal(v, round) {
			t.Fatal("state JSON round trip changed")
		}
		wrapped := append(append([]byte(`{"value":`), encoded...), '}')
		if _, e = parseJSON(wrapped[:len(wrapped)-1]); e == nil {
			t.Fatal("truncated state accepted")
		}
	})
}
func FuzzUpdatePlist(f *testing.F) {
	for _, s := range []string{"plain", "x&y", "é", "<tag>", "\x00"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 65536 {
			return
		}
		b := plistStrings(map[string]string{"value": s})
		m, e := parsePlist(b)
		if e != nil {
			return
		}
		if m["value"] != s {
			t.Fatal("plist round trip changed")
		}
		if _, e = parsePlist(b[:len(b)-1]); e == nil {
			t.Fatal("truncated plist accepted")
		}
	})
}
func FuzzUpdateProcessRows(f *testing.F) {
	for _, s := range []string{"1 /app\n2 /worker\n", "0 /bad", "1 /a\n1 /b", "1 /path with spaces"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := parseProcesses(b)
		if e != nil {
			return
		}
		var out strings.Builder
		for pid, cmd := range m {
			if pid <= 0 || pid > 1<<31-1 {
				t.Fatal("process id bounds lost")
			}
			fmt.Fprintf(&out, "%d %s\n", pid, cmd)
		}
		round, e := parseProcesses([]byte(out.String()))
		if e != nil || !reflect.DeepEqual(m, round) {
			t.Fatal("process listing round trip changed")
		}
	})
}
func FuzzUpdateLayout(f *testing.F) {
	for _, s := range []string{`{"tabs":[],"panes":[]}`, `{"sessionNames":["s","name"],"activePaneID":"p"}`, `{"tabs":[{"splitRatios":["x",0.5]}]}`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := object(b)
		if e != nil {
			return
		}
		v, e := Layout(m)
		if e != nil {
			return
		}
		round, e := Layout(v)
		if e != nil || !equal(v, round) {
			t.Fatal("layout normalization not idempotent")
		}
		if _, ok := v["activePaneID"]; ok {
			t.Fatal("focus leaked into structural layout")
		}
	})
}
func FuzzUpdateAudit(f *testing.F) {
	f.Add([]byte(`{"owner":"A","audit":[1,2]}`))
	f.Add([]byte(`{"audit":[]}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		m, e := object(b)
		if e != nil {
			return
		}
		if _, e = auditArray(m); e != nil {
			return
		}
		if e = AuditContinuity(m, m); e != nil {
			t.Fatal("unchanged audit rejected")
		}
		changed, e := object(jsonData(m))
		if e != nil {
			return
		}
		changed["owner-proof"] = "changed"
		if _, exists := m["owner-proof"]; !exists && AuditContinuity(m, changed) == nil {
			t.Fatal("caller ownership change accepted")
		}
	})
}
func TestCommandOutputBound(t *testing.T) {
	var b limitedBuffer
	b.Write(make([]byte, maxState+1))
	if !b.overflow || b.Len() > maxState {
		t.Fatal("command output bound ignored")
	}
}
