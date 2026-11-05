package desktoproute

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func privateTemp(t *testing.T) string {
	t.Helper()
	p, e := os.MkdirTemp("/tmp", "dr-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(p) })
	return p
}
func TestReceiptReplayArchiveAndMonotonicity(t *testing.T) {
	root := privateTemp(t)
	config := filepath.Join(root, "route.json")
	now := time.Unix(42, 0)
	if ok, e := updateReceipt(config, "unknown", "read_acknowledged", false, now); e != nil || ok {
		t.Fatal("unknown message gained read receipt", ok, e)
	}
	if _, e := updateReceipt(config, "first", "pending", true, now); e != nil {
		t.Fatal(e)
	}
	if _, e := updateReceipt(config, "first", "pending", true, now); !errors.Is(e, errReplay) {
		t.Fatal("replay admitted", e)
	}
	if _, e := updateReceipt(config, "first", "read_acknowledged", false, now); e != nil {
		t.Fatal(e)
	}
	if _, e := updateReceipt(config, "first", "unknown", false, now); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 257; i++ {
		if _, e := updateReceipt(config, fmt.Sprintf("id-%d", i), "pending", true, now); e != nil {
			t.Fatal(e)
		}
	}
	if _, e := updateReceipt(config, "first", "pending", true, now); !errors.Is(e, errReplay) {
		t.Fatal("evicted message replay admitted", e)
	}
	if _, e := updateReceipt(config, "first", "written_to_socket", false, now); e != nil {
		t.Fatal(e)
	}
	path, _ := receiptPath(config)
	var rows []Receipt
	if e := readJSONFile(path, 65536, &rows); e != nil {
		t.Fatal(e)
	}
	if len(rows) > 256 {
		t.Fatal("ledger unbounded")
	}
	if rows[len(rows)-1].Status != "read_acknowledged" {
		t.Fatal("acknowledgment downgraded after eviction")
	}
	st, e := os.Stat(path)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("ledger not private")
	}
}
func TestPrivateFilesRejectLinksAndOversize(t *testing.T) {
	root := privateTemp(t)
	file := filepath.Join(root, "record")
	if e := os.WriteFile(file, []byte("{}"), 0600); e != nil {
		t.Fatal(e)
	}
	link := filepath.Join(root, "link")
	os.Symlink(file, link)
	if _, e := privateRead(link, 100, 0077); e == nil {
		t.Fatal("symlink admitted")
	}
	os.Chmod(file, 0644)
	if _, e := privateRead(file, 100, 0077); e == nil {
		t.Fatal("public file admitted")
	}
	os.Chmod(file, 0600)
	if _, e := privateRead(file, 1, 0077); e == nil {
		t.Fatal("oversize file admitted")
	}
	dirlink := filepath.Join(root, "directory-link")
	os.Symlink(root, dirlink)
	if privateDirectory(dirlink, false) == nil {
		t.Fatal("directory symlink admitted")
	}
}
func TestReceiptBoundedTwoActorSequences(t *testing.T) {
	// Every length-three sequence over two actors x {reserve,write,ack}. Both
	// actors address the same ID; compare the production durable ledger after
	// every step with the independent at-most-once/monotonic model.
	root := privateTemp(t)
	sequences, steps := 0, 0
	for encoded := 0; encoded < 216; encoded++ {
		directory := filepath.Join(root, fmt.Sprint(encoded))
		if e := os.Mkdir(directory, 0700); e != nil {
			t.Fatal(e)
		}
		path := filepath.Join(directory, "r.json")
		reserved, acked := false, false
		n := encoded
		for depth := 0; depth < 3; depth++ {
			op := n % 6
			n /= 6
			_ = op / 3
			kind := op % 3
			create := kind == 0
			status := []string{"pending", "written_to_socket", "read_acknowledged"}[kind]
			ok, e := updateReceipt(path, "same-id", status, create, time.Unix(int64(depth), 0))
			if create {
				if reserved {
					if !errors.Is(e, errReplay) {
						t.Fatalf("sequence %d replay escaped", encoded)
					}
				} else {
					if e != nil || !ok {
						t.Fatal(e)
					}
					reserved = true
				}
			} else {
				if e != nil || ok != reserved {
					t.Fatalf("sequence %d unknown receipt acquired state", encoded)
				}
				if reserved && kind == 2 {
					acked = true
				}
			}
			receipt, _ := receiptPath(path)
			var rows []Receipt
			if exists(receipt) {
				if e := readJSONFile(receipt, 65536, &rows); e != nil {
					t.Fatal(e)
				}
			}
			if len(rows) > 1 || (!reserved && len(rows) != 0) || (reserved && len(rows) != 1) {
				t.Fatal("reservation cardinality escaped")
			}
			if acked && rows[0].Status != "read_acknowledged" {
				t.Fatal("read receipt downgraded")
			}
			steps++
		}
		sequences++
	}
	t.Logf("bound=3 alphabet=6 actors=2 sequences=%d transitions=%d", sequences, steps)
}
func TestRememberHandoffAndExplicitRebind(t *testing.T) {
	home := privateTemp(t)
	var commands [][]string
	r := &runtime{home: home, exe: "/Applications/Relay.app/Contents/MacOS/relayd", desktop: &fakeDesktop{}, service: func(_ context.Context, args ...string) error {
		commands = append(commands, append([]string{}, args...))
		if args[0] == "print" {
			return errors.New("not loaded")
		}
		return nil
	}}
	c := configFixture()
	saved, e := r.remember(context.Background(), c, false, false)
	if e != nil {
		t.Fatal(e)
	}
	again, e := r.remember(context.Background(), c, false, false)
	if e != nil || again != saved {
		t.Fatal("remember not idempotent", e)
	}
	bound, e := readConfig(saved.Config)
	if e != nil {
		t.Fatal(e)
	}
	changed := bound
	changed.RemotePID++
	if _, e = r.remember(context.Background(), changed, true, false); e == nil {
		t.Fatal("incarnation silently changed")
	}
	if _, e = r.remember(context.Background(), changed, true, true); e != nil {
		t.Fatal(e)
	}
	rows, e := connections(r.root())
	if e != nil || len(rows) != 1 {
		t.Fatal(e)
	}
	updated, e := r.handoff(context.Background(), saved.Config, changed, "task-next")
	if e != nil {
		t.Fatal(e)
	}
	rows, e = connections(r.root())
	if e != nil || !reflect.DeepEqual(rows[0].Tasks, []string{"task-a", "task-next"}) {
		t.Fatal("lineage lost", rows, e)
	}
	if updated.LocalName != bound.LocalName {
		t.Fatal("reply address changed")
	}
	if len(commands) == 0 {
		t.Fatal("service control missing")
	}
	stale := routeEvent{Session: changed.RemoteSession, PID: 222, Start: "777", Name: "new-peer"}
	if _, e = adoptConfig(changed, saved.Config, stale); !errors.Is(e, errIdentity) {
		t.Fatal("stale same-session adoption overwrote handoff")
	}
}
func TestWorkReferenceCASBounded(t *testing.T) {
	root := privateTemp(t)
	sequences, steps := 0, 0
	for encoded := 0; encoded < 64; encoded++ {
		home := filepath.Join(root, fmt.Sprint(encoded))
		d := &nativeDesktop{home: home, inspect: func(int) (processInfo, error) {
			return processInfo{WorkStart: "Sun Oct 25 01:02:03 2026", Executable: workApp}, nil
		}}
		a := workReference{1, "task", "local", d.workSocket(), workApp, 123, "Sun Oct 25 01:02:03 2026", "11111111-1111-1111-1111-111111111111"}
		b := a
		b.Owner = "22222222-2222-2222-2222-222222222222"
		var model *workReference
		n := encoded
		for depth := 0; depth < 3; depth++ {
			op := n % 4
			n /= 4
			next := a
			var expected *workReference
			switch op {
			case 1:
				next = b
			case 2:
				next = b
				expected = &a
			case 3:
				expected = &b
			}
			allowed := (model == nil && expected == nil) || (model != nil && expected != nil && *model == *expected)
			e := d.commitWork(next, expected)
			if (e == nil) != allowed {
				t.Fatalf("CAS acceptance sequence %d step %d: %v", encoded, depth, e)
			}
			if allowed {
				copy := next
				model = &copy
			}
			actual, e := d.workRef(d.legacySocket(), "task")
			if e != nil || !reflect.DeepEqual(actual, model) {
				t.Fatalf("CAS state %d: %+v %+v %v", encoded, actual, model, e)
			}
			steps++
		}
		sequences++
	}
	t.Logf("bound=3 alphabet=4 sequences=%d transitions=%d", sequences, steps)
}
func TestNativeServiceOnlyMigratesExactLegacy(t *testing.T) {
	home := privateTemp(t)
	r := &runtime{home: home, exe: "/app/relayd", service: func(context.Context, ...string) error { return nil }}
	c := configFixture()
	if e := privateDirectory(r.root(), true); e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(r.root(), routeKey(c)+".json")
	c.LocalName = "existing"
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	label := "dev.vaklab.relay-desktop-old"
	service := filepath.Join(home, "Library/LaunchAgents", label+".plist")
	os.MkdirAll(filepath.Dir(service), 0700)
	legacy := serviceBytes(label, []string{r.root() + "/venv/bin/python", r.root() + "/relay-desktop-route.py", "listen", "--config", path})
	os.WriteFile(service, legacy, 0600)
	if _, e := r.remember(context.Background(), c, false, false); e == nil {
		t.Fatal("legacy migrated without explicit connect")
	}
	if _, e := r.remember(context.Background(), c, true, false); e != nil {
		t.Fatal(e)
	}
	raw, e := privateRead(service, 16384, 0077)
	if e != nil || !r.serviceMatches(raw, label, path, false) {
		t.Fatal("native definition not installed", e)
	}
}

func TestRememberRejectsChangedLaunchBehavior(t *testing.T) {
	for _, change := range []string{"environment", "keepalive"} {
		t.Run(change, func(t *testing.T) {
			home := privateTemp(t)
			calls := 0
			r := &runtime{home: home, exe: "/app/relayd", service: func(context.Context, ...string) error { calls++; return nil }}
			c := configFixture()
			saved, e := r.remember(context.Background(), c, false, false)
			if e != nil {
				t.Fatal(e)
			}
			raw, e := privateRead(saved.Service, 16384, 0077)
			if e != nil {
				t.Fatal(e)
			}
			text := string(raw)
			if change == "environment" {
				text = strings.Replace(text, "<key>PATH</key>", "<key>HOME</key><string>/different</string><key>PATH</key>", 1)
			} else {
				text = strings.Replace(text, "<key>KeepAlive</key><false/>", "<key>KeepAlive</key><true/>", 1)
			}
			if e = os.WriteFile(saved.Service, []byte(text), 0600); e != nil {
				t.Fatal(e)
			}
			before := calls
			if _, e = r.remember(context.Background(), c, true, false); e == nil || calls != before {
				t.Fatal("changed launch behavior enabled", e, calls, before)
			}
		})
	}
}
func TestRouteAdoptionBounded(t *testing.T) {
	root := privateTemp(t)
	steps := 0
	for encoded := 0; encoded < 64; encoded++ {
		dir := filepath.Join(root, fmt.Sprint(encoded))
		os.Mkdir(dir, 0700)
		path := filepath.Join(dir, "route.json")
		initial := configFixture()
		model := initial
		if e := atomicJSON(path, model); e != nil {
			t.Fatal(e)
		}
		n := encoded
		for depth := 0; depth < 3; depth++ {
			op := n % 4
			n /= 4
			expected := model
			event := routeEvent{Session: model.RemoteSession, PID: 200 + depth, Start: fmt.Sprint(300 + depth), Name: "replacement"}
			valid := true
			switch op {
			case 1:
				event.Session = "another-session"
				valid = false
			case 2:
				expected = initial
				valid = model == initial
			case 3:
				event.Name = "../invalid"
				valid = false
			}
			got, e := adoptConfig(expected, path, event)
			if (e == nil) != valid {
				t.Fatalf("adoption sequence %d step %d accepted=%v error=%v", encoded, depth, valid, e)
			}
			if valid {
				model.RemotePID = event.PID
				model.RemoteStart = event.Start
				model.RemoteName = event.Name
				if got != model {
					t.Fatal("adoption changed unrelated binding")
				}
			}
			actual, e := readConfig(path)
			if e != nil || actual != model {
				t.Fatal("rejected adoption mutated saved route", e)
			}
			steps++
		}
	}
	t.Logf("bound=3 alphabet=4 sequences=64 transitions=%d", steps)
}
