package codexmcphealth

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeRecovery struct {
	root, bad   string
	calls       []string
	statusCalls int
}

func (r *fakeRecovery) Call(method string, params any) (map[string]any, error) {
	r.calls = append(r.calls, method)
	switch method {
	case "initialize":
		return map[string]any{}, nil
	case "thread/start":
		p := params.(map[string]any)
		if p["ephemeral"] != true || p["approvalPolicy"] != "never" || p["sandbox"] != "read-only" || p["cwd"] != r.root {
			return nil, fmt.Errorf("nonprivate fixture")
		}
		return map[string]any{"thread": map[string]any{"id": "private-thread"}}, nil
	case "mcpServerStatus/list":
		p := params.(map[string]any)
		if p["threadId"] != "private-thread" || p["limit"] != 100 || p["detail"] != "toolsAndAuthOnly" || p["serverName"] != "relayDesktopR" {
			return nil, fmt.Errorf("unbounded catalog")
		}
		tools := map[string]any{"one": map[string]any{}}
		if r.bad == "tools" {
			tools["two"] = true
		}
		row := map[string]any{"name": "relayDesktopR", "tools": tools}
		if r.bad == "toolserror" {
			row["toolsError"] = "broken"
		}
		if r.bad == "missing" {
			row["name"] = "other"
		}
		return map[string]any{"data": []any{row}}, nil
	case "thread/loaded/list":
		loaded := []any{"private-thread"}
		if r.bad == "thread" {
			loaded = []any{"changed"}
		}
		return map[string]any{"data": loaded}, nil
	}
	return nil, fmt.Errorf("unexpected fixture method %s", method)
}
func (r *fakeRecovery) Status(thread, server, status string, timeout time.Duration) error {
	r.statusCalls++
	wantServer, wantStatus, wantTimeout := "healthy", "ready", 30*time.Second
	if r.statusCalls == 2 {
		wantServer = "relayDesktopR"
		wantStatus = "failed"
	}
	if r.statusCalls == 3 {
		wantServer = "relayDesktopR"
		wantTimeout = 80 * time.Second
	}
	if thread != "private-thread" || server != wantServer || status != wantStatus || timeout != wantTimeout {
		return fmt.Errorf("startup deadline/order changed")
	}
	if r.statusCalls == 1 {
		_ = os.WriteFile(filepath.Join(r.root, "healthy.starts"), []byte("100\n"), 0600)
	}
	if r.statusCalls == 3 {
		if _, e := os.Stat(filepath.Join(r.root, "repaired")); e != nil {
			return e
		}
		data := "200\n201\n"
		if r.bad == "replacement" {
			data = "200\n"
		}
		_ = os.WriteFile(filepath.Join(r.root, "broken.starts"), []byte(data), 0600)
		if r.bad == "healthy" {
			_ = os.WriteFile(filepath.Join(r.root, "healthy.starts"), []byte("101\n"), 0600)
		}
	}
	return nil
}
func TestNativeRecoveryAssertions(t *testing.T) {
	for _, bad := range []string{"", "tools", "toolserror", "missing", "healthy", "replacement", "thread"} {
		t.Run(bad, func(t *testing.T) {
			r := &fakeRecovery{root: t.TempDir(), bad: bad}
			thread, count, e := VerifyRecovery(r, r.root)
			if (e == nil) != (bad == "") {
				t.Fatalf("recovery invariant %q error=%v", bad, e)
			}
			if bad == "" && (thread != "private-thread" || count != 2 || r.statusCalls != 3) {
				t.Fatal("fixture identity")
			}
			for _, m := range r.calls {
				if strings.HasPrefix(m, "turn/") || m == "thread/resume" {
					t.Fatal("model call")
				}
			}
		})
	}
}
func TestRecoveryRejectsModelTurnAndBoundsEvents(t *testing.T) {
	rpc := newRecoveryRPC(io.Discard, strings.NewReader("{\"method\":\"turn/started\"}\n"))
	if _, e := rpc.receive(time.Now().Add(time.Second)); e == nil {
		t.Fatal("model turn missed")
	}
	for i := 0; i < 4097; i++ {
		rpc.remember(map[string]any{"n": i})
	}
	if len(rpc.events) != 4096 || rpc.events[0]["n"] != 1 {
		t.Fatal("event history bound changed")
	}
	rpc = newRecoveryRPC(io.Discard, strings.NewReader("{\"id\":1,\"result\":{}}\n"))
	if _, e := rpc.Call("initialize", map[string]any{}); e != nil {
		t.Fatal(e)
	}
}
func TestFixtureHelperNoPython(t *testing.T) {
	root := t.TempDir()
	input := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}\n{\"id\":2,\"method\":\"tools/list\"}\n{\"method\":\"notification\"}\n{\"id\":3,\"method\":\"ping\"}\n"
	var out bytes.Buffer
	if e := FixtureHelper([]string{root, "broken"}, strings.NewReader(input), &out); e == nil || out.Len() != 0 {
		t.Fatal("broken fixture should fail initialization")
	}
	_ = os.WriteFile(filepath.Join(root, "repaired"), nil, 0600)
	if e := FixtureHelper([]string{root, "broken"}, strings.NewReader(input), &out); e != nil {
		t.Fatal(e)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 3 {
		t.Fatal("helper response count")
	}
	var v map[string]any
	_ = json.Unmarshal([]byte(lines[1]), &v)
	result := v["result"].(map[string]any)
	tools := result["tools"].([]any)
	if len(tools) != 1 || tools[0].(map[string]any)["name"] != "fixture_read" {
		t.Fatal("tool fixture changed")
	}
	pids, e := starts(root, "broken")
	if e != nil || len(pids) != 2 {
		t.Fatal("fixture start accounting")
	}
}
func FuzzFixtureJSON(f *testing.F) {
	f.Add([]byte(`{"id":1,"method":"ping"}`))
	f.Add([]byte(`{"method":"turn/started"}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > 32768 {
			return
		}
		var value map[string]any
		e := json.Unmarshal(raw, &value)
		if e != nil {
			return
		}
		encoded, _ := json.Marshal(value)
		r := newRecoveryRPC(io.Discard, bytes.NewReader(append(encoded, '\n')))
		got, e := r.receive(time.Now().Add(time.Second))
		if value["method"] == "turn/started" {
			if e == nil {
				t.Fatal("model turn accepted")
			}
		} else if e != nil || !bytes.Equal(marshal(got), marshal(value)) {
			t.Fatal("JSON recovery roundtrip")
		}
	})
}
func marshal(v any) []byte { raw, _ := json.Marshal(v); return raw }
