package desktoproute

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Route c69609 (2026-11-08) was re-pinned to the moved pane's new process by
// an older listener that kept the recorded account (~/.claude-max) although
// the process runs in ~/.claude-team. The pid then already matched, so no
// re-pin ran again and the stale account stayed. The ready frame now says
// whether the live account shares the recorded account's history, and the
// route corrects the account for that same incarnation and logs it.

func sharedAccounts(t *testing.T, shared bool) (home, personal, team string) {
	t.Helper()
	home = privateTemp(t)
	history := filepath.Join(home, ".claude", "projects")
	personal, team = filepath.Join(home, ".claude-max"), filepath.Join(home, ".claude-team")
	for _, dir := range []string{history, personal, team} {
		if err := privateDirectory(dir, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(history, filepath.Join(personal, "projects")); err != nil {
		t.Fatal(err)
	}
	teamHistory := history
	if !shared {
		teamHistory = filepath.Join(home, "elsewhere")
		if err := privateDirectory(teamHistory, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(teamHistory, filepath.Join(team, "projects")); err != nil {
		t.Fatal(err)
	}
	return home, personal, team
}

func readyFor(t *testing.T, r *remoteRuntime, recorded string) routeEvent {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var out bytes.Buffer
	_ = r.run(ctx, []string{"listen", "123", "session", testOwnerStart, "reply", recorded}, bytes.NewReader(nil), &out)
	for _, line := range bytes.Split(out.Bytes(), []byte("\n")) {
		if strings.Contains(string(line), `"type":"ready"`) {
			event, e := parseEvent(line)
			if e != nil {
				t.Fatalf("ready frame does not parse: %s %v", line, e)
			}
			return event
		}
	}
	t.Fatalf("no ready frame: %s", out.String())
	return routeEvent{}
}

func TestReadyFrameMarksALiveAccountThatSharesTheRecordedHistory(t *testing.T) {
	for _, c := range []struct {
		name     string
		shared   bool
		recorded string
		want     bool
	}{
		{"moved_shared_history", true, "personal", true},
		{"moved_separate_history", false, "personal", false},
		{"same_account", true, "team", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			home, personal, team := sharedAccounts(t, c.shared)
			r, _ := ownerInAccount(t, home, team, 123, "session")
			recorded := personal
			if c.recorded == "team" {
				recorded = team
			}
			event := readyFor(t, r, recorded)
			if event.Account != team || event.AccountShared != c.want {
				t.Fatalf("ready account = %q shared=%v, want %q shared=%v", event.Account, event.AccountShared, team, c.want)
			}
		})
	}
}

func TestReadyCorrectsAStaleAccountForTheSameIncarnationAndLogsIt(t *testing.T) {
	dir := privateTemp(t)
	path := filepath.Join(dir, "route.json")
	c := configFixture()
	c.RemoteAccount = "/home/u/.claude-max"
	c.RemoteAccountAccepted = true
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	ready := routeEvent{Type: "ready", PID: 99, Start: "1", Name: c.LocalName, Account: "/home/u/.claude-team", AccountShared: true}
	updated, _, e := readyAccount(c, path, ready)
	if e != nil || updated.RemoteAccount != "/home/u/.claude-team" || updated.RemotePID != c.RemotePID || updated.RemoteStart != c.RemoteStart {
		t.Fatalf("stale account not corrected: %+v %v", updated, e)
	}
	if saved, e := readConfig(path); e != nil || saved != updated {
		t.Fatalf("correction not saved: %+v %v", saved, e)
	}
	log, e := os.ReadFile(filepath.Join(dir, "route.repins.jsonl"))
	if e != nil || bytes.Count(log, []byte("\n")) != 1 ||
		!bytes.Contains(log, []byte(`"old_account":"/home/u/.claude-max"`)) || !bytes.Contains(log, []byte(`"new_account":"/home/u/.claude-team"`)) {
		t.Fatalf("correction not logged: %s %v", log, e)
	}
	// A second ready for the corrected route changes and logs nothing.
	again, _, e := readyAccount(updated, path, ready)
	if e != nil || again != updated {
		t.Fatalf("repeated ready changed the route: %+v %v", again, e)
	}
	if log2, _ := os.ReadFile(filepath.Join(dir, "route.repins.jsonl")); !bytes.Equal(log, log2) {
		t.Fatalf("repeated ready logged again: %s", log2)
	}
}

func TestReadyKeepsTheRecordedAccountWithoutSharedHistoryOrOverAChangedRoute(t *testing.T) {
	dir := privateTemp(t)
	c := configFixture()
	c.RemoteAccount = "/home/u/.claude-max"
	c.RemoteAccountAccepted = true
	unshared := routeEvent{Type: "ready", PID: 99, Start: "1", Name: c.LocalName, Account: "/home/u/.claude-team"}
	path := filepath.Join(dir, "route.json")
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	if updated, _, e := readyAccount(c, path, unshared); e != nil || updated != c {
		t.Fatalf("account changed without shared history: %+v %v", updated, e)
	}
	// The file changed under this listener: it must not overwrite it.
	changed := c
	changed.RemotePID = 777
	if err := atomicJSON(path, changed); err != nil {
		t.Fatal(err)
	}
	shared := unshared
	shared.AccountShared = true
	if updated, _, _ := readyAccount(c, path, shared); updated.RemoteAccount != c.RemoteAccount {
		t.Fatalf("stale listener rewrote the account: %+v", updated)
	}
	if saved, _ := readConfig(path); saved != changed {
		t.Fatalf("stale listener overwrote the route: %+v", saved)
	}
	if _, e := os.Stat(filepath.Join(dir, "route.repins.jsonl")); !os.IsNotExist(e) {
		t.Fatalf("refused correction was logged: %v", e)
	}
}
