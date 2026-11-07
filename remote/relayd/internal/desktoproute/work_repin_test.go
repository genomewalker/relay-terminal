package desktoproute

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// After the Codex app restarts, every saved Work endpoint pins the old process,
// so discovery reported saved_work_unverified and every Codex chat lost Relay
// until a route was recreated by hand (live on 2026-11-07: ChatGPT 25704 ->
// 34056). Discovery now re-pins a saved thread when the new incarnation passes
// the same checks a first registration needs, and never otherwise.
func TestDiscoveryRepinsAThreadAfterTheWorkAppRestarted(t *testing.T) {
	const oldStart, newStart = "Fri Nov  6 07:29:57 2026", "Sat Nov  7 22:48:20 2026"
	oldOwner, newOwner := "11111111-1111-1111-1111-111111111111", "44444444-4444-4444-4444-444444444444"
	for _, scenario := range []string{"restarted", "older-start", "other-executable", "no-untrusted-input"} {
		t.Run(scenario, func(t *testing.T) {
			home := privateTemp(t)
			start, executable := newStart, workApp
			switch scenario {
			case "older-start":
				start = "Thu Nov  5 01:00:00 2026"
			case "other-executable":
				executable = "/Applications/Other.app/Contents/MacOS/Other"
			}
			d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
				if pid != os.Getpid() {
					return processInfo{}, errors.New("wrong PID")
				}
				return processInfo{WorkStart: start, Executable: executable}, nil
			}}
			listener := unixFixture(t, d.workSocket())
			stale := workReference{1, "task", "local", d.workSocket(), workApp, os.Getpid(), oldStart, oldOwner}
			// Seed the stale record directly: commitWork checks the live process.
			if e := privateDirectory(d.workRoot(), true); e != nil {
				t.Fatal(e)
			}
			if e := exclusiveJSON(filepath.Join(d.workRoot(), "task.json"), stale); e != nil {
				t.Fatal(e)
			}
			go func() {
				for {
					conn, e := listener.AcceptUnix()
					if e != nil {
						return
					}
					go func() {
						defer conn.Close()
						conn.SetDeadline(time.Now().Add(3 * time.Second))
						for {
							req, e := readRequest(conn)
							if e != nil {
								return
							}
							method := req["method"].(string)
							reply := map[string]any{"type": "response", "requestId": req["requestId"], "method": method, "resultType": "success"}
							switch method {
							case "initialize":
								reply["result"] = map[string]string{"clientId": "33333333-3333-3333-3333-333333333333"}
							case "thread-owner-discovery":
								reply["handledByClientId"] = newOwner
								reply["result"] = map[string]bool{"supportsUntrustedAppInput": scenario != "no-untrusted-input"}
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
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			rows, err := d.Tasks(ctx, d.legacySocket())
			saved, readErr := d.readWork(filepath.Join(d.workRoot(), "task.json"))
			if readErr != nil || saved == nil {
				t.Fatal("saved Work record unreadable", readErr)
			}
			if scenario == "restarted" {
				if err != nil || len(rows) != 1 || rows[0].ID != "task" {
					t.Fatal("restarted Work app not rediscovered", rows, err)
				}
				if saved.Start != newStart || saved.Owner != newOwner || saved.Thread != "task" || saved.AppPath != workApp {
					t.Fatal("re-pin did not record the new incarnation", *saved)
				}
				return
			}
			if err == nil && len(rows) > 0 {
				t.Fatal("unverified incarnation was rediscovered", scenario, rows)
			}
			if *saved != stale {
				t.Fatal("stale record was rewritten", scenario, *saved)
			}
		})
	}
}
