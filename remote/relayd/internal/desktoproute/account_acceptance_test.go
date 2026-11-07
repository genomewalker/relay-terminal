package desktoproute

import (
	"context"
	"encoding/base64"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// listenerScript is one remote listener process as the fake host runs it: the
// stdout and stderr it has produced by the time it exits.
type listenerScript struct {
	out, err string
}

// scriptedHost runs one script per listener exec, in order, and records the
// listener spec of each exec. Every listener has exited by its first status.
type scriptedHost struct {
	t       *testing.T
	scripts []listenerScript
	specs   []map[string]any
	jobs    map[string]listenerScript
	onExec  func(int)
}

func offsetValue(values map[string]any, key string) int {
	switch v := values[key].(type) {
	case int:
		return v
	case int64:
		return int(v)
	}
	return 0
}

func (h *scriptedHost) request(_ context.Context, job, op string, values map[string]any) (hostResult, error) {
	switch op {
	case "exec":
		spec, _ := values["listener"].(map[string]any)
		n := len(h.specs)
		h.specs = append(h.specs, spec)
		if n >= len(h.scripts) {
			h.t.Fatalf("unscripted listener exec %d", n)
		}
		h.jobs[job] = h.scripts[n]
		if h.onExec != nil {
			h.onExec(n)
		}
		return hostResult{State: "running"}, nil
	case "status":
		s, ok := h.jobs[job]
		if !ok {
			h.t.Fatalf("status for unknown job %s", job)
		}
		o, eo := min(offsetValue(values, "stdout_offset"), len(s.out)), min(offsetValue(values, "stderr_offset"), len(s.err))
		code := 0
		return hostResult{Job: hostJob{ID: job, State: "exited", ExitCode: &code}, Stdout: base64.StdEncoding.EncodeToString([]byte(s.out[o:])),
			Stderr: base64.StdEncoding.EncodeToString([]byte(s.err[eo:])), OutOffset: int64(len(s.out)), ErrOffset: int64(len(s.err))}, nil
	}
	return hostResult{}, nil
}

func (h *scriptedHost) accounts() []any {
	var got []any
	for _, spec := range h.specs {
		got = append(got, spec["owner_account"])
	}
	return got
}

const (
	missingFrame = "{\"type\":\"identity_missing\"}\n"
	oldRefusal   = oldRemoteListenRefusal + "\n"
)

func readyLine(pid int, account string) string {
	line := `{"type":"ready","pid":` + strconv.Itoa(pid) + `,"start":"777","name":"reply","peer":"peer","drain":1`
	if account != "" {
		line += `,"account":"` + account + `"`
	}
	return line + "}\n"
}

// runScripted runs one listen call until its last scripted listener has run.
// A host from an earlier call keeps its jobs, as a remote daemon does across a
// local relayd restart.
func runScripted(t *testing.T, h *scriptedHost, home, path string, c Config, scripts []listenerScript) *scriptedHost {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if h == nil {
		h = &scriptedHost{t: t, jobs: map[string]listenerScript{}}
	}
	h.scripts, h.specs = scripts, nil
	waits := 0
	h.onExec = func(n int) {
		if n == len(scripts)-1 {
			cancel()
		}
	}
	r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { return h }, wait: func(ctx context.Context, _ time.Duration) error {
		if waits++; waits > 4*len(scripts) {
			t.Errorf("listen made no progress: %d execs after %d reconnects", len(h.specs), waits)
			cancel()
		}
		return ctx.Err()
	}}
	_ = r.listen(ctx, c, path)
	return h
}

// The owner exits after the remote's ready frame has carried its account, so
// later listeners report identity_missing and send no ready frame. They must
// keep carrying the recorded account, or a resumed owner can never be found.
func TestRecordedAccountSurvivesAttemptsWithoutReady(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := configFixture()
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	replacement := "{\"type\":\"identity_replacement\",\"session\":\"session-a\",\"pid\":900,\"start\":\"901\",\"name\":\"peer\"}\n"
	h := runScripted(t, nil, home, path, c, []listenerScript{
		{out: readyLine(4321, acct)},
		{out: missingFrame},
		{out: missingFrame},
		{out: missingFrame},
		{out: replacement},
		{out: readyLine(4322, acct)},
	})
	got := h.accounts()
	if len(got) != 6 || got[0] != nil {
		t.Fatalf("listener accounts = %v", got)
	}
	for i := 1; i < len(got); i++ {
		if got[i] != acct {
			t.Fatalf("attempt %d withheld the recorded account: %v", i, got)
		}
	}
	after, e := readConfig(path)
	if e != nil || after.RemotePID != 900 || after.RemoteStart != "901" || after.RemoteAccount != acct || !after.RemoteAccountAccepted {
		t.Fatalf("replacement not adopted with recorded account: %+v %v", after, e)
	}
	if h.specs[5]["owner_pid"] != 900 {
		t.Fatalf("listener after replacement names %v", h.specs[5]["owner_pid"])
	}
}

// Acceptance is on the route, so a new listen call, as after a relayd restart,
// sends the recorded account on its first listener.
func TestRecordedAccountAcceptancePersistsAcrossListen(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := configFixture()
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	h := runScripted(t, nil, home, path, c, []listenerScript{{out: readyLine(4321, acct)}, {out: missingFrame}})
	stored, e := readConfig(path)
	if e != nil || !stored.RemoteAccountAccepted || stored.RemoteAccount != acct {
		t.Fatalf("acceptance not recorded: %+v %v", stored, e)
	}
	h = runScripted(t, h, home, path, stored, []listenerScript{{out: missingFrame}})
	if got := h.accounts(); len(got) != 1 || got[0] != acct {
		t.Fatalf("restarted listen withheld the account: %v", got)
	}
}

// Only an explicit refusal by an older remote relayd withdraws acceptance, and
// the next listener has the base argument count that remote accepts.
func TestOldRemoteRefusalWithholdsAccount(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := configFixture()
	c.RemoteAccount = acct
	c.RemoteAccountAccepted = true
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	h := runScripted(t, nil, home, path, c, []listenerScript{{err: oldRefusal}, {out: readyLine(4321, "")}})
	got := h.accounts()
	if len(got) != 2 || got[0] != acct || got[1] != nil {
		t.Fatalf("listener accounts after refusal = %v", got)
	}
	after, e := readConfig(path)
	if e != nil || after.RemoteAccountAccepted || after.RemoteAccount != acct {
		t.Fatalf("refusal did not withdraw acceptance only: %+v %v", after, e)
	}
	// Any other ending, such as a listener that exits without a diagnostic,
	// keeps acceptance.
	c2 := after
	c2.RemoteAccountAccepted = true
	if e := atomicJSON(path, c2); e != nil {
		t.Fatal(e)
	}
	h = runScripted(t, h, home, path, c2, []listenerScript{{err: "relayd: listener failed\n"}, {out: missingFrame}})
	if got := h.accounts(); len(got) != 2 || got[0] != acct || got[1] != acct {
		t.Fatalf("unrelated failure withdrew acceptance: %v", got)
	}
}
