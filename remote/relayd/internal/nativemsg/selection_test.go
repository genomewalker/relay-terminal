//go:build linux || darwin

package nativemsg

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRootPIDUsesExactLiveHintAndRetainsFences(t *testing.T) {
	f := claudePane(t, func(o *paneOptions) { o.noWorker = true })
	f.claudeBinding(nil)
	host := f.host()
	host.RootPID = int64(f.shell)
	got := f.runHost(t, host, discover())
	endpoint, _ := got["endpoint"].(map[string]any)
	if endpoint == nil || endpoint["rootPID"] != float64(f.shell) || endpoint["pid"] != float64(f.pids["claude"]) {
		t.Fatalf("explicit root did not select exact pane: %v", got)
	}
	// With no hint, the missing retained worker must still be refused.
	host.RootPID = 0
	if got = f.runHost(t, host, discover()); got["endpoint"] != nil || !strings.Contains(got["error"].(string), "No such file or directory") {
		t.Fatalf("missing worker was bypassed: %v", got)
	}
	host.RootPID = -1
	if got = f.runHost(t, host, discover()); got["endpoint"] != nil {
		t.Fatalf("invalid root admitted: %v", got)
	}
	host.RootPID = int64(f.shell)
	requireIncarnationFence(t, f, host, discover(), func(r map[string]any) bool { return r["endpoint"] != nil }, 0)
}

func siblingCodexPane(t *testing.T) *fixture {
	t.Helper()
	f := newFixture(t)
	transcript := f.path("codex/sessions/2026/rollout.jsonl")
	f.write("codex/sessions/2026/rollout.jsonl", `{"type":"session_meta","payload":{"id":"`+threadA+`","source":"cli"}}`+"\n")
	f.write("fix/codex.json", codexConfig{Loaded: [][]any{{threadA}}, Thread: map[string]any{"id": threadA, "path": transcript}, Turn: map[string]any{"id": "turn-7"}})
	socket := f.path("codex/app-server-control/app-server-control.sock")
	f.start([]agentSpec{
		{name: "codex", program: f.path("bin/codex"), args: []string{"--open", transcript}, env: map[string]string{"CODEX_HOME": f.path("codex")}},
		{name: "server", program: f.path("bin/codex"), args: []string{"--mode", "codex", "--socket", socket, "--record", f.path("rec"), "--config", f.path("fix/codex.json")}, env: map[string]string{"CODEX_HOME": f.path("codex")}},
	}, nil)
	f.workerRecord(nil)
	binding := f.stockProxy(nil)
	binding["native_endpoint"].(map[string]any)["daemon_pid"] = f.pids["server"]
	f.write("fix/binding.json", binding)
	return f
}

// The canonical agent() fallback requires a stable authenticated stock proxy,
// the exact Codex descendant, and the independent native incarnation callback.
// Every negative case has zero message writes; none picks a newer sibling.
func TestSiblingCodexSelectionRequiresExactNativeProof(t *testing.T) {
	for _, name := range []string{"valid", "missing-callback", "wrong-start", "callback-error", "callback-panic", "changed-binding", "invalid-proof", "outside-candidate", "wrong-provider", "boolean-start"} {
		t.Run(name, func(t *testing.T) {
			f := siblingCodexPane(t)
			host := f.host()
			host.RootPID = int64(f.shell)
			calls := 0
			host.NativeProcessStart = func(pane string, pid int64, provider string) (uint64, error) {
				calls++
				if pane != f.pane || pid != int64(f.pids["codex"]) || provider != "codex" {
					t.Errorf("wrong native identity selector: %q %d %q", pane, pid, provider)
				}
				switch name {
				case "wrong-start":
					return 4243, nil
				case "callback-error":
					return 4242, errors.New("stale native process")
				case "callback-panic":
					panic("native reader failed")
				}
				return 4242, nil
			}
			binding := f.stockProxy(nil)
			binding["native_endpoint"].(map[string]any)["daemon_pid"] = f.pids["server"]
			switch name {
			case "missing-callback":
				host.NativeProcessStart = nil
			case "changed-binding":
				f.write("fix/binding.limit", "1")
				after := f.stockProxy(map[string]any{"revision": strings.Repeat("a", 64)})
				after["native_endpoint"].(map[string]any)["daemon_pid"] = f.pids["server"]
				f.write("fix/binding.after.json", after)
			case "invalid-proof":
				binding["revision"] = "invalid"
			case "outside-candidate":
				binding["producer"].(map[string]any)["process_id"] = f.worker
			case "wrong-provider":
				binding["producer"].(map[string]any)["provider"] = "claude"
			case "boolean-start":
				binding["producer"].(map[string]any)["process_start"] = true
			}
			f.write("fix/binding.json", binding)
			got := f.runHost(t, host, discover())
			endpoint, _ := got["endpoint"].(map[string]any)
			if name == "valid" {
				if endpoint == nil || endpoint["pid"] != float64(f.pids["codex"]) || endpoint["socketPID"] != float64(f.pids["server"]) || endpoint["transport"] != "codex_app_server_message" || calls != 1 {
					t.Fatalf("exact sibling selection failed: %v calls=%d", got, calls)
				}
			} else {
				if endpoint != nil || got["replay_permitted"] != false || !strings.Contains(got["error"].(string), "exact, unique foreground agent") {
					t.Fatalf("invalid sibling proof admitted: %v", got)
				}
				wantCalls := 0
				if name == "wrong-start" || name == "callback-error" || name == "callback-panic" {
					wantCalls = 1
				}
				if calls != wantCalls {
					t.Fatalf("callback calls %d want %d", calls, wantCalls)
				}
			}
			if records := writes(f.settledRecords()); len(records) != 0 {
				t.Fatalf("selection sent collaborator messages: %q", records)
			}
		})
	}
}

func TestSiblingNativeProofHonorsCancelledContext(t *testing.T) {
	f := siblingCodexPane(t)
	host := f.host()
	released := make(chan struct{})
	defer close(released)
	entered := make(chan struct{})
	host.NativeProcessStart = func(string, int64, string) (uint64, error) { close(entered); <-released; return 4242, nil }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := &runner{ctx: ctx, host: host, proc: defaultSource(), uid: int64(os.Getuid()), home: f.path("home")}
	result := make(chan bool, 1)
	go func() {
		_, ok := r.stockProxyCandidate(f.pane, map[int64]string{int64(f.pids["codex"]): "codex"})
		result <- ok
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("native proof callback not entered")
	}
	cancel()
	select {
	case ok := <-result:
		if ok {
			t.Fatal("cancelled proof was admitted")
		}
	case <-time.After(time.Second):
		t.Fatal("native callback ignored cancellation")
	}
}

// Two independent authorities can revoke or restore the saved proxy and the
// kernel incarnation. Check every depth-three ordering through the real
// selector after every operation, with explicit model state as the oracle.
func TestStockProxySelectionBounded(t *testing.T) {
	sequences, transitions := 0, 0
	for code := 0; code < 64; code++ {
		bindingValid, startValid := true, true
		current := code
		for step := 0; step < 3; step++ {
			event := current % 4
			current /= 4
			switch event {
			case 0:
				bindingValid = false
			case 1:
				bindingValid = true
			case 2:
				startValid = false
			case 3:
				startValid = true
			}
			bound := map[string]any{"version": 1, "producer": map[string]any{"pane_id": "pane", "provider": "codex", "process_id": 123, "process_start": 4242}, "session_id": threadA, "source": "stock_app_server_proxy", "revision": revision, "stock_proxy": map[string]any{"proxy_pid": 2, "proxy_start": 3, "control_device": 4, "control_inode": 5, "connection": 6, "selection": 7, "control_socket": "/tmp/control"}, "native_endpoint": map[string]any{"daemon_pid": 456, "daemon_start": 777, "socket": "/tmp/daemon"}}
			if !bindingValid {
				bound["revision"] = "revoked"
			}
			raw, _ := json.Marshal(bound)
			host := Host{Binding: func(string, string) ([]byte, error) { return raw, nil }, NativeProcessStart: func(string, int64, string) (uint64, error) {
				if startValid {
					return 4242, nil
				}
				return 9999, nil
			}}
			r := &runner{ctx: context.Background(), host: host}
			selected, ok := r.stockProxyCandidate("pane", map[int64]string{123: "codex", 456: "codex"})
			want := bindingValid && startValid
			if ok != want || (ok && selected != 123) {
				t.Fatalf("authorization conjunction failed sequence=%d step=%d selected=%d ok=%v want=%v", code, step, selected, ok, want)
			}
			transitions++
		}
		sequences++
	}
	if sequences != 64 || transitions != 192 {
		t.Fatalf("bounded enumeration changed: %d %d", sequences, transitions)
	}
	t.Logf("actors=2 alphabet=4 depth=3 sequences=%d transitions=%d", sequences, transitions)
}
