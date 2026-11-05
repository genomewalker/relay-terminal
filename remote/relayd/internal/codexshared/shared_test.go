package codexshared

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fake struct {
	queue     []map[string]any
	sent      []map[string]any
	deadlines []time.Duration
	closed    bool
}

func (f *fake) Send(b []byte, op byte) error {
	if op != 1 {
		return errors.New("opcode")
	}
	var v map[string]any
	if e := json.Unmarshal(b, &v); e != nil {
		return e
	}
	f.sent = append(f.sent, v)
	return nil
}
func (f *fake) Receive() (map[string]any, error) {
	if len(f.queue) == 0 {
		return nil, io.EOF
	}
	v := f.queue[0]
	f.queue = f.queue[1:]
	return v, nil
}
func (f *fake) SetDeadline(d time.Time) error {
	f.deadlines = append(f.deadlines, time.Until(d))
	return nil
}
func (f *fake) Close() error { f.closed = true; return nil }
func response(id int, r map[string]any) map[string]any {
	return map[string]any{"id": float64(id), "result": r}
}
func complete(status string) map[string]any {
	return map[string]any{"method": "turn/completed", "params": map[string]any{"turn": map[string]any{"status": status}}}
}
func item(text string) map[string]any {
	return map[string]any{"method": "item/completed", "params": map[string]any{"item": map[string]any{"type": "agentMessage", "text": text}}}
}
func fixtures() (*fake, *fake) {
	return &fake{queue: []map[string]any{response(1, map[string]any{}), response(2, map[string]any{"thread": map[string]any{"id": "private-thread"}}), response(10, map[string]any{}), complete("completed"), response(3, map[string]any{"turn": map[string]any{"id": "shared-turn"}}), item(TokenA), item(TokenB), complete("completed")}}, &fake{queue: []map[string]any{response(1, map[string]any{}), response(2, map[string]any{}), response(3, map[string]any{"turn": map[string]any{"id": "shared-turn"}}), item(TokenA + "\n" + TokenB), complete("completed")}}
}
func TestExactTwoClientProtocol(t *testing.T) {
	a, b := fixtures()
	var out bytes.Buffer
	if e := Exercise(a, b, "/private-fixture", &out); e != nil {
		t.Fatal(e)
	}
	for _, s := range []string{"PASS client 0: both reply tokens; completed notification", "PASS client 1: both reply tokens; completed notification"} {
		if !strings.Contains(out.String(), s) {
			t.Fatal("missing client completion")
		}
	}
	for i, c := range []*fake{a, b} {
		want := []string{"initialize", "initialized", "thread/resume", "turn/start"}
		if i == 0 {
			want = []string{"initialize", "initialized", "thread/start", "turn/start", "turn/start"}
		}
		if len(c.sent) != len(want) {
			t.Fatal("wrong request count")
		}
		for j, m := range want {
			if c.sent[j]["method"] != m {
				t.Fatal("wrong protocol order")
			}
		}
		init := c.sent[0]["params"].(map[string]any)
		if init["capabilities"].(map[string]any)["experimentalApi"] != true {
			t.Fatal("experimental API missing")
		}
		if init["clientInfo"].(map[string]any)["name"] != "relay_shared_test" {
			t.Fatal("client identity changed")
		}
		p := c.sent[len(c.sent)-1]["params"].(map[string]any)
		if p["threadId"] != "private-thread" || len(p["input"].([]any)) != 0 {
			t.Fatal("delivery thread/input changed")
		}
		tool := p["toolOutput"].(map[string]any)
		if tool["name"] != "relay_peer" || tool["output"] != []string{TokenA, TokenB}[i] {
			t.Fatal("delivery token changed")
		}
		for _, d := range c.deadlines {
			if !((d > 19*time.Second && d <= RPCTimeout) || (d > 59*time.Second && d <= CollectionTimeout)) {
				t.Fatalf("wrong deadline %v", d)
			}
		}
		if c.deadlines[len(c.deadlines)-1] < 59*time.Second {
			t.Fatal("collection deadline changed")
		}
	}
	p := a.sent[2]["params"].(map[string]any)
	if p["cwd"] != "/private-fixture" || p["model"] != "gpt-6-astra" || p["sandbox"] != "read-only" || p["approvalPolicy"] != "never" || p["developerInstructions"] != "Connectivity test. Never call tools. Echo the exact contents of each external tool output, verbatim." {
		t.Fatal("isolated thread policy changed")
	}
	if b.sent[2]["params"].(map[string]any)["threadId"] != "private-thread" {
		t.Fatal("resume changed")
	}
	if RPCTimeout != 20*time.Second || CollectionTimeout != 60*time.Second || ReadyAttempts != 100 || ReadyInterval != 50*time.Millisecond {
		t.Fatal("original time bounds changed")
	}
}
func TestEveryAcceptanceFailure(t *testing.T) {
	for _, which := range []string{"different-turn", "first-missing", "second-missing", "first-failed", "second-failed", "rpc-error", "bad-thread", "closed"} {
		t.Run(which, func(t *testing.T) {
			a, b := fixtures()
			switch which {
			case "different-turn":
				b.queue[2] = response(3, map[string]any{"turn": map[string]any{"id": "other"}})
			case "first-missing":
				a.queue[6] = item("none")
			case "second-missing":
				b.queue[3] = item(TokenA)
			case "first-failed":
				a.queue[7] = complete("failed")
			case "second-failed":
				b.queue[4] = complete("failed")
			case "rpc-error":
				a.queue[0] = map[string]any{"id": float64(1), "error": "rejected", "result": map[string]any{}}
			case "bad-thread":
				a.queue[1] = response(2, map[string]any{"thread": map[string]any{"id": ""}})
			case "closed":
				b.queue = b.queue[:4]
			}
			if Exercise(a, b, "/private", io.Discard) == nil {
				t.Fatal("accepted failed contract")
			}
		})
	}
}
func TestOptInBeforeAnyProviderOrAuthAccess(t *testing.T) {
	t.Setenv("HOME", filepath.Join(t.TempDir(), "missing"))
	if e := Run([]string{"--binary", "/never-execute"}, io.Discard, io.Discard); e == nil || !strings.Contains(e.Error(), "--live") {
		t.Fatal("opt-in gate missing")
	}
}
func TestPrivateFakeBackendLaunchAndCleanup(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	capture := filepath.Join(home, "capture")
	binary := filepath.Join(home, "fake-backend")
	script := "#!/bin/sh\n[ \"$1\" = app-server ] && [ \"$2\" = --listen ] || exit 8\n[ -L \"$CODEX_HOME/auth.json\" ] || exit 9\nreadlink \"$CODEX_HOME/auth.json\" > \"$RELAY_SHARED_CAPTURE\"\nprintf '%s\\n' \"$CODEX_HOME\" \"$PWD\" \"$3\" >> \"$RELAY_SHARED_CAPTURE\"\nexit 0\n"
	if e := os.WriteFile(binary, []byte(script), 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("RELAY_SHARED_CAPTURE", capture)
	t.Setenv("CODEX_HOME", "/must-not-use")
	e := Run([]string{"--live", "--binary", binary}, io.Discard, io.Discard)
	if e == nil || !strings.Contains(e.Error(), "exited before readiness") {
		t.Fatalf("unexpected fake launch %v", e)
	}
	b, e := os.ReadFile(capture)
	if e != nil {
		t.Fatal(e)
	}
	physicalTmp, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 4 || lines[0] != filepath.Join(home, ".codex/auth.json") || filepath.Join(physicalTmp, filepath.Base(lines[1])) != lines[2] || !strings.HasPrefix(lines[1], "/tmp/relay-shared-") || lines[3] != "unix://"+lines[1]+"/server.sock" {
		t.Fatalf("isolation changed: %q", lines)
	}
	if _, e = os.Stat(lines[1]); !os.IsNotExist(e) {
		t.Fatal("temporary session not cleaned")
	}
}
func FuzzProviderEvents(f *testing.F) {
	f.Add([]byte(`{"method":"turn/completed","params":{"turn":{"status":"completed"}}}`))
	f.Add([]byte(`{"thread":{"id":"thread"}}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > 1<<20 {
			return
		}
		var v map[string]any
		if json.Unmarshal(b, &v) != nil {
			return
		}
		id, e := nestedID(v, "thread")
		if e == nil {
			m, ok := v["thread"].(map[string]any)
			if !ok || id == "" || m["id"] != id {
				t.Fatal("invalid thread authority")
			}
		}
		c := &fake{queue: []map[string]any{v}}
		text, e := Collect(c)
		if e == nil {
			if !strings.Contains(text, TokenA) || !strings.Contains(text, TokenB) {
				t.Fatal("success without both tokens")
			}
			p, _ := v["params"].(map[string]any)
			turn, _ := p["turn"].(map[string]any)
			if v["method"] != "turn/completed" || turn["status"] != "completed" {
				t.Fatal("success without completed")
			}
		}
	})
}
func TestRPCSkipsUnrelatedAndRejectsMalformed(t *testing.T) {
	c := &fake{queue: []map[string]any{{"id": float64(44)}, response(3, map[string]any{"ok": true})}}
	r, e := rpc(c, 3, "test", nil)
	if e != nil || r["ok"] != true {
		t.Fatal("RPC correlation")
	}
	c = &fake{queue: []map[string]any{{"id": float64(3), "result": "wrong"}}}
	if _, e = rpc(c, 3, "test", nil); e == nil {
		t.Fatal("malformed result accepted")
	}
	if _, e = nestedID(map[string]any{}, "thread"); e == nil {
		t.Fatal("missing object accepted")
	}
	c = &fake{queue: []map[string]any{item(strings.Repeat("x", (4<<20)+1))}}
	if _, e = Collect(c); e == nil || !strings.Contains(e.Error(), "reply exceeds limit") {
		t.Fatal("unbounded reply accepted")
	}
}
