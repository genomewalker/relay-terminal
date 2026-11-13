package desktoproute

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// relay_list_desktop_tasks returned 503 on 2026-11-13: four saved Work threads
// from an earlier Codex app run were checked one after another, the app answered
// owner discovery for each unloaded thread only at its own 12 s timeout, and the
// listing took ~41 s against the app's 20 s limit. Stale saved threads must not
// hide a live one or push the listing past that limit.
func TestListingIsNotHeldUpBySavedThreadsTheWorkAppNeverAnswers(t *testing.T) {
	const oldStart, newStart = "Fri Nov  6 07:29:57 2026", "Sat Nov  7 22:48:20 2026"
	liveOwner := "44444444-4444-4444-4444-444444444444"
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
		if pid != os.Getpid() {
			return processInfo{}, errors.New("wrong PID")
		}
		return processInfo{WorkStart: newStart, Executable: workApp}, nil
	}}
	listener := unixFixture(t, d.workSocket())
	if e := privateDirectory(d.workRoot(), true); e != nil {
		t.Fatal(e)
	}
	stale := []string{"stale-a", "stale-b", "stale-c", "stale-d"}
	for _, thread := range stale {
		r := workReference{1, thread, "local", d.workSocket(), workApp, os.Getpid(), oldStart, "11111111-1111-1111-1111-111111111111"}
		if e := exclusiveJSON(filepath.Join(d.workRoot(), thread+".json"), r); e != nil {
			t.Fatal(e)
		}
	}
	live := workReference{1, "live", "local", d.workSocket(), workApp, os.Getpid(), newStart, liveOwner}
	if e := exclusiveJSON(filepath.Join(d.workRoot(), "live.json"), live); e != nil {
		t.Fatal(e)
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			conn, e := listener.AcceptUnix()
			if e != nil {
				return
			}
			go func() {
				defer conn.Close()
				for {
					req, e := readRequest(conn)
					if e != nil {
						return
					}
					method, _ := req["method"].(string)
					reply := map[string]any{"type": "response", "requestId": req["requestId"], "method": method, "resultType": "success"}
					switch method {
					case "initialize":
						reply["result"] = map[string]string{"clientId": "33333333-3333-3333-3333-333333333333"}
					case "thread-owner-discovery":
						params, _ := req["params"].(map[string]any)
						if params["conversationId"] != "live" {
							// Like the app for an unloaded thread: no answer
							// within any listing budget.
							select {
							case <-done:
							case <-time.After(30 * time.Second):
							}
							return
						}
						reply["handledByClientId"] = liveOwner
						reply["result"] = map[string]bool{"supportsUntrustedAppInput": true}
					default:
						t.Error("unexpected Work method", method)
						return
					}
					if writeWorkResponse(conn, reply) != nil {
						return
					}
				}
			}()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	began := time.Now()
	rows, err := d.Tasks(ctx, d.legacySocket())
	took := time.Since(began)
	if err != nil || len(rows) != 1 || rows[0].ID != "live" {
		t.Fatal("live saved thread not listed", rows, err)
	}
	if limit := 3 * workProbeTimeout; took > limit {
		t.Fatalf("listing took %v with unanswered saved threads; limit %v (app gives up at 20 s)", took, limit)
	}
	for _, thread := range stale {
		saved, e := d.readWork(filepath.Join(d.workRoot(), thread+".json"))
		if e != nil || saved == nil || saved.Start != oldStart {
			t.Fatal("unanswered saved thread was rewritten", thread, saved, e)
		}
	}
}
