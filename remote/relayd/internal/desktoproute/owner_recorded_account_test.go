package desktoproute

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const testOwnerStart = "Thu Nov  5 05:28:32 2026"

// A live owner in a non-default account, with a verified registration there.
func ownerInAccount(t *testing.T, home, acct string, pid int, session string) (*remoteRuntime, string) {
	t.Helper()
	sessions := filepath.Join(acct, "sessions")
	if err := privateDirectory(sessions, true); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(acct, "owner.sock")
	listener := unixFixture(t, socket)
	t.Cleanup(func() { listener.Close() })
	record := peerRecord{PID: pid, Name: "reply", Session: session, Start: testOwnerStart, Socket: socket, CWD: home}
	if err := atomicJSON(filepath.Join(sessions, fmt.Sprintf("%d.json", pid)), record); err != nil {
		t.Fatal(err)
	}
	return &remoteRuntime{home: home, inspect: func(p int) (processInfo, error) {
		if p == pid {
			return processInfo{Start: testOwnerStart}, nil
		}
		if p == os.Getpid() {
			return processInfo{Start: "Thu Nov  5 05:28:33 2026"}, nil
		}
		return processInfo{}, errIdentity
	}, environment: func(int, ...string) (map[string]string, error) {
		return map[string]string{"CLAUDE_CONFIG_DIR": acct}, nil
	}}, socket
}

func testRoute(home string) Config {
	return Config{Host: "laptop", LocalName: "relay-route", Thread: "thread-1", RemoteName: "reply", RemoteSession: "session",
		RemotePID: 123, RemoteStart: testOwnerStart, Socket: filepath.Join(home, "desktop.sock")}
}

// A route created for a local owner records the owner's own account.
func TestRouteRecordsOwnerAccountAtCreation(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	r, _ := ownerInAccount(t, home, acct, 123, "session")
	c := recordLocalOwnerAccount(r, testRoute(home))
	if c.RemoteAccount != acct {
		t.Fatalf("recorded account = %q, want %q", c.RemoteAccount, acct)
	}
	gone := &remoteRuntime{home: home, inspect: func(int) (processInfo, error) { return processInfo{}, errIdentity }, environment: r.environment}
	if c := recordLocalOwnerAccount(gone, testRoute(home)); c.RemoteAccount != "" {
		t.Fatalf("recorded for a gone owner: %q", c.RemoteAccount)
	}
}

// A live owner's listener reports its account, and the route backfills it once.
func TestOwnerAccountBackfilledFromLiveOwner(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	r, _ := ownerInAccount(t, home, acct, 123, "session")
	// The listener runs until its context ends; the owner account is reported
	// right after its ready frame.
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var out bytes.Buffer
	_ = r.run(ctx, []string{"listen", "123", "session", testOwnerStart, "reply"}, bytes.NewReader(nil), &out)
	var event routeEvent
	found := false
	for _, line := range bytes.Split(out.Bytes(), []byte("\n")) {
		if parsed, e := parseEvent(line); e == nil && parsed.Type == "owner_account" {
			event, found = parsed, true
		}
	}
	if !found || event.Account != acct || event.PID != 123 || event.Start != testOwnerStart {
		t.Fatalf("no account backfill event: %s", out.String())
	}
	path := filepath.Join(home, "route.json")
	c := testRoute(home)
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	updated, e := backfillOwnerAccount(c, path, event)
	if e != nil || updated.RemoteAccount != acct {
		t.Fatalf("backfill = %+v, %v", updated, e)
	}
	saved, e := readConfig(path)
	if e != nil || saved.RemoteAccount != acct {
		t.Fatalf("backfill not persisted: %+v, %v", saved, e)
	}
	// A recorded account is never overwritten, and another incarnation is ignored.
	again, e := backfillOwnerAccount(updated, path, routeEvent{Type: "owner_account", PID: 123, Start: testOwnerStart, Account: home})
	if e != nil || again != updated {
		t.Fatalf("recorded account overwritten: %+v, %v", again, e)
	}
	other, e := backfillOwnerAccount(c, path, routeEvent{Type: "owner_account", PID: 999, Start: testOwnerStart, Account: acct})
	if e != nil || other != c {
		t.Fatalf("another incarnation backfilled: %+v, %v", other, e)
	}
}

// After the owner exits, a replacement is adopted only from the recorded account.
func TestReplacementSearchesOnlyRecordedAccount(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	defaultSessions := filepath.Join(home, ".claude", "sessions")
	if err := privateDirectory(defaultSessions, true); err != nil {
		t.Fatal(err)
	}
	replacementSocket := filepath.Join(home, "replacement.sock")
	listener := unixFixture(t, replacementSocket)
	defer listener.Close()
	replacement := peerRecord{PID: 4242, Name: "reply", Session: "session", Start: "789", Socket: replacementSocket, CWD: home}
	inspect := func(pid int) (processInfo, error) {
		if pid == 4242 {
			return processInfo{Start: "789"}, nil
		}
		return processInfo{}, errIdentity
	}
	run := func(t *testing.T, account string) string {
		t.Helper()
		r := &remoteRuntime{home: home, inspect: inspect, environment: func(int, ...string) (map[string]string, error) {
			t.Fatal("environment read for a gone owner")
			return nil, nil
		}}
		args := []string{"listen", "123", "session", "456", "reply"}
		if account != "" {
			args = append(args, account)
		}
		var out bytes.Buffer
		if e := r.run(context.Background(), args, bytes.NewReader(nil), &out); e != nil {
			t.Fatal(e)
		}
		event, e := parseEvent(out.Bytes())
		if e != nil {
			t.Fatal(e)
		}
		return event.Type
	}
	// Recorded account holds the replacement: adopted.
	if err := privateDirectory(filepath.Join(acct, "sessions"), true); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(acct, "sessions", "4242.json"), replacement); err != nil {
		t.Fatal(err)
	}
	if got := run(t, acct); got != "identity_replacement" {
		t.Fatalf("recorded account replacement = %s", got)
	}
	// A replacement only in the default account is ignored.
	if err := os.Remove(filepath.Join(acct, "sessions", "4242.json")); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(defaultSessions, "4242.json"), replacement); err != nil {
		t.Fatal(err)
	}
	if got := run(t, acct); got != "identity_missing" {
		t.Fatalf("default-account replacement adopted for a recorded account: %s", got)
	}
	// A route with no recorded account and a dead owner is identity_missing.
	if got := run(t, ""); got != "identity_missing" {
		t.Fatalf("legacy route with a dead owner = %s", got)
	}
}
