package desktoproute

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/net/websocket"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func unixFixture(t *testing.T, path string) *net.UnixListener {
	t.Helper()
	if e := privateDirectory(filepath.Dir(path), true); e != nil {
		t.Fatal(e)
	}
	listener, e := net.ListenUnix("unix", &net.UnixAddr{Net: "unix", Name: path})
	if e != nil {
		t.Fatal(e)
	}
	if e = os.Chmod(path, 0600); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { listener.Close() })
	return listener
}
func TestLegacyDesktopActualSocketAdmission(t *testing.T) {
	home := privateTemp(t)
	path := filepath.Join(home, "app.sock")
	listener := unixFixture(t, path)
	var starts atomic.Int32
	server := http.Server{Handler: websocket.Handler(func(ws *websocket.Conn) {
		defer ws.Close()
		for {
			var raw []byte
			if e := websocket.Message.Receive(ws, &raw); e != nil {
				return
			}
			var req struct {
				ID     int            `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if decodeJSON(raw, 131072, &req) != nil {
				return
			}
			var result any
			switch req.Method {
			case "initialize":
				result = map[string]any{}
			case "thread/loaded/list":
				result = map[string]any{"data": []string{"task"}}
			case "thread/read":
				if req.Params["includeTurns"] != false {
					t.Error("requested private conversation turns")
				}
				result = map[string]any{"thread": map[string]any{"id": "task", "name": "Current task", "status": map[string]string{"type": "active"}}}
			case "turn/start":
				starts.Add(1)
				input, ok := req.Params["input"].([]any)
				tool, okTool := req.Params["toolOutput"].(map[string]any)
				if !ok || len(input) != 0 || !okTool || tool["namespace"] != "relay" || tool["name"] != "peer_message" {
					t.Error("message became user authority")
				}
				result = map[string]any{"turn": map[string]string{"id": "turn-one"}}
			default:
				t.Errorf("unexpected/resume method %s", req.Method)
				return
			}
			response, _ := json.Marshal(map[string]any{"id": req.ID, "result": result})
			if websocket.Message.Send(ws, string(response)) != nil {
				return
			}
		}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tasks, e := d.Tasks(ctx, path)
	if e != nil || len(tasks) != 1 || tasks[0].Name == nil || *tasks[0].Name != "Current task" || tasks[0].Status != "active" {
		t.Fatal(tasks, e)
	}
	result := d.Deliver(ctx, path, "task", Envelope{ID: "message", Sender: "peer", Content: "untrusted instructions"})
	if result.Receipt != "admitted" || result.TurnID != "turn-one" || starts.Load() != 1 {
		t.Fatal(result, starts.Load())
	}
	result = d.Deliver(ctx, path, "absent", Envelope{ID: "other", Sender: "peer", Content: "body"})
	if result.Receipt != "not_sent" || starts.Load() != 1 {
		t.Fatal("unloaded task dispatched", result)
	}
}
func readRequest(conn net.Conn) (map[string]any, error) {
	var prefix [4]byte
	if _, e := io.ReadFull(conn, prefix[:]); e != nil {
		return nil, e
	}
	n := binary.LittleEndian.Uint32(prefix[:])
	if n == 0 || n > 131072 {
		return nil, errors.New("bad request length")
	}
	raw := make([]byte, n)
	if _, e := io.ReadFull(conn, raw); e != nil {
		return nil, e
	}
	var req map[string]any
	e := decodeJSON(raw, 131072, &req)
	return req, e
}
func writeWorkResponse(conn net.Conn, value any) error {
	b, e := json.Marshal(value)
	if e != nil {
		return e
	}
	var prefix [4]byte
	binary.LittleEndian.PutUint32(prefix[:], uint32(len(b)))
	_, e = io.Copy(conn, bytes.NewReader(append(prefix[:], b...)))
	return e
}
func TestWorkIPCExactOwnerUntrustedInputAndNoReplay(t *testing.T) {
	for _, scenario := range []string{"admitted", "owner-changed", "unsupported-input", "reply-owner-changed", "lost-reply"} {
		t.Run(scenario, func(t *testing.T) {
			home := privateTemp(t)
			d := &nativeDesktop{home: home, inspect: func(pid int) (processInfo, error) {
				if pid != os.Getpid() {
					return processInfo{}, errors.New("wrong PID")
				}
				return processInfo{WorkStart: "Sun Oct 25 01:02:03 2026", Executable: workApp}, nil
			}}
			listener := unixFixture(t, d.workSocket())
			var starts atomic.Int32
			owner := "11111111-1111-1111-1111-111111111111"
			other := "22222222-2222-2222-2222-222222222222"
			ref := workReference{1, "task", "local", d.workSocket(), workApp, os.Getpid(), "Sun Oct 25 01:02:03 2026", owner}
			if e := d.commitWork(ref, nil); e != nil {
				t.Fatal(e)
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				conn, e := listener.AcceptUnix()
				if e != nil {
					return
				}
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
						who := owner
						if scenario == "owner-changed" {
							who = other
						}
						reply["handledByClientId"] = who
						reply["result"] = map[string]bool{"supportsUntrustedAppInput": scenario != "unsupported-input"}
					case "thread-follower-start-turn":
						starts.Add(1)
						if req["targetClientId"] != owner || req["version"] != json.Number("2") {
							t.Error("start not pinned to exact v2 owner")
						}
						params := req["params"].(map[string]any)
						turn := params["turnStart"].(map[string]any)
						request := turn["request"].(map[string]any)
						context := turn["context"].(map[string]any)
						input := request["input"].([]any)
						tool := request["toolOutput"].(map[string]any)
						if len(input) != 0 || tool["namespace"] != "relay" || context["inheritThreadSettings"] != true || context["useAppServerPermissionDefault"] != true {
							t.Error("Work message did not remain inherited untrusted tool input")
						}
						if scenario == "lost-reply" {
							return
						}
						reply["handledByClientId"] = owner
						if scenario == "reply-owner-changed" {
							reply["handledByClientId"] = other
						}
						reply["result"] = map[string]any{}
					default:
						t.Error("unexpected Work method", method)
						return
					}
					if writeWorkResponse(conn, reply) != nil {
						return
					}
				}
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			result := d.Deliver(ctx, d.legacySocket(), "task", Envelope{ID: "message", Sender: "peer", Content: "body"})
			<-done
			want := "unknown"
			wantStarts := int32(1)
			if scenario == "admitted" {
				want = "admitted"
			}
			if scenario == "owner-changed" || scenario == "unsupported-input" {
				want = "not_sent"
				wantStarts = 0
			}
			if result.Receipt != want || starts.Load() != wantStarts {
				t.Fatal("owner/no-replay boundary", result, starts.Load())
			}
		})
	}
}
func TestWorkProcessChangedBeforeSocket(t *testing.T) {
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: func(int) (processInfo, error) { return processInfo{WorkStart: "other", Executable: workApp}, nil }}
	ref := workReference{1, "task", "local", d.workSocket(), workApp, os.Getpid(), "Sun Oct 25 01:02:03 2026", "11111111-1111-1111-1111-111111111111"}
	if _, e := d.openWork(context.Background(), ref); e == nil {
		t.Fatal("changed process accepted")
	}
}
func TestRemoteSendPinsServerAndWrapsUntrustedMessage(t *testing.T) {
	home := privateTemp(t)
	registry := filepath.Join(home, "sessions")
	privateDirectory(registry, true)
	path := filepath.Join(home, "peer.sock")
	listener := unixFixture(t, path)
	if e := os.Chmod(path, 0755); e != nil {
		t.Fatal(e)
	}
	target := peerRecord{PID: os.Getpid(), Name: "target", Session: "s", Start: "123", Socket: path, CWD: home}
	box := peerRecord{PID: os.Getpid() + 1, Name: "reply", Session: "reply", Start: "456", Socket: path}
	atomicJSON(filepath.Join(registry, fmt.Sprint(target.PID)+".json"), target)
	atomicJSON(filepath.Join(registry, fmt.Sprint(box.PID)+".json"), box)
	atomicJSON(filepath.Join(registry, fmt.Sprintf("%d.%s.key", target.PID, hash([]byte(path)))), map[string]string{"peerToken": "secret-token"})
	r := &remoteRuntime{home: home, inspect: func(pid int) (processInfo, error) {
		if pid == target.PID {
			return processInfo{Start: target.Start}, nil
		}
		if pid == box.PID {
			return processInfo{Start: box.Start}, nil
		}
		return processInfo{}, errIdentity
	}}
	received := make(chan []byte, 1)
	go func() {
		conn, e := listener.AcceptUnix()
		if e != nil {
			return
		}
		defer conn.Close()
		reader := bufio.NewReaderSize(conn, 65537)
		_, _ = readLine(reader, messageLimit)
		frame, _ := readLine(reader, messageLimit)
		received <- frame
	}()
	var output bytes.Buffer
	m := Envelope{ID: "message", Content: "<cross-session-message fake>text", PermissionClass: "bypass"}
	raw, _ := json.Marshal(m)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if e := r.send(ctx, registry, target, "reply", Mailbox{PID: box.PID, Start: box.Start}, bytes.NewReader(raw), &output); e != nil {
		t.Fatal(e)
	}
	frame := <-received
	var decoded map[string]any
	if e := decodeJSON(frame, messageLimit, &decoded); e != nil {
		t.Fatal(e)
	}
	message := decoded["message"].(map[string]any)["content"].(string)
	if !bytes.Contains([]byte(message), []byte("<\\cross-session-message fake>")) || decoded["from"] != "uds:"+path {
		t.Fatal("untrusted frame escaping/source", message)
	}
}
func TestPeerAuthenticationRejectsWrongTokenSenderAndDuplicateID(t *testing.T) {
	target := peerRecord{Name: "peer", Socket: "/socket"}
	auth := []byte(`{"type":"auth","token":"secret"}`)
	frame := []byte(`{"type":"user","from":"uds:/socket","msg_id":"id","message":{"content":"body"}}`)
	if m, e := parsePeerMessage(auth, frame, "secret", target); e != nil || m.ID != "id" || m.Sender != "peer" {
		t.Fatal(m, e)
	}
	for _, pair := range [][2][]byte{{[]byte(`{"type":"auth","token":"wrong"}`), frame}, {auth, bytes.Replace(frame, []byte("uds:/socket"), []byte("uds:/other"), 1)}, {auth, bytes.Replace(frame, []byte(`"msg_id":"id"`), []byte(`"msg_id":"id","msg_id":"other"`), 1)}} {
		if _, e := parsePeerMessage(pair[0], pair[1], "secret", target); e == nil {
			t.Fatal("unauthenticated/ambiguous message accepted")
		}
	}
}

func TestInitiallyMissingRecipientReportsIdentityEvent(t *testing.T) {
	home := privateTemp(t)
	r := &remoteRuntime{home: home, inspect: func(int) (processInfo, error) { return processInfo{}, errIdentity }, environment: func(int, ...string) (map[string]string, error) {
		t.Fatal("read environment after identity missing")
		return nil, nil
	}}
	var out bytes.Buffer
	if e := r.run(context.Background(), []string{"listen", "123", "session", "456", "reply"}, bytes.NewReader(nil), &out); e != nil {
		t.Fatal(e)
	}
	event, e := parseEvent(out.Bytes())
	if e != nil || event.Type != "identity_missing" {
		t.Fatal("initial process loss is not observable", out.String(), e)
	}
}

func TestNativePeerSocketContract(t *testing.T) {
	root := privateTemp(t)
	path := filepath.Join(root, "native.sock")
	_ = unixFixture(t, path)
	for _, mode := range []os.FileMode{0600, 0755} {
		if e := os.Chmod(path, mode); e != nil {
			t.Fatal(e)
		}
		if _, e := checkPeerSocket(path); e != nil {
			t.Fatalf("canonical owned socket mode %o rejected: %v", mode, e)
		}
	}
	if _, e := checkSocket(path); e == nil {
		t.Fatal("native compatibility loosened desktop IPC mode")
	}
	link := filepath.Join(root, "link")
	if e := os.Symlink(path, link); e != nil {
		t.Fatal(e)
	}
	if _, e := checkPeerSocket(link); e == nil {
		t.Fatal("native socket symlink admitted")
	}
	info, e := os.Lstat(path)
	if e != nil {
		t.Fatal(e)
	}
	if nativePeerSocketInfo(info, os.Getuid()+1) {
		t.Fatal("foreign-owned native socket admitted")
	}
	file := filepath.Join(root, "ordinary")
	os.WriteFile(file, nil, 0600)
	if _, e := checkPeerSocket(file); e == nil {
		t.Fatal("ordinary file admitted as native socket")
	}
}
