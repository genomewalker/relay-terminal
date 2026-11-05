package desktoproute

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestVerifySelectedWorkExactIdentity(t *testing.T) {
	for _, scenario := range []string{"match", "wrong-expected-owner", "wrong-expected-incarnation", "changed-live-owner", "changed-process-after-owner", "changed-reference-during-owner"} {
		t.Run(scenario, func(t *testing.T) {
			home := privateTemp(t)
			var inspections atomic.Int32
			d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
				if pid != os.Getpid() {
					return processInfo{}, errors.New("wrong pid")
				}
				n := inspections.Add(1)
				start := "Sun Oct 25 01:02:03 2026"
				if scenario == "changed-process-after-owner" && n >= 3 {
					start = "Sun Oct 25 01:02:04 2026"
				}
				return processInfo{WorkStart: start, Executable: workApp}, nil
			}}
			listener := unixFixture(t, d.workSocket())
			owner := "11111111-1111-1111-1111-111111111111"
			other := "22222222-2222-2222-2222-222222222222"
			ref := workReference{1, "task", "local", d.workSocket(), workApp, os.Getpid(), "Sun Oct 25 01:02:03 2026", owner}
			if err := d.commitWork(ref, nil); err != nil {
				t.Fatal(err)
			}
			inspections.Store(0)
			actual := SelectedWorkIdentity{Thread: ref.Thread, Owner: ref.Owner, PID: ref.PID, Start: ref.Start}
			expectedOwner, inc := owner, actual.Incarnation()
			if scenario == "wrong-expected-owner" {
				expectedOwner = other
			}
			if scenario == "wrong-expected-incarnation" {
				inc += "x"
			}
			connected := scenario != "wrong-expected-owner" && scenario != "wrong-expected-incarnation"
			done := make(chan struct{})
			if connected {
				go func() {
					defer close(done)
					conn, err := listener.AcceptUnix()
					if err != nil {
						return
					}
					defer conn.Close()
					conn.SetDeadline(time.Now().Add(3 * time.Second))
					for {
						req, err := readRequest(conn)
						if err != nil {
							return
						}
						method := req["method"].(string)
						reply := map[string]any{"type": "response", "requestId": req["requestId"], "method": method, "resultType": "success"}
						switch method {
						case "initialize":
							reply["result"] = map[string]string{"clientId": "33333333-3333-3333-3333-333333333333"}
						case "thread-owner-discovery":
							if scenario == "changed-reference-during-owner" {
								changed := ref
								changed.Owner = other
								if err := d.commitWork(changed, &ref); err != nil {
									t.Error(err)
									return
								}
							}
							who := owner
							if scenario == "changed-live-owner" {
								who = other
							}
							reply["handledByClientId"] = who
							reply["result"] = map[string]bool{"supportsUntrustedAppInput": true}
						default:
							t.Errorf("unexpected method %s", method)
							return
						}
						if writeWorkResponse(conn, reply) != nil {
							return
						}
					}
				}()
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			err := d.verifySelectedWork(ctx, "task", expectedOwner, inc)
			if connected {
				<-done
			}
			if (scenario == "match") != (err == nil) {
				t.Fatal("unexpected result", err)
			}
			if (scenario == "wrong-expected-owner" || scenario == "wrong-expected-incarnation") && (err == nil || err.Error() != "selected Work identity changed") {
				t.Fatal("identity mismatch was not rejected before IPC", err)
			}
		})
	}
}

func TestInspectSelectedWorkExactIdentity(t *testing.T) {
	home := privateTemp(t)
	const start = "Sun Oct 25 01:02:03 2026"
	const owner = "11111111-1111-1111-1111-111111111111"
	d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
		if pid != os.Getpid() {
			return processInfo{}, errors.New("wrong pid")
		}
		return processInfo{WorkStart: start, Executable: workApp}, nil
	}}
	listener := unixFixture(t, d.workSocket())
	listener.SetDeadline(time.Now().Add(5 * time.Second))
	done := make(chan struct{})
	go func() {
		defer close(done)
		probe, err := listener.AcceptUnix()
		if err != nil {
			return
		}
		_, _ = io.Copy(io.Discard, probe)
		probe.Close()
		conn, err := listener.AcceptUnix()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		for {
			req, err := readRequest(conn)
			if err != nil {
				return
			}
			method := req["method"].(string)
			reply := map[string]any{"type": "response", "requestId": req["requestId"], "method": method, "resultType": "success"}
			switch method {
			case "initialize":
				reply["result"] = map[string]string{"clientId": "33333333-3333-3333-3333-333333333333"}
			case "thread-owner-discovery":
				reply["handledByClientId"] = owner
				reply["result"] = map[string]bool{"supportsUntrustedAppInput": true}
			default:
				t.Errorf("unexpected method %s", method)
				return
			}
			if writeWorkResponse(conn, reply) != nil {
				return
			}
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	got, err := d.inspectSelectedWork(ctx, "task")
	<-done
	want := SelectedWorkIdentity{Thread: "task", Owner: owner, PID: os.Getpid(), Start: start}
	if err != nil || got != want {
		t.Fatal(got, err)
	}
}

func TestPersistSelectedWorkNoSilentRebind(t *testing.T) {
	home := privateTemp(t)
	start := "Sun Oct 25 01:02:03 2026"
	d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
		if pid != os.Getpid() {
			return processInfo{}, errors.New("bad pid")
		}
		return processInfo{WorkStart: start, Executable: workApp}, nil
	}}
	r := workReference{1, "task", "local", d.workSocket(), workApp, os.Getpid(), start, "11111111-1111-1111-1111-111111111111"}
	if err := d.persistSelectedWork(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	if err := d.persistSelectedWork(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	changed := r
	changed.Owner = "22222222-2222-2222-2222-222222222222"
	if err := d.persistSelectedWork(context.Background(), changed); err == nil {
		t.Fatal("silently accepted rebind")
	}
	saved, err := d.readWork(filepath.Join(d.workRoot(), "task.json"))
	if err != nil || saved == nil || *saved != r {
		t.Fatal(saved, err)
	}
	start = "Sun Oct 25 01:02:04 2026"
	if err := d.persistSelectedWork(context.Background(), r); err == nil {
		t.Fatal("accepted stale process")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := d.persistSelectedWork(ctx, r); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
