package desktoproute

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeDesktop struct {
	closed              map[string]bool
	delivered           []Envelope
	targets             []string
	receipt, permission string
	before              func(string, Envelope)
}

func (d *fakeDesktop) Loaded(context.Context, string) ([]string, error) {
	return []string{"a", "b"}, nil
}
func (d *fakeDesktop) Tasks(context.Context, string) ([]TaskInfo, error) {
	return []TaskInfo{{ID: "a"}, {ID: "b"}}, nil
}
func (d *fakeDesktop) Verify(_ context.Context, _ string, id string) error {
	if d.closed[id] {
		return errors.New("closed task")
	}
	return nil
}
func (d *fakeDesktop) Inspect(ctx context.Context, path, id string, _ bool) (SelectedTask, error) {
	return SelectedTask{id, "work_ipc"}, d.Verify(ctx, path, id)
}
func (d *fakeDesktop) Permission(ctx context.Context, path, id string) (string, error) {
	return d.permission, d.Verify(ctx, path, id)
}
func (d *fakeDesktop) Deliver(_ context.Context, _ string, id string, m Envelope) Delivery {
	if d.before != nil {
		d.before(id, m)
	}
	d.targets = append(d.targets, id)
	d.delivered = append(d.delivered, m)
	receipt := d.receipt
	if receipt == "" {
		receipt = "admitted"
	}
	return Delivery{MessageID: m.ID, Receipt: receipt}
}

type hostCall struct {
	job, op string
	values  map[string]any
}
type fakeHost struct {
	calls   []hostCall
	respond func(int, hostCall) (hostResult, error)
}

func (f *fakeHost) request(_ context.Context, job, op string, values map[string]any) (hostResult, error) {
	c := hostCall{job, op, values}
	f.calls = append(f.calls, c)
	return f.respond(len(f.calls)-1, c)
}
func statusResult(state string, out []byte, offset int64) hostResult {
	zero := 0
	return hostResult{Job: hostJob{State: state, ExitCode: &zero}, Stdout: base64.StdEncoding.EncodeToString(out), OutOffset: offset}
}
func TestHostSendNeverRetriesAmbiguousExec(t *testing.T) {
	f := &fakeHost{respond: func(int, hostCall) (hostResult, error) { return hostResult{}, errors.New("lost reply") }}
	if _, e := sendHost(context.Background(), f, []string{"relayd", "desktop-remote"}, []byte("body")); e == nil {
		t.Fatal("uncertainty hidden")
	}
	if len(f.calls) != 1 || f.calls[0].op != "exec" {
		t.Fatal("execution replayed")
	}
}
func TestHostSendExactOffsetsAndTerminalReceipt(t *testing.T) {
	f := &fakeHost{respond: func(i int, c hostCall) (hostResult, error) {
		switch i {
		case 0:
			return hostResult{State: "running"}, nil
		case 1:
			return statusResult("exited", []byte("receipt"), 7), nil
		default:
			return statusResult("exited", nil, 7), nil
		}
	}}
	output, e := sendHost(context.Background(), f, []string{"relayd"}, []byte("input"))
	if e != nil || string(output) != "receipt" || len(f.calls) != 3 {
		t.Fatal(string(output), e, f.calls)
	}
	for _, c := range f.calls {
		if c.job != f.calls[0].job {
			t.Fatal("job binding changed")
		}
	}
	f = &fakeHost{respond: func(i int, c hostCall) (hostResult, error) {
		if i == 0 {
			return hostResult{State: "running"}, nil
		}
		return statusResult("exited", []byte("x"), 2), nil
	}}
	if _, e = sendHost(context.Background(), f, nil, nil); e == nil || e.Error() != "host output offset mismatch" || len(f.calls) != 2 {
		t.Fatalf("offset mismatch was not rejected at its first response: calls=%d error=%v", len(f.calls), e)
	}
}
func TestListenerCheckpointAfterReceiptOnly(t *testing.T) {
	root := privateTemp(t)
	c, e := openCheckpoint(root, "host", []string{"relayd", "desktop-remote", "listen"})
	if e != nil {
		t.Fatal(e)
	}
	defer c.lock.Close()
	stop := errors.New("fixture end")
	line := []byte("{\"type\":\"message\",\"id\":\"x\",\"sender\":\"peer\",\"content\":\"body\"}\n")
	f := &fakeHost{respond: func(i int, _ hostCall) (hostResult, error) {
		if i == 0 {
			return hostResult{State: "running"}, nil
		}
		return statusResult("running", line, int64(len(line))), nil
	}}
	if e = listenHost(context.Background(), f, c, map[string]any{}, func([]byte) error { return stop }); !errors.Is(e, stop) {
		t.Fatal(e)
	}
	var saved checkpointState
	if e = readJSONFile(c.path, 16384, &saved); e != nil || saved.Out != 0 || saved.Pending {
		t.Fatal("unacknowledged output advanced", saved, e)
	}
	c.present = false
	c.state = checkpointState{Job: "job-second"}
	two := append(append([]byte{}, line...), line...)
	calls := 0
	f = &fakeHost{respond: func(i int, _ hostCall) (hostResult, error) {
		if i == 0 {
			return hostResult{State: "running"}, nil
		}
		return statusResult("running", two, int64(len(two))), nil
	}}
	e = listenHost(context.Background(), f, c, map[string]any{}, func([]byte) error {
		calls++
		if calls == 2 {
			return stop
		}
		return nil
	})
	if !errors.Is(e, stop) {
		t.Fatal(e)
	}
	if e = readJSONFile(c.path, 16384, &saved); e != nil || saved.Out != int64(len(line)) {
		t.Fatal("checkpoint does not stop at first durable event", saved, e)
	}
}
func TestListenerUnresolvedStateNeverExecutes(t *testing.T) {
	for _, state := range []string{"unknown_after_daemon_restart", "queued", "unexpected"} {
		t.Run(state, func(t *testing.T) {
			c, e := openCheckpoint(privateTemp(t), "host", []string{"relayd"})
			if e != nil {
				t.Fatal(e)
			}
			defer c.lock.Close()
			c.state.Purpose = "peer_listener"
			if e = c.save(); e != nil {
				t.Fatal(e)
			}
			f := &fakeHost{respond: func(int, hostCall) (hostResult, error) {
				return hostResult{Job: hostJob{State: state}, Process: "alive"}, nil
			}}
			if e = listenHost(context.Background(), f, c, map[string]any{"executable": "relayd", "owner_pid": 4242, "owner_session": "session", "owner_start": "123", "route": "route"}, func([]byte) error { return nil }); e == nil {
				t.Fatal("unknown state accepted")
			}
			if len(f.calls) != 1 || f.calls[0].op != "status" {
				t.Fatal("unknown execution replayed", f.calls)
			}
		})
	}
}
func TestListenerAdoptsSuccessorWithoutExec(t *testing.T) {
	c, e := openCheckpoint(privateTemp(t), "host", []string{"relayd"})
	if e != nil {
		t.Fatal(e)
	}
	defer c.lock.Close()
	c.state.Purpose = "peer_listener"
	c.save()
	old := c.state.Job
	stop := errors.New("stop")
	line := []byte("{\"type\":\"heartbeat\"}\n")
	f := &fakeHost{respond: func(i int, call hostCall) (hostResult, error) {
		if call.op == "exec" {
			t.Fatal("adopted successor was executed again")
		}
		switch i {
		case 0:
			return hostResult{Job: hostJob{State: "exited", Successor: "job-successor"}}, nil
		case 1:
			return statusResult("exited", nil, 0), nil
		default:
			if call.job != "job-successor" {
				t.Fatal("did not bind successor")
			}
			return statusResult("running", line, int64(len(line))), nil
		}
	}}
	if e = listenHost(context.Background(), f, c, map[string]any{"executable": "relayd", "owner_pid": 4242, "owner_session": "session", "owner_start": "123", "route": "route"}, func([]byte) error { return stop }); !errors.Is(e, stop) {
		t.Fatal(e)
	}
	if !exists(c.path + ".previous-" + old) {
		t.Fatal("historical job reservation lost")
	}
}
func TestRuntimeSendReservesBeforeDispatchAndStripsAttestation(t *testing.T) {
	home := privateTemp(t)
	c := configFixture()
	d := &fakeDesktop{permission: "prompting"}
	r := &runtime{home: home, exe: "/app/relayd", desktop: d}
	path := filepath.Join(home, "route.json")
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	privateDirectory(filepath.Dir(r.status(c)), true)
	state := RouteState{Host: c.Host, LocalName: c.LocalName, LocalSession: c.Thread, RemoteSession: c.RemoteSession, RemotePID: c.RemotePID, RemoteStart: c.RemoteStart, State: "online", Heartbeat: float64(time.Now().Unix()), Mailbox: &Mailbox{PID: 999, Start: "111"}}
	atomicJSON(r.status(c), state)
	f := &fakeHost{respond: func(_ int, call hostCall) (hostResult, error) {
		receipt, _ := receiptPath(path)
		var rows []Receipt
		if e := readJSONFile(receipt, 65536, &rows); e != nil || len(rows) != 1 || rows[0].Status != "pending" {
			t.Fatal("dispatch preceded durable reservation", rows, e)
		}
		raw, e := base64.StdEncoding.DecodeString(call.values["stdin"].(string))
		if e != nil {
			t.Fatal(e)
		}
		var msg Envelope
		if decodeJSON(raw, messageLimit, &msg) != nil || msg.PermissionClass != "prompting" || !strings.Contains(msg.Content, "Relay-Read-Receipt: message-1") {
			t.Fatal("untrusted attestation survived or receipt absent", string(raw))
		}
		return hostResult{}, errors.New("ambiguous exec")
	}}
	r.host = func(string) hostAPI { return f }
	result, e := r.send(context.Background(), c, path, Envelope{ID: "message-1", Content: "hello", PermissionClass: "bypass"})
	if e == nil || result.Receipt != "unknown" {
		t.Fatal("ambiguous send hidden", result, e)
	}
	if _, e = r.send(context.Background(), c, path, Envelope{ID: "message-1", Content: "hello"}); !errors.Is(e, errReplay) {
		t.Fatal("same message reissued", e)
	}
	if len(f.calls) != 1 {
		t.Fatal("replay called transport")
	}
}
func desktopPlan() groupPlan {
	return groupPlan{ID: "11111111-2222-4333-8444-555555555555", Topology: "everyone", Participants: []participant{{Kind: "desktop", Host: "laptop", Session: "a", Name: "A"}, {Kind: "desktop", Host: "laptop", Session: "b", Name: "B"}}}
}
func TestDesktopGroupDurableAdmissionReplayAndExactEdges(t *testing.T) {
	home := privateTemp(t)
	d := &fakeDesktop{}
	r := &runtime{home: home, exe: "/app/relayd", desktop: d}
	plan := desktopPlan()
	receipt := filepath.Join(home, ".local/state/relay/peer-groups", plan.ID+".json")
	d.before = func(_ string, _ Envelope) {
		var state groupState
		if e := readJSONFile(receipt, messageLimit, &state); e != nil || state.Introductions[len(state.Introductions)-1].Receipt != "unknown" {
			t.Fatal("group dispatch preceded receipt", state, e)
		}
	}
	raw, _ := json.Marshal(plan)
	state, e := r.applyGroup(context.Background(), plan, raw)
	if e != nil || state.State != "introductions_attempted" || len(d.delivered) != 2 {
		t.Fatal(state, e)
	}
	if _, e = r.applyGroup(context.Background(), plan, raw); e == nil {
		t.Fatal("group repeated")
	}
	if len(d.delivered) != 2 {
		t.Fatal("duplicate group resent")
	}
	d.before = nil
	if _, e = r.sendGroup(context.Background(), receipt, "a", "c", "body"); e == nil {
		t.Fatal("non-edge sent")
	}
	for _, edge := range [][2]string{{"a", "b"}, {"b", "a"}} {
		if _, e = r.sendGroup(context.Background(), receipt, edge[0], edge[1], "body"); e != nil {
			t.Fatal(e)
		}
	}
	d.closed = map[string]bool{"a": true}
	if _, e = r.sendGroup(context.Background(), receipt, "a", "b", "body"); e == nil {
		t.Fatal("closed task sent")
	}
	if !reflect.DeepEqual(d.targets, []string{"a", "b", "b", "a"}) {
		t.Fatal(d.targets)
	}
}
func TestGroupRefusalsAndUnknownReceipt(t *testing.T) {
	for _, kind := range []string{"autonomous", "closed", "mesh", "unknown"} {
		t.Run(kind, func(t *testing.T) {
			home := privateTemp(t)
			d := &fakeDesktop{}
			r := &runtime{home: home, exe: "/app/relayd", desktop: d}
			p := desktopPlan()
			switch kind {
			case "autonomous":
				p.Autonomous = true
			case "closed":
				d.closed = map[string]bool{"a": true}
			case "mesh":
				p.Participants = append(p.Participants, participant{Kind: "native", Host: "remote", Session: "native", Name: "Native", PID: 123, Start: "456"})
			case "unknown":
				d.receipt = "unknown"
			}
			raw, _ := json.Marshal(p)
			state, e := r.applyGroup(context.Background(), p, raw)
			if e == nil {
				t.Fatal("unsafe group accepted")
			}
			if kind != "unknown" {
				if len(d.delivered) > 0 || exists(filepath.Join(home, ".local/state/relay/peer-groups")) {
					t.Fatal("validation caused side effects")
				}
			} else {
				if state.State != "needs_attention" || len(state.Introductions) != 1 || state.Introductions[0].Receipt != "unknown" {
					t.Fatal("uncertainty lost", state)
				}
			}
		})
	}
}
func TestRegistryEnvironmentRecheckedOnFailure(t *testing.T) {
	home := privateTemp(t)
	root := filepath.Join(home, "account/sessions")
	privateDirectory(root, true)
	calls := 0
	r := &remoteRuntime{home: home, inspect: func(int) (processInfo, error) {
		calls++
		start := "123"
		if calls == 2 {
			start = "124"
		}
		return processInfo{Start: start}, nil
	}, environment: func(int, ...string) (map[string]string, error) { return nil, errors.New("environment denied") }}
	if _, e := r.registry(42, "123"); !errors.Is(e, errIdentity) {
		t.Fatal("environment error concealed incarnation change", e)
	}
	r.inspect = func(int) (processInfo, error) { return processInfo{Start: "123"}, nil }
	r.environment = func(int, ...string) (map[string]string, error) {
		return map[string]string{"CLAUDE_CONFIG_DIR": filepath.Dir(root)}, nil
	}
	if got, e := r.registry(42, "123"); e != nil || got != root {
		t.Fatal("account registry not preserved", got, e)
	}
}
func TestConcurrentReservationExactlyOneActorWins(t *testing.T) {
	path := filepath.Join(privateTemp(t), "r.json")
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, e := updateReceipt(path, "one", "pending", true, time.Now()); results <- e }()
	}
	wg.Wait()
	close(results)
	wins, replays := 0, 0
	for e := range results {
		if e == nil {
			wins++
		} else if errors.Is(e, errReplay) {
			replays++
		} else {
			t.Fatal(e)
		}
	}
	if wins != 1 || replays != 1 {
		t.Fatal(wins, replays)
	}
}

func TestGroupBoundedAdmissionAndMembership(t *testing.T) {
	root := privateTemp(t)
	steps := 0
	for encoded := 0; encoded < 64; encoded++ {
		home := filepath.Join(root, fmt.Sprint(encoded))
		d := &fakeDesktop{closed: map[string]bool{}}
		r := &runtime{home: home, exe: "/app/relayd", desktop: d}
		p := desktopPlan()
		raw, _ := json.Marshal(p)
		receipt := filepath.Join(home, ".local/state/relay/peer-groups", p.ID+".json")
		ready, closed := false, false
		n := encoded
		expectedDispatches := 0
		for depth := 0; depth < 3; depth++ {
			op := n % 4
			n /= 4
			switch op {
			case 0:
				_, e := r.applyGroup(context.Background(), p, raw)
				allowed := !ready && !closed
				if (e == nil) != allowed {
					t.Fatalf("group admission sequence %d step %d: %v", encoded, depth, e)
				}
				if allowed {
					ready = true
					expectedDispatches += 2
				}
			case 1:
				_, e := r.sendGroup(context.Background(), receipt, "a", "b", "message")
				allowed := ready && !closed
				if (e == nil) != allowed {
					t.Fatal("group send availability escaped", encoded, depth, e)
				}
				if allowed {
					expectedDispatches++
				}
			case 2:
				if _, e := r.sendGroup(context.Background(), receipt, "a", "outsider", "message"); e == nil {
					t.Fatal("nonmember admitted")
				}
			case 3:
				closed = true
				d.closed["a"] = true
			}
			if len(d.delivered) != expectedDispatches {
				t.Fatal("unauthorized/duplicate group effect", encoded, depth, len(d.delivered), expectedDispatches)
			}
			steps++
		}
	}
	t.Logf("bound=3 alphabet=4 sequences=64 transitions=%d", steps)
}

func TestMailboxRootIndependentOfTMPDIR(t *testing.T) {
	t.Setenv("TMPDIR", "/private/custom-task-tmp")
	if got := mailboxRoot(501); got != "/tmp/relay-desktop-501" {
		t.Fatalf("mailbox registry relocated by TMPDIR: %s", got)
	}
}
func TestTokenRefreshHasBoundedContext(t *testing.T) {
	called := false
	transport := &hostTransport{exe: "/fixture/relayd", readHeaders: func(ctx context.Context, exe string) ([]byte, error) {
		called = true
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > 10*time.Second {
			t.Fatal("token refresh escaped its 10-second deadline")
		}
		if exe != "/fixture/relayd" {
			t.Fatal("helper executable changed")
		}
		return nil, errors.New("fixture refuses token")
	}}
	if _, e := transport.request(context.Background(), "job-fixture", "status", nil); e == nil || !called {
		t.Fatal("token failure hidden")
	}
}
