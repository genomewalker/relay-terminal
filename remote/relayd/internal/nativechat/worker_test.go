package nativechat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNativeFixtureProcess(t *testing.T) {
	if os.Getenv("RELAY_NATIVE_FIXTURE") != "codex" {
		return
	}
	// This disposable fixture exits itself. No process or group signals are used.
	defer os.Exit(0)
	lines := make(chan []byte)
	go func() {
		s := bufio.NewScanner(os.Stdin)
		for s.Scan() {
			lines <- append([]byte(nil), s.Bytes()...)
		}
		close(lines)
	}()
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	emit := func(v any) { fmt.Println(string(wire(v))) }
	turn := 0
	for {
		select {
		case <-timer.C:
			return
		case raw, ok := <-lines:
			if !ok {
				return
			}
			m := obj(raw)
			id := m["id"]
			method := str(m["method"])
			params := obj(m["params"])
			switch method {
			case "initialize":
				emit(map[string]any{"id": id, "result": map[string]any{}})
			case "thread/start":
				emit(map[string]any{"id": id, "result": map[string]any{"thread": map[string]any{"id": "session", "turns": []any{}}}})
			case "turn/start":
				text := ""
				for _, input := range array(params["input"]) {
					text += str(obj(input)["text"])
				}
				if text == "fixture-exit" {
					return
				}
				f, e := os.OpenFile(os.Getenv("RELAY_NATIVE_COUNT"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
				if e != nil {
					os.Exit(3)
				}
				_, _ = f.WriteString(text + "\n")
				_ = f.Close()
				turn++
				tid := fmt.Sprintf("turn-%d", turn)
				emit(map[string]any{"id": id, "result": map[string]any{"turn": map[string]any{"id": tid}}})
				emit(map[string]any{"method": "item/completed", "params": map[string]any{"threadId": "session", "turnId": tid, "item": map[string]any{"type": "agentMessage", "id": tid + "-message", "text": "reply:" + text}}})
				emit(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "session", "turn": map[string]any{"id": tid, "status": "completed"}}})
			}
		}
	}
}
func TestWorkerRoundtripReceiptAndOfflineHistory(t *testing.T) {
	root := t.TempDir()
	id := Identity{stableID("pane", root), stableID("instance", root), "codex"}
	var alive atomic.Bool
	alive.Store(true)
	// The fixture tests real pipes/files/sockets. Kernel observations are injected;
	// platform peer credentials are covered by the daemon's own kernel tests.
	kernel := Kernel{
		ProcessStart: func(pid int) (string, error) {
			if pid == os.Getpid() && !alive.Load() {
				return "", errors.New("fixture worker ended")
			}
			return fmt.Sprint(pid), nil
		},
		PeerCredentials: func(net.Conn) (int, int, error) { return os.Getuid(), os.Getpid(), nil },
	}
	count := filepath.Join(root, "count")
	finished := make(chan error, 1)
	go func() {
		finished <- Serve(context.Background(), RunConfig{
			Identity: id, Provider: ProviderOptions{Provider: "codex", CWD: root},
			Executable: os.Args[0], Arguments: []string{"-test.run=^TestNativeFixtureProcess$"},
			Environment: append(os.Environ(), "RELAY_NATIVE_FIXTURE=codex", "RELAY_NATIVE_COUNT="+count),
			Root:        root, Kernel: kernel,
		})
	}()
	// Discovery is bounded by the fixture's autonomous deadline, and subsequent
	// changes use the production long-poll notification path.
	deadline := time.Now().Add(10 * time.Second)
	var snapshot Snapshot
	for {
		select {
		case startupErr := <-finished:
			t.Fatalf("worker ended before readiness: %v", startupErr)
		default:
		}
		r, e := Call(context.Background(), root, RPCRequest{Operation: "snapshot", Identity: id, AfterRevision: snapshot.Revision, WaitMillis: 1000}, kernel)
		if e == nil && r.Snapshot != nil {
			snapshot = *r.Snapshot
			if snapshot.Capabilities.Send {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("worker readiness: %v", e)
		}
		// Socket creation is the only interval with no worker notification yet.
		if e != nil {
			time.Sleep(10 * time.Millisecond)
		}
	}
	action := Action{ID: "one-action", Identity: id, Kind: "send", Text: "once"}
	r, e := Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &action}, kernel)
	if e != nil || r.Receipt == nil || r.Receipt.State != "sent" {
		t.Fatalf("action %v %+v", e, r)
	}
	first := *r.Receipt
	for i := 0; i < 3; i++ {
		r, e = Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &action}, kernel)
		if e != nil || r.Receipt == nil || *r.Receipt != first {
			t.Fatalf("replay changed receipt %v %+v", e, r)
		}
	}
	for !snapshot.Capabilities.Send || len(snapshot.Items) == 0 {
		r, e = Call(context.Background(), root, RPCRequest{Operation: "snapshot", Identity: id, AfterRevision: snapshot.Revision, WaitMillis: 1000}, kernel)
		if e != nil || r.Snapshot == nil {
			t.Fatalf("snapshot %v", e)
		}
		snapshot = *r.Snapshot
		if time.Now().After(deadline) {
			t.Fatal("reply deadline")
		}
	}
	data, e := os.ReadFile(count)
	if e != nil || string(data) != "once\n" {
		t.Fatalf("provider got duplicate or missing input %q %v", data, e)
	}
	r, e = Call(context.Background(), root, RPCRequest{Operation: "receipt", Identity: id, ReceiptID: action.ID}, kernel)
	if e != nil || r.Receipt == nil || *r.Receipt != first {
		t.Fatal("receipt unavailable after reconnect")
	}
	badKernel := kernel
	badKernel.PeerCredentials = func(net.Conn) (int, int, error) { return os.Getuid(), os.Getpid() + 1, nil }
	if _, e = Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &action}, badKernel); e == nil {
		t.Fatal("wrong kernel peer accepted")
	}
	// Distinct processes can share a start timestamp at the platform's
	// resolution. PID ownership must remain an independent check.
	badKernel.ProcessStart = func(int) (string, error) { return fmt.Sprint(os.Getpid()), nil }
	if _, e = Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &action}, badKernel); e == nil {
		t.Fatal("wrong kernel peer accepted with matching start")
	}
	exitAction := Action{ID: "exit", Identity: id, Kind: "send", Text: "fixture-exit"}
	// Provider may exit before the action reply. It is never retried.
	_, _ = Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &exitAction}, kernel)
	select {
	case e := <-finished:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("fixture did not exit autonomously")
	}
	alive.Store(false)
	r, e = Call(context.Background(), root, RPCRequest{Operation: "snapshot", Identity: id}, kernel)
	if e != nil || r.Snapshot == nil || r.Snapshot.Phase != "exited" || r.Snapshot.Capabilities.Send {
		t.Fatalf("offline history %v %+v", e, r)
	}
	found := false
	for _, item := range r.Snapshot.Items {
		found = found || item.Text == "reply:once"
	}
	if !found {
		t.Fatal("persisted assistant history missing")
	}
	if _, e = Call(context.Background(), root, RPCRequest{Operation: "action", Identity: id, Action: &action}, kernel); e == nil {
		t.Fatal("offline action admitted")
	}
}
func TestLaunchClaimAcrossPanes(t *testing.T) {
	root := t.TempDir()
	const actors = 8
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < actors; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if claimLaunch(root, Identity{fmt.Sprintf("pane-%d", i), "same-launch", "codex"}) == nil {
				accepted.Add(1)
			}
		}(i)
	}
	wg.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("launch effects admitted=%d", accepted.Load())
	}
	if e := claimLaunch(root, Identity{"next-pane", "same-launch", "codex"}); e == nil {
		t.Fatal("durable launch claim replayed")
	}
}
func TestHistoryDeltaRoundTrip(t *testing.T) {
	root := t.TempDir()
	f, e := os.Create(filepath.Join(root, "items.jsonl"))
	if e != nil {
		t.Fatal(e)
	}
	state := readyState(t)
	w := worker{state: state, items: f}
	_ = state.AddItem(Item{ID: "one", Role: "assistant", Text: "hello"}, false)
	if e = w.appendItems(); e != nil {
		t.Fatal(e)
	}
	_ = state.AddItem(Item{ID: "one", Role: "assistant", Text: " world"}, true)
	if e = w.appendItems(); e != nil {
		t.Fatal(e)
	}
	_ = f.Close()
	items, _, e := readHistory(root, 0)
	if e != nil || len(items) != 1 || items[0].Text != "hello world" {
		t.Fatalf("history deltas %v %+v", e, items)
	}
}
func TestImageStorageRejectsEscapesAndChanges(t *testing.T) {
	root := t.TempDir()
	if e := privateDirectory(filepath.Join(root, "images")); e != nil {
		t.Fatal(e)
	}
	png := append([]byte{137, 'P', 'N', 'G', 13, 10, 26, 10}, []byte("fixture")...)
	path, e := storeImage(root, png)
	if e != nil {
		t.Fatal(e)
	}
	w := worker{directory: root}
	if _, e = w.imageBlocks([]string{filepath.Join(root, "..", "outside.png")}); e == nil {
		t.Fatal("foreign image path accepted")
	}
	if e = os.WriteFile(path, append(png, 'x'), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = w.imageBlocks([]string{path}); e == nil {
		t.Fatal("changed digest-named image accepted")
	}
	if _, e = storeImage(root, []byte("not an image")); e == nil {
		t.Fatal("unknown image header accepted")
	}
}
func TestFrameRejectsTruncation(t *testing.T) {
	for _, raw := range []string{`{"a":1}`, strings.Repeat("x", 8192)} {
		if _, e := readFrame(strings.NewReader(raw), 9000); e == nil {
			t.Fatal("unterminated frame accepted")
		}
	}
	b, e := readFrame(strings.NewReader("{}\n"), 4)
	if e != nil || !json.Valid(b) {
		t.Fatal("valid bounded frame rejected")
	}
	if _, e = readFrame(strings.NewReader("12345\n"), 4); e == nil {
		t.Fatal("frame bound ignored")
	}
}

func FuzzReadFrame(f *testing.F) {
	f.Add([]byte("{}\n"))
	f.Add([]byte("{}"))
	f.Add([]byte("x\ntrailing"))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 8192 {
			return
		}
		frame, e := readFrame(bytes.NewReader(data), 4096)
		if e != nil {
			return
		}
		end := bytes.IndexByte(data, 10)
		if end < 0 || end+1 > 4096 || !bytes.Equal(frame, data[:end]) {
			t.Fatal("framer accepted truncation or changed first frame")
		}
	})
}

func TestSnapshotFitsWireBudget(t *testing.T) {
	s := readyState(t)
	for i := 0; i < MaxItems; i++ {
		_ = s.AddItem(Item{ID: fmt.Sprintf("item-%d", i), Role: "assistant", Text: strings.Repeat("\t", MaxItemBytes)}, false)
	}
	s.View.Failure = strings.Repeat("failure ", 1<<18)
	snapshot := boundedSnapshot(s.Snapshot())
	data, e := json.Marshal(snapshot)
	if e != nil || len(data) > 2<<20 {
		t.Fatalf("snapshot wire budget exceeded: %d %v", len(data), e)
	}
	if len(snapshot.Items) == 0 || snapshot.Items[len(snapshot.Items)-1].ID != fmt.Sprintf("item-%d", MaxItems-1) || snapshot.OlderBefore == 0 {
		t.Fatal("snapshot dropped newest item or pagination")
	}
	if !strings.HasSuffix(snapshot.Failure, "[truncated]") {
		t.Fatal("bounded error did not disclose truncation")
	}
}
