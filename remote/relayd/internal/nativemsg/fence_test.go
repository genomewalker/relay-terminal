//go:build linux || darwin

package nativemsg

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// flippingSource reports a different incarnation for one process after its
// first `after` identity reads, as if that process exited and its PID was
// reused mid-operation.
type flippingSource struct {
	processSource
	mu    sync.Mutex
	pid   int64
	after int
	calls map[int64]int
}

func (s *flippingSource) identity(pid int64) (string, error) {
	s.mu.Lock()
	s.calls[pid]++
	n := s.calls[pid]
	s.mu.Unlock()
	start, err := s.processSource.identity(pid)
	if err == nil && pid == s.pid && s.after > 0 && n > s.after {
		start += "-reused"
	}
	return start, err
}

func (f *fixture) runWith(t *testing.T, source processSource, packet map[string]any) map[string]any {
	t.Helper()
	host := f.host()
	host.proc = source
	return f.runHost(t, host, packet)
}

func (f *fixture) runHost(t *testing.T, host Host, packet map[string]any) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var result map[string]any
	if err := json.Unmarshal(Output(Run(ctx, host, f.pane, request(packet))), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

// requireEveryIncarnationFence changes each process's incarnation after each
// of its identity reads but the last and requires the operation to fail
// before any write.
func requireEveryIncarnationFence(t *testing.T, f *fixture, packet map[string]any, succeeded func(map[string]any) bool, baselineWrites int) {
	t.Helper()
	requireIncarnationFence(t, f, f.host(), packet, succeeded, baselineWrites)
}

func requireIncarnationFence(t *testing.T, f *fixture, host Host, packet map[string]any, succeeded func(map[string]any) bool, baselineWrites int) {
	t.Helper()
	run := func(source processSource) map[string]any {
		host.proc = source
		return f.runHost(t, host, packet)
	}
	baseline := &flippingSource{processSource: defaultSource(), calls: map[int64]int{}}
	f.clearRecords()
	if result := run(baseline); !succeeded(result) {
		t.Fatalf("baseline failed: %v", result)
	}
	if len(writes(f.settledRecords())) != baselineWrites {
		t.Fatal("baseline wrote an unexpected number of messages")
	}
	checked := 0
	for pid, total := range baseline.calls {
		for after := 1; after < total; after++ {
			f.clearRecords()
			source := &flippingSource{processSource: defaultSource(), pid: pid, after: after, calls: map[int64]int{}}
			result := run(source)
			if succeeded(result) {
				t.Fatalf("pid %d reused after read %d of %d, still succeeded: %v", pid, after, total, result)
			}
			if records := writes(f.settledRecords()); len(records) != 0 {
				t.Fatalf("pid %d reused after read %d of %d, wrote %d deliveries: %v", pid, after, total, len(records), result)
			}
			if result["replay_permitted"] != false {
				t.Fatalf("failure permits replay: %v", result)
			}
			checked++
		}
	}
	if checked == 0 {
		t.Fatal("no process was read more than once")
	}
}

func TestEveryIncarnationReadFencesClaudeDiscovery(t *testing.T) {
	f := claudePane(t)
	f.claudeBinding(nil)
	requireEveryIncarnationFence(t, f, discover(), func(result map[string]any) bool {
		return result["endpoint"] != nil
	}, 0)
}

func TestEveryIncarnationReadFencesClaudeDelivery(t *testing.T) {
	f := claudePane(t)
	f.claudeBinding(nil)
	endpoint, _ := f.runWith(t, defaultSource(), discover())["endpoint"].(map[string]any)
	if endpoint == nil {
		t.Fatal("no endpoint")
	}
	requireEveryIncarnationFence(t, f, send(endpoint, kernelSource(nil), "hi"), func(result map[string]any) bool {
		return result["status"] == "written_to_socket"
	}, 1)
}

func TestEveryIncarnationReadFencesCodexDelivery(t *testing.T) {
	f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}})
	f.codexBinding(nil)
	endpoint, _ := f.runWith(t, defaultSource(), discover())["endpoint"].(map[string]any)
	if endpoint == nil {
		t.Fatal("no endpoint")
	}
	requireEveryIncarnationFence(t, f, send(endpoint, kernelSource(nil), "hi"), func(result map[string]any) bool {
		status, _ := result["status"].(string)
		return status != "" && status != "unavailable" && status != "outcome_unknown"
	}, 1)
}

// A send whose endpoint no longer matches never connects to anything.
func TestAChangedEndpointIsNeverWritten(t *testing.T) {
	f := claudePane(t)
	f.claudeBinding(nil)
	endpoint, _ := f.runWith(t, defaultSource(), discover())["endpoint"].(map[string]any)
	for _, field := range []string{"socketStart", "socketIdentity", "sessionID", "rootStart"} {
		changed := map[string]any{}
		for key, value := range endpoint {
			changed[key] = value
		}
		changed[field] = "x"
		f.clearRecords()
		result := f.runWith(t, defaultSource(), send(changed, kernelSource(nil), "hi"))
		if result["status"] != "outcome_unknown" || !strings.Contains(result["error"].(string), "changed: "+field) {
			t.Fatalf("%s: %v", field, result)
		}
		if records := f.settledRecords(); len(records) != 0 {
			t.Fatalf("%s: wrote %d", field, len(records))
		}
	}
}

// writes are the recorded connections that carried a message: a Claude inbox
// authentication or a Codex turn, not Codex discovery's read-only requests.
func writes(records []string) []string {
	var result []string
	for _, record := range records {
		if strings.Contains(record, "turn/start") || strings.Contains(record, `"auth"`) {
			result = append(result, record)
		}
	}
	return result
}

// Without relayd's inbound class the inbox incarnation check just before the
// Claude write is the last one; it alone must stop a reused PID.
func TestTheLastIncarnationReadFencesClaudeDeliveryWithoutAnInboundClass(t *testing.T) {
	f := claudePane(t)
	f.claudeBinding(nil)
	host := f.host()
	host.InboundClass = nil
	endpoint, _ := f.runHost(t, host, discover())["endpoint"].(map[string]any)
	if endpoint == nil {
		t.Fatal("no endpoint")
	}
	requireIncarnationFence(t, f, host, send(endpoint, kernelSource(nil), "hi"), func(result map[string]any) bool {
		return result["status"] == "written_to_socket"
	}, 1)
}

// replaceSocket puts a fresh listening socket at path, as a process that
// recreated its inbox would, and reports whether anything ever wrote to it.
func replaceSocket(t *testing.T, path string) func() bool {
	t.Helper()
	spare := path + ".new"
	listener, err := net.Listen("unix", spare)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(spare, path); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	wrote := false
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				conn.SetReadDeadline(time.Now().Add(10 * time.Second))
				// A WebSocket upgrade request is discovery, not a message; it is
				// never answered, so no frame can follow it.
				data := make([]byte, 16)
				n, _ := io.ReadFull(conn, data)
				if n > 0 && !strings.HasPrefix("GET / HTTP/1.1\r\n", string(data[:n])) {
					mu.Lock()
					wrote = true
					mu.Unlock()
				}
			}()
		}
	}()
	t.Cleanup(func() { listener.Close() })
	return func() bool {
		time.Sleep(100 * time.Millisecond)
		mu.Lock()
		defer mu.Unlock()
		return wrote
	}
}

// requireEverySocketReadFence replaces the socket at path just before each
// read of its identity and requires the operation to fail without writing
// to the old or the new socket.
func requireEverySocketReadFence(t *testing.T, newPane func(t *testing.T) (*fixture, map[string]any), path func(*fixture) string,
	succeeded func(map[string]any) bool) {
	t.Helper()
	f, packet := newPane(t)
	host := f.host()
	reads := 0
	host.beforeSocketCheck = func(p string) {
		if p == path(f) {
			reads++
		}
	}
	f.clearRecords()
	if result := f.runHost(t, host, packet); !succeeded(result) {
		t.Fatalf("baseline failed: %v", result)
	}
	if len(writes(f.settledRecords())) != 1 {
		t.Fatal("baseline did not write exactly once")
	}
	if reads == 0 {
		t.Fatal("the socket identity was never read")
	}
	for at := 1; at <= reads; at++ {
		f, packet := newPane(t)
		host := f.host()
		seen := 0
		wroteNew := func() bool { return false }
		host.beforeSocketCheck = func(p string) {
			if p == path(f) {
				if seen++; seen == at {
					wroteNew = replaceSocket(t, p)
				}
			}
		}
		f.clearRecords()
		result := f.runHost(t, host, packet)
		if succeeded(result) {
			t.Fatalf("socket replaced before read %d of %d, still succeeded: %v", at, reads, result)
		}
		if records := writes(f.settledRecords()); len(records) != 0 || wroteNew() {
			t.Fatalf("socket replaced before read %d of %d, wrote (old %d, new %v): %v", at, reads, len(records), wroteNew(), result)
		}
		if result["replay_permitted"] != false {
			t.Fatalf("failure permits replay: %v", result)
		}
	}
}

func TestEverySocketReadFencesClaudeDelivery(t *testing.T) {
	requireEverySocketReadFence(t, func(t *testing.T) (*fixture, map[string]any) {
		f := claudePane(t)
		f.claudeBinding(nil)
		endpoint, _ := f.runHost(t, f.host(), discover())["endpoint"].(map[string]any)
		if endpoint == nil {
			t.Fatal("no endpoint")
		}
		return f, send(endpoint, kernelSource(nil), "hi")
	}, func(f *fixture) string { return f.path("s/c.sock") }, func(result map[string]any) bool {
		return result["status"] == "written_to_socket"
	})
}

func TestEverySocketReadFencesCodexDelivery(t *testing.T) {
	requireEverySocketReadFence(t, func(t *testing.T) (*fixture, map[string]any) {
		f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}})
		f.codexBinding(nil)
		endpoint, _ := f.runHost(t, f.host(), discover())["endpoint"].(map[string]any)
		if endpoint == nil {
			t.Fatal("no endpoint")
		}
		return f, send(endpoint, kernelSource(nil), "hi")
	}, func(f *fixture) string { return f.path("codex/app-server-control/app-server-control.sock") }, func(result map[string]any) bool {
		status, _ := result["status"].(string)
		return status != "" && status != "unavailable" && status != "outcome_unknown"
	})
}
