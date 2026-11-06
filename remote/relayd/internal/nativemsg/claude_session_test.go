//go:build linux || darwin

package nativemsg

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// desktopSession starts a Claude process outside any pane, as the Claude
// desktop app does, publishing sessionA under configDir (empty: the default
// account directory under HOME).
func desktopSession(t *testing.T, configDir string, overrides map[string]any, extra ...agentSpec) (*fixture, ClaudeSessionTarget) {
	t.Helper()
	f := newFixture(t)
	env := map[string]string{}
	root := f.path("home/.claude")
	if configDir != "" {
		env["CLAUDE_CONFIG_DIR"] = configDir
		root = configDir
	}
	agents := append([]agentSpec{{name: "desktop", program: f.path("bin/claude"),
		args: []string{"--socket", f.path("s/d.sock"), "--record", f.path("rec")}, env: env}}, extra...)
	f.start(idlePane(f), agents)
	row := map[string]any{"entrypoint": ClaudeDesktopEntrypoint}
	for key, value := range overrides {
		row[key] = value
	}
	f.desktopRecord("desktop", root, f.path("s/d.sock"), row)
	return f, ClaudeSessionTarget{AccountRoot: root, SessionID: sessionA}
}

// desktopRecord writes a session record and inbox key into root's registry.
func (f *fixture) desktopRecord(name, root, socket string, overrides map[string]any) {
	f.t.Helper()
	f.claudeSession(name, sessionA, socket, overrides)
	if root == f.path("claude") {
		return
	}
	// claudeSession writes under f.path("claude"); move both files.
	rel := strings.TrimPrefix(root, f.dir+"/")
	matches, _ := os.ReadDir(f.path("claude/sessions"))
	os.MkdirAll(f.path(rel+"/sessions"), 0o700)
	for _, entry := range matches {
		if err := os.Rename(f.path("claude/sessions/"+entry.Name()), f.path(rel+"/sessions/"+entry.Name())); err != nil {
			f.t.Fatal(err)
		}
	}
}

func runSession(t *testing.T, f *fixture, target ClaudeSessionTarget, packet map[string]any) map[string]any {
	t.Helper()
	data, err := json.Marshal(packet)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result := RunClaudeSession(ctx, f.host(), target, data)
	// Round-trip as the adapter prints it, so numbers compare as JSON.
	var decoded map[string]any
	if err := json.Unmarshal(Output(result), &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

func sessionEndpoint(t *testing.T, f *fixture, target ClaudeSessionTarget) map[string]any {
	t.Helper()
	got := runSession(t, f, target, map[string]any{"operation": "discover"})
	endpoint, ok := got["endpoint"].(map[string]any)
	if !ok {
		t.Fatalf("no endpoint: %v", got)
	}
	return endpoint
}

func TestClaudeSessionTargetDeliversToTheDesktopSessionInbox(t *testing.T) {
	f, target := desktopSession(t, "", nil)
	if target.AccountRoot != f.path("home/.claude") {
		t.Fatal(target)
	}
	endpoint := sessionEndpoint(t, f, target)
	if endpoint["transport"] != "native_peer_socket" || endpoint["sessionID"] != sessionA ||
		endpoint["socketPath"] != f.path("s/d.sock") || endpoint["socketPID"] != float64(f.pids["desktop"]) {
		t.Fatalf("endpoint %v", endpoint)
	}
	got := runSession(t, f, target, send(endpoint, kernelSource(nil), "hello desktop"))
	if got["status"] != "written_to_socket" {
		t.Fatalf("send %v", got)
	}
	records := f.settledRecords()
	if len(records) != 1 || !strings.Contains(records[0], "hello desktop") || !strings.Contains(records[0], "token-0123456789abcdef") {
		t.Fatalf("inbox received %q", records)
	}
}

func TestClaudeSessionTargetWithExplicitAccountDirectory(t *testing.T) {
	f3 := newFixture(t)
	config := f3.path("claude")
	f3.start(idlePane(f3), []agentSpec{{name: "desktop", program: f3.path("bin/claude"),
		args: []string{"--socket", f3.path("s/d.sock"), "--record", f3.path("rec")}, env: map[string]string{"CLAUDE_CONFIG_DIR": config}}})
	f3.claudeSession("desktop", sessionA, f3.path("s/d.sock"), map[string]any{"entrypoint": ClaudeDesktopEntrypoint})
	target3 := ClaudeSessionTarget{AccountRoot: config, SessionID: sessionA}
	if got := runSession(t, f3, target3, send(sessionEndpoint(t, f3, target3), kernelSource(nil), "hi")); got["status"] != "written_to_socket" {
		t.Fatal(got)
	}
}

func TestClaudeSessionTargetRefusesRecordsThatDoNotIdentifyTheSession(t *testing.T) {
	refused := func(t *testing.T, f *fixture, target ClaudeSessionTarget) {
		t.Helper()
		got := runSession(t, f, target, map[string]any{"operation": "discover"})
		if _, ok := got["endpoint"]; ok || got["status"] != "unavailable" {
			t.Fatalf("resolved %v", got)
		}
		if records := f.settledRecords(); len(records) != 0 {
			t.Fatalf("inbox touched %q", records)
		}
	}
	t.Run("stale record: process start differs (PID reused)", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"procStart": 7})
		refused(t, f, target)
	})
	t.Run("record of a process that exited", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"pid": 999999})
		refused(t, f, target)
	})
	t.Run("terminal session record (entrypoint cli)", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"entrypoint": "cli"})
		refused(t, f, target)
	})
	t.Run("Relay proxy record", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"relayProxy": true})
		refused(t, f, target)
	})
	t.Run("background job record", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"kind": "bg"})
		refused(t, f, target)
	})
	t.Run("another session", func(t *testing.T) {
		f, target := desktopSession(t, "", map[string]any{"sessionId": sessionB})
		refused(t, f, target)
	})
	t.Run("process belongs to another account directory", func(t *testing.T) {
		f := newFixture(t)
		other := f.path("claude")
		f.start(idlePane(f), []agentSpec{{name: "desktop", program: f.path("bin/claude"),
			args: []string{"--socket", f.path("s/d.sock"), "--record", f.path("rec")}, env: map[string]string{"CLAUDE_CONFIG_DIR": other}}})
		// The record is copied into the default registry; the process's own
		// account is the other directory.
		f.desktopRecord("desktop", f.path("home/.claude"), f.path("s/d.sock"), map[string]any{"entrypoint": ClaudeDesktopEntrypoint})
		refused(t, f, ClaudeSessionTarget{AccountRoot: f.path("home/.claude"), SessionID: sessionA})
	})
	t.Run("missing inbox key", func(t *testing.T) {
		f, target := desktopSession(t, "", nil)
		matches, _ := os.ReadDir(target.AccountRoot + "/sessions")
		for _, entry := range matches {
			if strings.HasSuffix(entry.Name(), ".key") {
				os.Remove(target.AccountRoot + "/sessions/" + entry.Name())
			}
		}
		refused(t, f, target)
	})
}

func TestClaudeSessionTargetRefusesTwoLiveRecordsForOneSession(t *testing.T) {
	f := newFixture(t)
	root := f.path("home/.claude")
	f.start(idlePane(f), []agentSpec{
		{name: "desktop", program: f.path("bin/claude"), args: []string{"--socket", f.path("s/d.sock"), "--record", f.path("rec")}},
		{name: "second", program: f.path("bin/claude"), args: []string{"--socket", f.path("s/e.sock"), "--record", f.path("rec")}},
	})
	f.desktopRecord("desktop", root, f.path("s/d.sock"), map[string]any{"entrypoint": ClaudeDesktopEntrypoint})
	f.desktopRecord("second", root, f.path("s/e.sock"), map[string]any{"entrypoint": ClaudeDesktopEntrypoint})
	got := runSession(t, f, ClaudeSessionTarget{AccountRoot: root, SessionID: sessionA}, map[string]any{"operation": "discover"})
	if got["status"] != "unavailable" {
		t.Fatalf("resolved one of two live records: %v", got)
	}
}

func TestClaudeSessionTargetChecksTheInboxAtDelivery(t *testing.T) {
	t.Run("socket owned by another process", func(t *testing.T) {
		f := newFixture(t)
		root := f.path("home/.claude")
		f.start(idlePane(f), []agentSpec{
			{name: "desktop", program: f.path("bin/claude"), args: nil},
			{name: "holder", program: f.path("bin/holder"), args: []string{"--socket", f.path("s/h.sock"), "--record", f.path("rec")}},
		})
		f.desktopRecord("desktop", root, f.path("s/h.sock"), map[string]any{"entrypoint": ClaudeDesktopEntrypoint})
		target := ClaudeSessionTarget{AccountRoot: root, SessionID: sessionA}
		got := runSession(t, f, target, send(sessionEndpoint(t, f, target), kernelSource(nil), "secret"))
		if got["status"] == "written_to_socket" || !strings.Contains(pyStr(got["error"]), "kernel owner mismatch") {
			t.Fatalf("delivered to a foreign inbox: %v", got)
		}
		for _, record := range f.settledRecords() {
			if strings.Contains(record, "secret") || strings.Contains(record, "token-") {
				t.Fatalf("foreign inbox received %q", record)
			}
		}
	})
	t.Run("socket replaced after discovery", func(t *testing.T) {
		f, target := desktopSession(t, "", nil)
		endpoint := sessionEndpoint(t, f, target)
		endpoint["socketIdentity"] = "0:0"
		got := runSession(t, f, target, send(endpoint, kernelSource(nil), "late"))
		if got["status"] == "written_to_socket" || !strings.Contains(pyStr(got["error"]), "changed: socketIdentity") {
			t.Fatalf("%v", got)
		}
		if records := f.settledRecords(); len(records) != 0 {
			t.Fatalf("written after a change: %q", records)
		}
	})
	t.Run("invalid targets", func(t *testing.T) {
		f, target := desktopSession(t, "", nil)
		for _, bad := range []ClaudeSessionTarget{
			{AccountRoot: "relative/.claude", SessionID: sessionA},
			{AccountRoot: "/", SessionID: sessionA},
			{AccountRoot: target.AccountRoot + "/../.claude", SessionID: sessionA},
			{AccountRoot: target.AccountRoot, SessionID: "not-a-session"},
		} {
			if got := runSession(t, f, bad, map[string]any{"operation": "discover"}); got["status"] != "unavailable" {
				t.Fatalf("%v accepted: %v", bad, got)
			}
		}
	})
}

// idlePane keeps the fixture's pane shell alive; the desktop session itself
// runs outside the pane.
func idlePane(f *fixture) []agentSpec {
	return []agentSpec{{name: "pane-idle", program: f.path("bin/holder")}}
}

func TestClaudeSessionTargetDispatchAndIdentity(t *testing.T) {
	f, target := desktopSession(t, "", nil)
	key, err := Target{Kind: "claude_session", Claude: &target}.IdentityKey()
	if err != nil || key != "claude_session:"+sessionA {
		t.Fatal(key, err)
	}
	for _, bad := range []Target{
		{Kind: "claude_session"},
		{Kind: "claude_session", Claude: &ClaudeSessionTarget{AccountRoot: "x", SessionID: sessionA}},
		{Kind: "claude_session", PaneID: f.pane, Claude: &target},
		{Kind: "pane", PaneID: f.pane, Claude: &target},
		{Kind: "work", Work: &WorkEndpoint{}, Claude: &target},
	} {
		if _, err := bad.IdentityKey(); err == nil {
			t.Fatalf("%+v accepted", bad)
		}
	}
	data, _ := json.Marshal(map[string]any{"operation": "discover"})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	got, err := RunTarget(ctx, f.host(), Target{Kind: "claude_session", Claude: &target}, data, nil)
	if err != nil || got["endpoint"] == nil {
		t.Fatal(got, err)
	}
	if _, err := RunTarget(ctx, f.host(), Target{Kind: "claude_session", Claude: &target}, data, &WorkMessage{}); err == nil {
		t.Fatal("Work message accepted for a Claude session target")
	}
}
