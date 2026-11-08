package desktoproute

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/websocket"
)

func TestOriginalTaskPickerDetailsAndPrivateInspection(t *testing.T) {
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	path := filepath.Join(home, "private.sock")
	listener := unixFixture(t, path)
	global := unixFixture(t, d.workSocket())
	var globalCalls atomic.Int32
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			c, e := global.AcceptUnix()
			if e != nil {
				return
			}
			globalCalls.Add(1)
			c.Close()
		}
	}()
	var mu sync.Mutex
	var methods []string
	server := http.Server{Handler: websocket.Handler(func(ws *websocket.Conn) {
		defer ws.Close()
		for {
			var raw []byte
			if websocket.Message.Receive(ws, &raw) != nil {
				return
			}
			var req struct {
				ID     int            `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if json.Unmarshal(raw, &req) != nil {
				return
			}
			mu.Lock()
			methods = append(methods, req.Method)
			mu.Unlock()
			var result any
			switch req.Method {
			case "initialize":
				result = map[string]any{}
			case "thread/loaded/list":
				result = map[string]any{"data": []string{"task-b", "task-a"}}
			case "thread/read":
				if req.Params["includeTurns"] != false {
					t.Error("task details requested conversation turns")
				}
				state := "idle"
				if req.Params["threadId"] == "task-a" {
					state = "active"
				}
				result = map[string]any{"thread": map[string]any{"id": req.Params["threadId"], "name": "Review network", "status": map[string]string{"type": state}}}
			default:
				t.Error("picker or inspect attempted unexpected/resume method", req.Method)
				return
			}
			b, _ := json.Marshal(map[string]any{"id": req.ID, "result": result})
			if websocket.Message.Send(ws, string(b)) != nil {
				return
			}
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	ids, e := d.Loaded(ctx, path)
	if e != nil || !reflect.DeepEqual(ids, []string{"task-a", "task-b"}) {
		t.Fatal("picker not exact sorted loaded tasks", ids, e)
	}
	mu.Lock()
	first := append([]string{}, methods...)
	mu.Unlock()
	if !reflect.DeepEqual(first, []string{"initialize", "thread/loaded/list"}) {
		t.Fatal("ID-only picker read more than loaded tasks", first)
	}
	details, e := d.Tasks(ctx, path)
	if e != nil || len(details) != 2 || details[0].ID != "task-a" || details[1].ID != "task-b" || details[0].Status != "active" || details[1].Status != "idle" || details[0].Name == nil || details[1].Name == nil || *details[0].Name != "Review network" || *details[1].Name != "Review network" {
		t.Fatal("loaded names/status changed", details, e)
	}
	selected, e := d.Inspect(ctx, path, "task-a", true)
	if e != nil || selected.ID != "task-a" || selected.Transport != "app_server" {
		t.Fatal("private inspection used another provider", selected, e)
	}
	if _, e := d.Inspect(ctx, path, "absent", true); e == nil {
		t.Fatal("unloaded private task accepted")
	}
	global.Close()
	<-done
	if globalCalls.Load() != 0 || exists(d.workRoot()) {
		t.Fatal("private fixture used or committed global Work endpoint", globalCalls.Load())
	}
}

func TestOriginalDesktopGroupActualSocketBothDirections(t *testing.T) {
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	listener := unixFixture(t, d.legacySocket())
	var mu sync.Mutex
	loaded := []string{"a", "b", "c"}
	var received []map[string]any
	server := http.Server{Handler: websocket.Handler(func(ws *websocket.Conn) {
		defer ws.Close()
		for {
			var raw []byte
			if websocket.Message.Receive(ws, &raw) != nil {
				return
			}
			var req struct {
				ID     int            `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if json.Unmarshal(raw, &req) != nil {
				return
			}
			var result any = map[string]any{}
			switch req.Method {
			case "initialize":
			case "thread/loaded/list":
				mu.Lock()
				result = map[string]any{"data": append([]string{}, loaded...)}
				mu.Unlock()
			case "turn/start":
				mu.Lock()
				received = append(received, req.Params)
				result = map[string]any{"turn": map[string]string{"id": fmt.Sprintf("turn-%d", len(received))}}
				mu.Unlock()
			default:
				t.Error("unexpected group socket method", req.Method)
				return
			}
			b, _ := json.Marshal(map[string]any{"id": req.ID, "result": result})
			if websocket.Message.Send(ws, string(b)) != nil {
				return
			}
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	p := desktopPlan()
	p.Topology = "coordinator"
	p.Coordinator = "desktop:laptop:a"
	p.Participants = []participant{{Kind: "desktop", Host: "laptop", Session: "a", Name: "a"}, {Kind: "desktop", Host: "laptop", Session: "b", Name: "b"}, {Kind: "desktop", Host: "laptop", Session: "c", Name: "c"}}
	r := &runtime{home: home, exe: "/private/relayd", desktop: d}
	raw, _ := json.Marshal(p)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	state, e := r.applyGroup(ctx, p, raw)
	if e != nil || state.State != "introductions_attempted" {
		t.Fatal(state, e)
	}
	path := filepath.Join(home, ".local/state/relay/peer-groups", strings.ToLower(p.ID)+".json")
	for _, edge := range [][2]string{{"a", "b"}, {"b", "a"}} {
		sent, e := r.sendGroup(ctx, path, edge[0], edge[1], "hello "+edge[1])
		if e != nil || sent.Receipt != "admitted" {
			t.Fatal("group socket delivery failed", sent, e)
		}
		mu.Lock()
		last := received[len(received)-1]
		mu.Unlock()
		var envelope map[string]any
		output := last["toolOutput"].(map[string]any)["output"].(string)
		if e := json.Unmarshal([]byte(output), &envelope); e != nil {
			t.Fatal(e)
		}
		if last["threadId"] != edge[1] || len(last["input"].([]any)) != 0 || envelope["sender"] != "Relay desktop task "+edge[0] {
			t.Fatal("group sender/target/authority changed", last, envelope)
		}
	}
	if _, e := r.sendGroup(ctx, path, "b", "c", "non-edge"); e == nil {
		t.Fatal("non-star edge sent")
	}
	mu.Lock()
	loaded = []string{"a", "c"}
	count := len(received)
	mu.Unlock()
	if _, e := r.sendGroup(ctx, path, "a", "b", "closed"); e == nil {
		t.Fatal("closed target sent")
	}
	if _, e := r.applyGroup(ctx, p, raw); e == nil {
		t.Fatal("closed group applied")
	}
	mu.Lock()
	loaded = []string{"a", "b", "c"}
	mu.Unlock()
	if _, e := r.applyGroup(ctx, p, raw); e == nil {
		t.Fatal("duplicate group replayed")
	}
	mu.Lock()
	after := len(received)
	mu.Unlock()
	if after != count {
		t.Fatal("failed/duplicate group wrote socket", after, count)
	}
}

func TestWorkInspectReadOnlyPrepareAndConcurrentSelectedChange(t *testing.T) {
	for _, scenario := range []string{"read-only", "prepare", "concurrent-selected-change", "unavailable"} {
		t.Run(scenario, func(t *testing.T) {
			d, r := retirementWork(t)
			if e := d.commitWork(r, nil); e != nil {
				t.Fatal(e)
			}
			initial, e := os.ReadFile(filepath.Join(d.workRoot(), r.Thread+".json"))
			if e != nil {
				t.Fatal(e)
			}
			listener := unixFixture(t, d.workSocket())
			var methods atomic.Int32
			done := make(chan struct{})
			go func() {
				defer close(done)
				for {
					conn, e := listener.AcceptUnix()
					if e != nil {
						return
					}
					func(conn *net.UnixConn) {
						defer conn.Close()
						conn.SetDeadline(time.Now().Add(3 * time.Second))
						for {
							req, e := readRequest(conn)
							if e != nil {
								return
							}
							methods.Add(1)
							method := req["method"].(string)
							reply := map[string]any{"type": "response", "requestId": req["requestId"], "method": method, "resultType": "success"}
							switch method {
							case "initialize":
								reply["result"] = map[string]string{"clientId": "33333333-3333-3333-3333-333333333333"}
							case "thread-owner-discovery":
								if scenario == "unavailable" {
									return
								}
								if scenario == "concurrent-selected-change" {
									other := r
									other.Owner = "44444444-4444-4444-4444-444444444444"
									if e := d.commitWork(other, &r); e != nil {
										t.Error(e)
									}
								}
								reply["handledByClientId"] = "22222222-2222-2222-2222-222222222222"
								reply["result"] = map[string]bool{"supportsUntrustedAppInput": true}
							default:
								t.Error("inspection resumed or sent to task", method)
								return
							}
							if writeWorkResponse(conn, reply) != nil {
								return
							}
						}
					}(conn)
				}
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			result, e := d.Inspect(ctx, d.legacySocket(), r.Thread, scenario != "read-only")
			listener.Close()
			<-done
			final, readErr := os.ReadFile(filepath.Join(d.workRoot(), r.Thread+".json"))
			if readErr != nil {
				t.Fatal(readErr)
			}
			switch scenario {
			case "read-only":
				if e != nil || result.ID != r.Thread || result.Transport != "work_ipc" || !bytes.Equal(initial, final) {
					t.Fatal("read-only inspection committed or chose another task", result, e)
				}
			case "prepare":
				got, e2 := d.readWork(filepath.Join(d.workRoot(), r.Thread+".json"))
				if e != nil || e2 != nil || got.Owner != "22222222-2222-2222-2222-222222222222" {
					t.Fatal("prepare did not refresh captured selected identity", got, e, e2)
				}
			case "concurrent-selected-change":
				got, e2 := d.readWork(filepath.Join(d.workRoot(), r.Thread+".json"))
				if e == nil || e2 != nil || got.Owner != "44444444-4444-4444-4444-444444444444" {
					t.Fatal("prepare overwrote concurrent selected identity", got, e, e2)
				}
			case "unavailable":
				if e == nil || !bytes.Equal(initial, final) {
					t.Fatal("unavailable exact task changed reference", e)
				}
			}
			if methods.Load() != 2 {
				t.Fatal("inspection requested unexpected methods", methods.Load())
			}
		})
	}
}

func TestHostListenerOriginalRecoveryTransitions(t *testing.T) {
	for _, scenario := range []string{"resume", "refused-retry", "answered-clears-pending", "superseded-launch", "ended-unread", "ended-empty", "running-successor"} {
		t.Run(scenario, func(t *testing.T) {
			c, e := openCheckpoint(privateTemp(t), "host", []string{"relayd", "desktop-remote", "listen"})
			if e != nil {
				t.Fatal(e)
			}
			defer c.lock.Close()
			original := c.state.Job
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			frame := []byte("{\"type\":\"message\",\"id\":\"m\"}\n")
			ready := []byte("{\"type\":\"ready\",\"pid\":9}\n")
			handled := 0
			spec := map[string]any{"executable": "relayd", "owner_pid": 4242, "owner_session": "session", "owner_start": "123", "route": "route"}
			if scenario == "refused-retry" {
				f := &fakeHost{respond: func(int, hostCall) (hostResult, error) { return hostResult{}, errors.New("execution was not started") }}
				if e := listenHost(ctx, f, c, spec, func([]byte) error { return nil }); e == nil || !c.state.Pending {
					t.Fatal("refused exec lost reservation", e)
				}
			}
			if scenario == "resume" || scenario == "ended-unread" || scenario == "ended-empty" || scenario == "running-successor" {
				c.state.Purpose = "peer_listener"
				if e := c.save(); e != nil {
					t.Fatal(e)
				}
			}
			f := &fakeHost{respond: func(i int, call hostCall) (hostResult, error) {
				stop := func() (hostResult, error) { cancel(); return hostResult{}, context.Canceled }
				if call.op == "exec" {
					if call.values["kind"] != "peer_listener_v1" || call.values["argv"] != nil || !reflect.DeepEqual(call.values["listener"], spec) {
						t.Error("listener launch lost typed identity", call)
					}
					if scenario == "answered-clears-pending" {
						return hostResult{State: "unknown_after_daemon_restart"}, nil
					}
					if scenario == "superseded-launch" {
						return hostResult{State: "failed", Successor: "job-successor"}, nil
					}
					return hostResult{State: "running"}, nil
				}
				switch scenario {
				case "resume", "running-successor":
					if i == 0 {
						return statusResult("running", nil, 0), nil
					}
					if i == 1 {
						v := statusResult("running", ready, int64(len(ready)))
						v.Job.PID = 9
						return v, nil
					}
					if scenario == "running-successor" {
						if i == 2 {
							return statusResult("running", frame, int64(len(frame))), nil
						}
						if i == 3 {
							v := statusResult("exited", nil, int64(len(frame)))
							v.Job.Successor = "job-successor"
							return v, nil
						}
					}
					return stop()
				case "ended-unread":
					if i == 0 {
						return statusResult("exited", nil, 0), nil
					}
					if i == 1 || i == 2 {
						return statusResult("exited", frame, int64(len(frame))), nil
					}
					return statusResult("exited", nil, int64(len(frame))), nil
				case "ended-empty":
					if i <= 1 {
						return statusResult("exited", nil, 0), nil
					}
					return stop()
				default:
					return stop()
				}
			}}
			e = listenHost(ctx, f, c, spec, func(raw []byte) error { handled++; return nil })
			if e == nil {
				t.Fatal("fixture termination disappeared")
			}
			var saved checkpointState
			if e := readJSONFile(c.path, 16384, &saved); e != nil {
				t.Fatal(e)
			}
			if saved.Pending {
				t.Fatal("answered exec retained pending state")
			}
			execs := 0
			for _, call := range f.calls {
				if call.op == "exec" {
					execs++
				}
			}
			switch scenario {
			case "resume":
				if execs != 0 || handled != 1 || saved.Job != original {
					t.Fatal("running listener reexecuted or ready lost", f.calls, handled, saved)
				}
			case "refused-retry":
				if f.calls[0].op != "exec" || f.calls[0].job != original || execs != 1 {
					t.Fatal("refused listener did not retry same reserved job", f.calls)
				}
			case "answered-clears-pending":
				if len(f.calls) != 1 || saved.Job != original {
					t.Fatal("answered ambiguous launch replayed", f.calls, saved)
				}
			case "superseded-launch", "running-successor":
				last := f.calls[len(f.calls)-1]
				if saved.Job != "job-successor" || last.job != "job-successor" || last.values["stdout_offset"] != int64(0) {
					t.Fatal("successor identity or offset lost", last, saved)
				}
			case "ended-unread":
				if execs != 0 || handled != 1 || saved.Job != original || saved.Out != int64(len(frame)) {
					t.Fatal("ended unread event lost or rotated early", f.calls, handled, saved)
				}
			case "ended-empty":
				if execs != 1 || saved.Job == original || !exists(c.path+".previous-"+original) {
					t.Fatal("ended empty listener failed to rotate once", f.calls, saved)
				}
			}
		})
	}
}

func retirementWork(t *testing.T) (*nativeDesktop, workReference) {
	t.Helper()
	d := &nativeDesktop{home: privateTemp(t), inspect: func(int) (processInfo, error) {
		return processInfo{WorkStart: "Sun Oct 25 01:02:03 2026", Executable: workApp}, nil
	}}
	return d, workReference{1, "selected", "local", d.workSocket(), workApp, os.Getpid(), "Sun Oct 25 01:02:03 2026", "11111111-1111-1111-1111-111111111111"}
}

func TestWorkRegistryExactCapCASAndIncarnation(t *testing.T) {
	d, r := retirementWork(t)
	other := r
	other.Thread = "other"
	if e := d.commitWork(other, nil); e != nil {
		t.Fatal(e)
	}
	if e := d.commitWork(r, nil); e != nil {
		t.Fatal(e)
	}
	next := r
	next.Owner = "22222222-2222-2222-2222-222222222222"
	if e := d.commitWork(next, &r); e != nil {
		t.Fatal(e)
	}
	if e := d.commitWork(r, &r); e == nil {
		t.Fatal("stale CAS overwrote selected reference")
	}
	for _, want := range []workReference{other, next} {
		path := filepath.Join(d.workRoot(), want.Thread+".json")
		got, e := d.readWork(path)
		if e != nil || got == nil || *got != want {
			t.Fatal("selected refresh changed another task", got, e)
		}
		st, e := os.Stat(path)
		if e != nil || st.Mode().Perm() != 0600 {
			t.Fatal("registry reference is not private", e)
		}
	}
	for i := 2; i < 16; i++ {
		row := r
		row.Thread = fmt.Sprintf("task%d", i)
		if e := d.commitWork(row, nil); e != nil {
			t.Fatal(e)
		}
	}
	overflow := r
	overflow.Thread = "seventeenth"
	if e := d.commitWork(overflow, nil); e == nil {
		t.Fatal("seventeenth task passed registry cap")
	}
	if exists(filepath.Join(d.workRoot(), overflow.Thread+".json")) {
		t.Fatal("overflow task written")
	}
	// Refresh remains legal at the exact cap, without removing any other row.
	if e := d.commitWork(r, &next); e != nil {
		t.Fatal("refresh at cap refused", e)
	}
	files, e := jsonFiles(d.workRoot(), 16)
	if e != nil || len(files) != 16 {
		t.Fatal("registry cardinality changed", files, e)
	}
	d2, r2 := retirementWork(t)
	d2.inspect = func(int) (processInfo, error) { return processInfo{}, errors.New("changed incarnation") }
	if e := d2.commitWork(r2, nil); e == nil {
		t.Fatal("changed app incarnation committed")
	}
	if exists(filepath.Join(d2.workRoot(), r2.Thread+".json")) {
		t.Fatal("changed app reference written")
	}
}

func TestRuntimeReconnectRemainsBoundedAfterNineDisconnects(t *testing.T) {
	expected := []time.Duration{1, 2, 4, 8, 16, 30, 30, 30, 30}
	for i, w := range expected {
		if reconnectDelay(i) != w*time.Second {
			t.Fatalf("backoff[%d]=%s", i, reconnectDelay(i))
		}
	}
	if reconnectDelay(100000) != 30*time.Second {
		t.Fatal("large reconnect attempt escaped bound")
	}
	home := privateTemp(t)
	c := configFixture()
	path := filepath.Join(home, "route.json")
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := &fakeHost{respond: func(int, hostCall) (hostResult, error) { return hostResult{}, errors.New("fixture disconnect") }}
	var waits []time.Duration
	r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { return f }, wait: func(_ context.Context, d time.Duration) error {
		waits = append(waits, d)
		if len(waits) == 9 {
			cancel()
			return ctx.Err()
		}
		return nil
	}}
	if e := r.listen(ctx, c, path); !errors.Is(e, context.Canceled) {
		t.Fatal("reconnect loop ended before ninth disconnect", e)
	}
	for i := range expected {
		expected[i] *= time.Second
	}
	if !reflect.DeepEqual(waits, expected) || len(f.calls) != 9 {
		t.Fatal("reconnect loop abandoned listener", waits, len(f.calls))
	}
	for _, call := range f.calls {
		if call.op != "exec" || call.job != f.calls[0].job {
			t.Fatal("pending listener changed job identity", call)
		}
	}
}

func TestRuntimeIdentityChangeStopsWithoutRebind(t *testing.T) {
	home := privateTemp(t)
	c := configFixture()
	path := filepath.Join(home, "route.json")
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	line := []byte("{\"type\":\"identity_changed\"}\n")
	f := &fakeHost{respond: func(i int, call hostCall) (hostResult, error) {
		if call.op == "exec" {
			return hostResult{State: "running"}, nil
		}
		return statusResult("running", line, int64(len(line))), nil
	}}
	r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { return f }, wait: func(context.Context, time.Duration) error { t.Fatal("identity change retried"); return nil }}
	if e := r.listen(context.Background(), c, path); e != nil {
		t.Fatal(e)
	}
	var state RouteState
	if e := readJSONFile(r.status(c), 16384, &state); e != nil || state.State != "needs_attention" || !state.RebindRequired || state.Mailbox != nil {
		t.Fatal("identity change did not hold exact route", state, e)
	}
	after, e := readConfig(path)
	if e != nil || after != c {
		t.Fatal("identity change rebound configuration", after, e)
	}
	execs := 0
	for _, call := range f.calls {
		if call.op == "exec" {
			execs++
		}
	}
	if execs != 1 {
		t.Fatal("identity change launched replacement", execs)
	}
}

func TestRuntimeCLIHasDistinctSinglePrivateFailureReceipt(t *testing.T) {
	for _, dispatched := range []bool{false, true} {
		t.Run(fmt.Sprint(dispatched), func(t *testing.T) {
			home := privateTemp(t)
			c := configFixture()
			path := filepath.Join(home, "route.json")
			if e := atomicJSON(path, c); e != nil {
				t.Fatal(e)
			}
			f := &fakeHost{respond: func(int, hostCall) (hostResult, error) { return hostResult{}, errors.New("private diagnostic") }}
			d := &fakeDesktop{closed: map[string]bool{c.Thread: !dispatched}}
			r := &runtime{home: home, desktop: d, host: func(string) hostAPI { return f }}
			if dispatched {
				if e := privateDirectory(filepath.Dir(r.status(c)), true); e != nil {
					t.Fatal(e)
				}
				state := RouteState{Schema: 1, PID: os.Getpid(), Host: c.Host, LocalName: c.LocalName, LocalSession: c.Thread, RemoteName: c.RemoteName, RemoteSession: c.RemoteSession, RemotePID: c.RemotePID, RemoteStart: c.RemoteStart, State: "online", Heartbeat: float64(time.Now().UnixNano()) / 1e9, Mailbox: &Mailbox{PID: 456, Start: "123", Name: c.LocalName}}
				if e := atomicJSON(r.status(c), state); e != nil {
					t.Fatal(e)
				}
			}
			var out bytes.Buffer
			e := r.run(context.Background(), []string{"send", "--config", path}, strings.NewReader(`{"id":"message","sender":"peer","content":"body"}`), &out)
			if e == nil {
				t.Fatal("fixture failure disappeared")
			}
			raw := out.String()
			dec := json.NewDecoder(&out)
			var result Delivery
			if e := dec.Decode(&result); e != nil {
				t.Fatal("missing single receipt", e)
			}
			want := "not_sent"
			if dispatched {
				want = "unknown"
			}
			if result.Receipt != want || result.RetrySafe {
				t.Fatal("uncertainty collapsed", result)
			}
			var extra any
			if e := dec.Decode(&extra); e != io.EOF {
				t.Fatal("multiple CLI responses", e)
			}
			if strings.Contains(raw, "private diagnostic") {
				t.Fatal("private diagnostic leaked")
			}
			if len(f.calls) != map[bool]int{false: 0, true: 1}[dispatched] {
				t.Fatal("unexpected host dispatch count", len(f.calls))
			}
		})
	}
}

func TestRuntimeCLIPreflightAlwaysEmitsOneReceipt(t *testing.T) {
	for _, kind := range []string{"missing-config", "bad-config", "bad-envelope", "oversized-envelope"} {
		t.Run(kind, func(t *testing.T) {
			home := privateTemp(t)
			r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { t.Fatal("preflight dispatched"); return nil }}
			config := filepath.Join(home, "route.json")
			body := "{}"
			if kind != "missing-config" {
				var value any = configFixture()
				if kind == "bad-config" {
					value = map[string]any{}
				}
				if e := atomicJSON(config, value); e != nil {
					t.Fatal(e)
				}
			}
			if kind == "oversized-envelope" {
				body = strings.Repeat("x", messageLimit+1)
			}
			var out bytes.Buffer
			if e := r.run(context.Background(), []string{"send", "--config", config}, strings.NewReader(body), &out); e == nil {
				t.Fatal("invalid preflight accepted")
			}
			dec := json.NewDecoder(&out)
			var v map[string]any
			if e := dec.Decode(&v); e != nil || v["receipt"] != "not_sent" || v["retrySafe"] != false || v["error"] != nil {
				t.Fatal("preflight lacks redacted not-sent receipt", v, e)
			}
			if e := dec.Decode(&v); e != io.EOF {
				t.Fatal("preflight emitted multiple responses", e)
			}
		})
	}
}

func TestPrivateDesktopSocketLinkAndStatusContract(t *testing.T) {
	root := privateTemp(t)
	target := filepath.Join(root, "target/server.sock")
	unixFixture(t, target)
	linkDir := filepath.Join(root, "link")
	if e := privateDirectory(linkDir, true); e != nil {
		t.Fatal(e)
	}
	link := filepath.Join(linkDir, "current.sock")
	if e := os.Symlink(target, link); e != nil {
		t.Fatal(e)
	}
	id, e := checkSocket(link)
	if e != nil || id.path != target {
		t.Fatal("private desktop socket link refused", id, e)
	}
	if e := os.Chmod(filepath.Dir(target), 0755); e != nil {
		t.Fatal(e)
	}
	if _, e := checkSocket(link); e == nil {
		t.Fatal("public symlink target directory accepted")
	}
	os.Chmod(filepath.Dir(target), 0700)
	os.Chmod(target, 0666)
	if _, e := checkSocket(target); e == nil {
		t.Fatal("public socket accepted")
	}
	path := filepath.Join(root, "status.json")
	for _, state := range []string{"connecting", "online"} {
		if e := atomicJSON(path, map[string]string{"state": state}); e != nil {
			t.Fatal(e)
		}
	}
	var got map[string]string
	if e := readJSONFile(path, 1024, &got); e != nil || got["state"] != "online" {
		t.Fatal(got, e)
	}
	st, e := os.Stat(path)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("atomic replacement not private", e)
	}
	os.Chmod(path, 0644)
	if e := readJSONFile(path, 1024, &got); e == nil {
		t.Fatal("public status read")
	}
}

func TestReplacementRequiresUniqueLiveSameSessionAndSupervisorAdopts(t *testing.T) {
	home := privateTemp(t)
	registry := filepath.Join(home, "sessions")
	if e := privateDirectory(registry, true); e != nil {
		t.Fatal(e)
	}
	remote := &remoteRuntime{home: home, inspect: func(int) (processInfo, error) { return processInfo{Start: "123"}, nil }}
	for _, pid := range []int{42, 43} {
		path := filepath.Join(registry, fmt.Sprintf("%d.sock", pid))
		unixFixture(t, path)
		record := peerRecord{PID: pid, Name: fmt.Sprintf("peer-%d", pid), Session: "same", Start: "123", Socket: path}
		if e := atomicJSON(filepath.Join(registry, fmt.Sprintf("%d.json", pid)), record); e != nil {
			t.Fatal(e)
		}
	}
	if _, e := remote.replacement(registry, "same"); !errors.Is(e, errIdentity) {
		t.Fatal("multiple live replacements accepted", e)
	}
	os.Remove(filepath.Join(registry, "43.json"))
	got, e := remote.replacement(registry, "same")
	if e != nil || got == nil || got.PID != 42 || got.Start != "123" || got.Name != "peer-42" {
		t.Fatal("unique replacement lost", got, e)
	}
	if got, e := remote.replacement(registry, "different"); e != nil || got != nil {
		t.Fatal("different session adopted", got, e)
	}
	remote.inspect = func(int) (processInfo, error) { return processInfo{Start: "changed"}, nil }
	if got, e := remote.replacement(registry, "same"); e != nil || got != nil {
		t.Fatal("stale replacement adopted", got, e)
	}
	c := configFixture()
	path := filepath.Join(home, "route.json")
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	execs := 0
	line, _ := json.Marshal(routeEvent{Type: "identity_replacement", Session: c.RemoteSession, PID: 222, Start: "456", Name: "new-peer"})
	line = append(line, '\n')
	f := &fakeHost{respond: func(i int, call hostCall) (hostResult, error) {
		if call.op == "exec" {
			execs++
			if execs == 2 {
				spec := call.values["listener"].(map[string]any)
				if spec["owner_pid"] != 222 || spec["owner_start"] != "456" || spec["owner_session"] != c.RemoteSession || spec["route"] != c.LocalName {
					t.Error("replacement launch not pinned", spec)
				}
				cancel()
				return hostResult{}, ctx.Err()
			}
			return hostResult{State: "running"}, nil
		}
		return statusResult("running", line, int64(len(line))), nil
	}}
	r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { return f }, wait: func(context.Context, time.Duration) error {
		t.Fatal("same-session adoption waited instead of restarting")
		return nil
	}}
	if e := r.listen(ctx, c, path); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	after, e := readConfig(path)
	want := c
	want.RemotePID = 222
	want.RemoteStart = "456"
	want.RemoteName = "new-peer"
	if e != nil || after != want || execs != 2 {
		t.Fatal("supervisor changed more than remote incarnation", after, e, execs)
	}
}

func TestRemoteRegistryFallbackAndFailures(t *testing.T) {
	home := privateTemp(t)
	root := filepath.Join(home, ".claude/sessions")
	if e := privateDirectory(root, true); e != nil {
		t.Fatal(e)
	}
	r := &remoteRuntime{home: home, inspect: func(int) (processInfo, error) { return processInfo{Start: "123"}, nil }, environment: func(int, ...string) (map[string]string, error) { return map[string]string{}, nil }}
	if got, e := r.registry(42, "123"); e != nil || got != root {
		t.Fatal("default account changed", got, e)
	}
	r.environment = func(int, ...string) (map[string]string, error) {
		return map[string]string{"CLAUDE_CONFIG_DIR": "relative/.claude"}, nil
	}
	if _, e := r.registry(42, "123"); e == nil || e.Error() != "invalid account path" {
		t.Fatal("relative account path accepted or misclassified", e)
	}
	sentinel := errors.New("agent environment unavailable")
	r.environment = func(int, ...string) (map[string]string, error) { return nil, sentinel }
	if _, e := r.registry(42, "123"); !errors.Is(e, sentinel) {
		t.Fatal("live capture error concealed", e)
	}
	r.inspect = func(int) (processInfo, error) { return processInfo{}, errors.New("ended") }
	if _, e := r.registry(42, "123"); !errors.Is(e, errIdentity) {
		t.Fatal("ended recipient did not require rebinding", e)
	}
}

func TestMixedGroupPinsRemoteAndFailedSetupSendsNothing(t *testing.T) {
	home := privateTemp(t)
	p := desktopPlan()
	p.Topology = "coordinator"
	p.Coordinator = "desktop:laptop:a"
	p.Participants = []participant{{Kind: "desktop", Host: "laptop", Session: "a", Name: "a"}, {Kind: "native", Host: "dandy-07", Session: "remote", Name: "peer", PID: 42, Start: "123"}, {Kind: "native", Host: "dandy-08", Session: "remote2", Name: "peer2", PID: 43, Start: "456"}}
	edges, e := p.edges()
	if e != nil || len(edges) != 2 || edges[0][1].Start != "123" || edges[1][1].Start != "456" {
		t.Fatal("star remote incarnations not pinned", edges, e)
	}
	d := &fakeDesktop{}
	r := &runtime{home: home, exe: "/private/relayd", desktop: d, service: func(context.Context, ...string) error { return errors.New("fixture service unavailable") }}
	raw, _ := json.Marshal(p)
	state, e := r.applyGroup(context.Background(), p, raw)
	if e == nil || state.State != "needs_attention" || len(state.Introductions) != 0 || len(d.delivered) != 0 {
		t.Fatal("failed route sent introductions", state, e)
	}
	path := filepath.Join(home, ".local/state/relay/peer-groups", strings.ToLower(p.ID)+".json")
	var saved groupState
	if e := readJSONFile(path, 1<<20, &saved); e != nil || !reflect.DeepEqual(saved, state) {
		t.Fatal("failed setup receipt not preserved", saved, e)
	}
	st, e := os.Stat(path)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("group receipt not private", e)
	}
}

func TestReplyMailboxStableSingleOwnerBusyIsClean(t *testing.T) {
	name := "retirement-" + uuid()
	root := mailboxRoot(os.Getuid())
	if e := privateDirectory(root, true); e != nil {
		t.Fatal(e)
	}
	dir := filepath.Join(root, hash([]byte(name))[:24])
	if e := privateDirectory(dir, true); e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(dir)
	lock, e := fileLock(filepath.Join(dir, "lock"), true)
	if e != nil {
		t.Fatal(e)
	}
	defer lock.Close()
	path := filepath.Join(dir, "peer.sock")
	listener := unixFixture(t, path)
	defer listener.Close()
	before, e := os.Stat(path)
	if e != nil {
		t.Fatal(e)
	}
	registry := privateTemp(t)
	record := filepath.Join(registry, "42.json")
	sentinel := []byte("unchanged-owner-record")
	if e := os.WriteFile(record, sentinel, 0600); e != nil {
		t.Fatal(e)
	}
	r := &remoteRuntime{inspect: func(int) (processInfo, error) {
		t.Fatal("losing listener reached process setup")
		return processInfo{}, nil
	}}
	var out bytes.Buffer
	if e := r.listen(context.Background(), registry, "", peerRecord{}, name, &out); e != nil || out.String() != "{\"type\":\"mailbox_busy\"}\n" {
		t.Fatal("busy listener did not exit cleanly", out.String(), e)
	}
	after, e := os.Stat(path)
	if e != nil || !os.SameFile(before, after) {
		t.Fatal("losing listener replaced serving address", e)
	}
	data, e := os.ReadFile(record)
	if e != nil || !bytes.Equal(data, sentinel) {
		t.Fatal("losing listener altered registration", e)
	}
	lock.Close()
	again, e := fileLock(filepath.Join(dir, "lock"), true)
	if e != nil {
		t.Fatal("stable mailbox cannot be reacquired", e)
	}
	again.Close()
}

func TestUnknownHostArgumentsNeverAcquireTypedListenerAuthority(t *testing.T) {
	known := []string{".local/bin/relayd", "desktop-remote", "listen", "4242", "session", "123", "route"}
	spec := listenerSpec(known)
	if spec == nil || spec["owner_pid"] != 4242 || spec["owner_session"] != "session" || spec["route"] != "route" {
		t.Fatal("known native listener not exactly typed", spec)
	}
	unknown := [][]string{{"listener"}, {"python3", "-u", "-c", "script", "listen", "42", "session"}, {"relayd", "other", "listen", "42", "session", "123", "route"}, {"relayd", "desktop-remote", "send", "42", "session", "123", "route"}, {"relayd", "desktop-remote", "listen", "0", "session", "123", "route"}}
	for _, args := range unknown {
		if listenerSpec(args) != nil {
			t.Fatal("unknown argv acquired typed authority", args)
		}
	}
	c, e := openCheckpoint(privateTemp(t), "host", known)
	if e != nil {
		t.Fatal(e)
	}
	defer c.lock.Close()
	f := &fakeHost{respond: func(int, hostCall) (hostResult, error) {
		t.Fatal("unrecognized listener dispatched")
		return hostResult{}, nil
	}}
	if e := listenHost(context.Background(), f, c, listenerSpec([]string{"listener"}), func([]byte) error { return nil }); e == nil || len(f.calls) != 0 || exists(c.path) {
		t.Fatal("unknown listener was admitted or reserved", e)
	}
	f = &fakeHost{respond: func(_ int, call hostCall) (hostResult, error) {
		if call.op != "exec" || call.values["kind"] != nil || call.values["listener"] != nil || !reflect.DeepEqual(call.values["argv"], []string{"private-command"}) {
			t.Error("generic exec gained listener authority", call)
		}
		return hostResult{}, errors.New("fixture refused")
	}}
	if _, e := sendHost(context.Background(), f, []string{"private-command"}, nil); e == nil || len(f.calls) != 1 {
		t.Fatal("generic exec replayed", e)
	}
}

func FuzzNativeListenerArguments(f *testing.F) {
	f.Add(` ["relayd","desktop-remote","listen","42","session","123","route"] `)
	f.Add(`["python3","-u","-c","script","listen","42","session"]`)
	f.Add(`["relayd","desktop-remote","send","42","session","123","route"]`)
	f.Fuzz(func(t *testing.T, raw string) {
		if len(raw) > 8192 {
			return
		}
		var args []string
		if json.Unmarshal([]byte(raw), &args) != nil {
			return
		}
		spec := listenerSpec(args)
		if spec == nil {
			return
		}
		if len(args) != 7 || filepath.Base(args[0]) != "relayd" || args[1] != "desktop-remote" || args[2] != "listen" || spec["owner_session"] != args[4] || spec["owner_start"] != args[5] || spec["route"] != args[6] {
			t.Fatal("unrecognized or changed arguments acquired typed authority", args, spec)
		}
	})
}

func TestOriginalDisconnectWhileAcknowledgingDrainedJobCancelsExactJob(t *testing.T) {
	home := privateTemp(t)
	c := configFixture()
	path := filepath.Join(home, "route.json")
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := &fakeDesktop{before: func(string, Envelope) { cancel() }}
	r := &runtime{home: home, desktop: d, wait: func(context.Context, time.Duration) error { t.Fatal("canceled drain reconnected"); return nil }}
	checkpoint, e := openCheckpoint(filepath.Join(home, ".local/state/relay/host-adapters"), c.Host, r.remoteArgs(c, "listen", nil))
	if e != nil {
		t.Fatal(e)
	}
	job := checkpoint.state.Job
	checkpoint.state.Purpose = "peer_listener"
	checkpoint.state.Out = 10
	if e = checkpoint.save(); e != nil {
		t.Fatal(e)
	}
	checkpoint.lock.Close()
	line := []byte("{\"type\":\"message\",\"id\":\"m4\",\"sender\":\"peer\",\"content\":\"queued\"}\n")
	statuses := 0
	f := &fakeHost{respond: func(_ int, call hostCall) (hostResult, error) {
		if call.job != job {
			t.Error("drained job identity changed", call)
		}
		if call.op == "cancel" {
			return hostResult{}, nil
		}
		if call.op != "status" {
			t.Fatal("drained job reexecuted", call)
		}
		statuses++
		if statuses == 1 {
			return hostResult{Job: hostJob{State: "exited", Successor: "job-resumed"}, Process: "absent"}, nil
		}
		if statuses <= 3 {
			v := statusResult("exited", line, 10+int64(len(line)))
			v.Job.Successor = "job-resumed"
			return v, nil
		}
		return hostResult{}, ctx.Err()
	}}
	r.host = func(string) hostAPI { return f }
	if e := r.listen(ctx, c, path); !errors.Is(e, context.Canceled) {
		t.Fatal("drain cancellation lost", e)
	}
	if len(d.delivered) != 1 || len(f.calls) == 0 {
		t.Fatal("queued event lost", len(d.delivered), f.calls)
	}
	last := f.calls[len(f.calls)-1]
	if last.job != job || last.op != "cancel" {
		t.Fatal("disconnect did not cancel exact drained job", last)
	}
	for _, call := range f.calls {
		if call.op == "exec" {
			t.Fatal("disconnect replayed listener", call)
		}
	}
}

func TestOriginalReceiptReplacementRemainsPrivateAndLeavesNoTemporaryFile(t *testing.T) {
	root := privateTemp(t)
	path := filepath.Join(root, "receipt.json")
	if e := atomicJSON(path, map[string]string{"receipt": "unknown"}); e != nil {
		t.Fatal(e)
	}
	if e := atomicJSON(path, map[string]string{"receipt": "socket_written"}); e != nil {
		t.Fatal(e)
	}
	st, e := os.Stat(path)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("replacement receipt is not private", st, e)
	}
	var value map[string]string
	if e := readJSONFile(path, 4096, &value); e != nil || value["receipt"] != "socket_written" {
		t.Fatal("replacement receipt did not persist", value, e)
	}
	files, e := os.ReadDir(root)
	if e != nil || len(files) != 1 || files[0].Name() != "receipt.json" {
		t.Fatal("receipt replacement left extra files", files, e)
	}
}
