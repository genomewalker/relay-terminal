package desktoproute

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestDeliverSelectedWorkExactTarget(t *testing.T) {
	for _, scenario := range []string{"admitted", "wrong-owner", "wrong-incarnation", "live-owner-changed", "reference-changed", "process-changed", "guard-denied", "lost-reply", "registry-busy", "cancelled"} {
		t.Run(scenario, func(t *testing.T) {
			home := privateTemp(t)
			var inspections atomic.Int32
			d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
				if pid != os.Getpid() {
					return processInfo{}, errors.New("bad pid")
				}
				start := "Sun Oct 25 01:02:03 2026"
				if scenario == "process-changed" && inspections.Add(1) >= 3 {
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
			var held *os.File
			if scenario == "registry-busy" {
				var err error
				held, err = fileLock(filepath.Join(d.workRoot(), ".registry.lock"), false)
				if err != nil {
					t.Fatal(err)
				}
				defer held.Close()
			}
			expectedOwner := owner
			inc := (SelectedWorkIdentity{PID: ref.PID, Start: ref.Start}).Incarnation()
			if scenario == "wrong-owner" {
				expectedOwner = other
			}
			if scenario == "wrong-incarnation" {
				inc += "x"
			}
			connected := scenario == "admitted" || scenario == "live-owner-changed" || scenario == "reference-changed" || scenario == "process-changed" || scenario == "guard-denied" || scenario == "lost-reply"
			done := make(chan struct{})
			var starts atomic.Int32
			var ownerObserved atomic.Bool
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
							if scenario == "reference-changed" {
								changed := ref
								changed.Owner = other
								if err := atomicJSON(filepath.Join(d.workRoot(), "task.json"), changed); err != nil {
									t.Error(err)
									return
								}
							}
							who := owner
							if scenario == "live-owner-changed" {
								who = other
							}
							reply["handledByClientId"] = who
							reply["result"] = map[string]bool{"supportsUntrustedAppInput": true}
							ownerObserved.Store(true)
						case "thread-follower-start-turn":
							if lock, err := fileLock(filepath.Join(d.workRoot(), ".registry.lock"), true); err == nil {
								lock.Close()
								t.Error("registry unlocked at dispatch")
							}
							starts.Add(1)
							if req["targetClientId"] != owner || req["version"] != json.Number("2") {
								t.Error("wrong target")
							}
							params := req["params"].(map[string]any)
							if params["conversationId"] != "task" {
								t.Error("wrong conversation")
							}
							turn := params["turnStart"].(map[string]any)
							request := turn["request"].(map[string]any)
							tool := request["toolOutput"].(map[string]any)
							var message map[string]string
							if err := json.Unmarshal([]byte(tool["output"].(string)), &message); err != nil || message["id"] != "req" || message["sender"] != "node/pane" || message["content"] != "hello" {
								t.Error("wrong message", message, err)
							}
							if scenario == "lost-reply" {
								return
							}
							reply["handledByClientId"] = owner
							reply["result"] = map[string]any{}
						default:
							t.Error("unexpected method", method)
							return
						}
						if writeWorkResponse(conn, reply) != nil {
							return
						}
					}
				}()
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			if scenario == "cancelled" {
				cancel()
			} else {
				defer cancel()
			}
			guard := func(context.Context) error {
				if scenario == "guard-denied" && ownerObserved.Load() {
					return errors.New("expired during owner handshake")
				}
				return nil
			}
			result := d.deliverSelectedWork(ctx, "task", expectedOwner, inc, Envelope{ID: "req", Sender: "node/pane", Content: "hello"}, guard)
			if connected {
				<-done
			}
			want := "not_sent"
			expectedStarts := int32(0)
			if scenario == "admitted" {
				want = "admitted"
				expectedStarts = 1
			}
			if scenario == "lost-reply" {
				want = "unknown"
				expectedStarts = 1
			}
			if scenario == "guard-denied" {
				want = "unknown"
			}
			if result.Receipt != want || starts.Load() != expectedStarts {
				t.Fatal(result, starts.Load())
			}
			if (scenario == "wrong-owner" || scenario == "wrong-incarnation") && result.Error != "selected Work identity changed" {
				t.Fatal("wrong pre-IPC rejection", result)
			}
			if scenario == "registry-busy" && result.Error != "Work registry unavailable" {
				t.Fatal("registry not fenced", result)
			}
		})
	}
}

func TestDeliverSelectedWorkRejectsInvalidText(t *testing.T) {
	d := &nativeDesktop{home: privateTemp(t), inspect: inspectProcess}
	result := d.deliverSelectedWork(context.Background(), "task", "owner", "inc", Envelope{ID: "req", Sender: "sender", Content: string([]byte{0xff})}, func(context.Context) error { return nil })
	if result.Receipt != "not_sent" || result.Error != "invalid Work text" {
		t.Fatal(result)
	}
}

func TestDeliverSelectedWorkRejectsMissingGuard(t *testing.T) {
	d := &nativeDesktop{home: privateTemp(t), inspect: inspectProcess}
	result := d.deliverSelectedWork(context.Background(), "task", "owner", "inc", Envelope{ID: "req", Sender: "sender", Content: "hello"}, nil)
	if result.Receipt != "not_sent" || result.Error != "admission guard unavailable" {
		t.Fatal(result)
	}
}

type guardSerializationProbe struct{ serialized *atomic.Bool }

func (p guardSerializationProbe) MarshalJSON() ([]byte, error) {
	p.serialized.Store(true)
	return []byte(`{"type":"request"}`), nil
}
func TestWorkGuardRunsAfterSerializationBeforeWrite(t *testing.T) {
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	listener := unixFixture(t, d.workSocket())
	_ = listener
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := dialSocket(ctx, d.workSocket())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	c := workClient{conn: conn}
	var serialized atomic.Bool
	sentinel := errors.New("expired while serializing")
	err = c.sendGuarded(guardSerializationProbe{serialized: &serialized}, func() error {
		if serialized.Load() {
			return sentinel
		}
		return nil
	})
	if !errors.Is(err, sentinel) {
		t.Fatal("guard was not after serialization", err)
	}
}
