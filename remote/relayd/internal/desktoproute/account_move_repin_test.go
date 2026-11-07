package desktoproute

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

// A Relay account move resumes the same conversation in another account, so
// the pane's new process registers under that account's sessions directory.
// The route searched only its recorded account and reported identity_missing,
// orphaning the Codex chat's route (bc08, 2026-11-08). A replacement is now
// also taken from another configured Claude account when both accounts share
// the conversation history and it is the only live match anywhere.
func TestAccountMovedReplacementIsAdoptedOnlyWithSharedHistory(t *testing.T) {
	for _, c := range []struct {
		name          string
		shared, twice bool
		want, account string
	}{
		{"shared_history", true, false, "identity_replacement", ".claude-team"},
		{"separate_history", false, false, "identity_missing", ""},
		{"two_live_matches", true, true, "identity_changed", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			home := privateTemp(t)
			history := filepath.Join(home, ".claude", "projects")
			personal, team := filepath.Join(home, ".claude-max"), filepath.Join(home, ".claude-team")
			for _, dir := range []string{history, filepath.Join(personal, "sessions"), filepath.Join(team, "sessions"), filepath.Join(home, ".relay")} {
				if err := privateDirectory(dir, true); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Symlink(history, filepath.Join(personal, "projects")); err != nil {
				t.Fatal(err)
			}
			teamHistory := history
			if !c.shared {
				teamHistory = filepath.Join(home, "elsewhere")
				if err := privateDirectory(teamHistory, true); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Symlink(teamHistory, filepath.Join(team, "projects")); err != nil {
				t.Fatal(err)
			}
			registry := `{"version":1,"accounts":[{"provider":"claude","label":"business","dir":"~/.claude-team","share_history":true},{"provider":"claude","label":"personal","dir":"~/.claude-max","share_history":true},{"provider":"codex","label":"business","dir":""},{"provider":"codex","label":"personal","dir":"~/.codex-personal"}]}`
			if err := os.WriteFile(filepath.Join(home, ".relay", "agent-accounts.json"), []byte(registry), 0600); err != nil {
				t.Fatal(err)
			}
			socket := filepath.Join(home, "replacement.sock")
			listener := unixFixture(t, socket)
			defer listener.Close()
			moved := peerRecord{PID: 4242, Name: "reply", Session: "session", Start: "789", Socket: socket, CWD: home}
			if err := atomicJSON(filepath.Join(team, "sessions", "4242.json"), moved); err != nil {
				t.Fatal(err)
			}
			live := map[int]bool{4242: true}
			if c.twice {
				other := moved
				other.PID = 4343
				live[4343] = true
				if err := atomicJSON(filepath.Join(personal, "sessions", "4343.json"), other); err != nil {
					t.Fatal(err)
				}
			}
			r := &remoteRuntime{home: home, inspect: func(pid int) (processInfo, error) {
				if live[pid] {
					return processInfo{Start: "789"}, nil
				}
				return processInfo{}, errIdentity
			}, environment: func(int, ...string) (map[string]string, error) {
				t.Fatal("environment read for a gone owner")
				return nil, nil
			}}
			var out bytes.Buffer
			if e := r.run(context.Background(), []string{"listen", "123", "session", "456", "reply", personal}, bytes.NewReader(nil), &out); e != nil {
				t.Fatal(e)
			}
			event, e := parseEvent(out.Bytes())
			if e != nil || event.Type != c.want {
				t.Fatalf("event = %s, want %s", out.String(), c.want)
			}
			if c.account != "" && event.Account != filepath.Join(home, c.account) {
				t.Fatalf("replacement account = %q", event.Account)
			}
		})
	}
}

// The route adopts the moved process with its new account and leaves a
// durable line naming both incarnations; a route that never recorded an
// account is not moved to one.
func TestAdoptingAMovedOwnerRecordsTheNewAccountAndAnEvent(t *testing.T) {
	dir := privateTemp(t)
	path := filepath.Join(dir, "route.json")
	c := configFixture()
	c.RemoteAccount = "/home/u/.claude-max"
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	event := routeEvent{Type: "identity_replacement", Session: c.RemoteSession, PID: 4242, Start: "789", Name: "peer2", Account: "/home/u/.claude-team"}
	updated, e := adoptConfig(c, path, event)
	if e != nil || updated.RemotePID != 4242 || updated.RemoteStart != "789" || updated.RemoteAccount != "/home/u/.claude-team" {
		t.Fatalf("moved owner not adopted: %+v %v", updated, e)
	}
	if saved, e := readConfig(path); e != nil || saved != updated {
		t.Fatalf("adoption not saved: %+v %v", saved, e)
	}
	log, e := os.ReadFile(filepath.Join(dir, "route.repins.jsonl"))
	if e != nil || !bytes.Contains(log, []byte(`"old_pid":123`)) || !bytes.Contains(log, []byte(`"new_pid":4242`)) ||
		!bytes.Contains(log, []byte(`"old_account":"/home/u/.claude-max"`)) || !bytes.Contains(log, []byte(`"new_account":"/home/u/.claude-team"`)) {
		t.Fatalf("re-pin event missing: %s %v", log, e)
	}
	legacy := configFixture()
	legacyPath := filepath.Join(dir, "legacy.json")
	if err := atomicJSON(legacyPath, legacy); err != nil {
		t.Fatal(err)
	}
	if _, e := adoptConfig(legacy, legacyPath, event); e == nil {
		t.Fatal("a route without a recorded account was moved to one")
	}
	if saved, _ := readConfig(legacyPath); saved != legacy {
		t.Fatal("refused adoption changed the route")
	}
}
