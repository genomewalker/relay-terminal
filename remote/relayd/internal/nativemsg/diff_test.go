//go:build linux || darwin

package nativemsg

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// These original differential cases now compare against captured canonical
// result and delivery bytes, instantiated with this fixture's independently
// observed process and inode identities. Real processes and sockets remain.

// request is the packet as communicationNative encodes it.
func request(packet map[string]any) []byte {
	packet["requireAuthenticatedBinding"] = true
	data, err := json.Marshal(packet)
	if err != nil {
		panic(err)
	}
	return data
}

func (f *fixture) host() Host {
	dir := f.path("fix")
	return Host{
		Binding: func(pane, session string) ([]byte, error) { return fixtureBinding(dir, pane, session) },
		InboundClass: func(int, string) (string, string) {
			return fixtureInboundClass(dir), ""
		},
		Getenv: func(key string) (string, bool) {
			value, ok := f.env[key]
			return value, ok
		},
	}
}

func (f *fixture) runPort(t *testing.T, packet []byte) []byte {
	t.Helper()
	os.Remove(f.path("fix/binding.count"))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return Output(Run(ctx, f.host(), f.pane, packet))
}

// settledRecords waits until the fake inboxes have written every connection.
func (f *fixture) settledRecords() []string {
	var last []string
	for i := 0; i < 50; i++ {
		time.Sleep(40 * time.Millisecond)
		current := f.records("*.sock")
		if i > 3 && len(current) == len(last) {
			return current
		}
		last = current
	}
	return last
}

// compare retains the canonical result, required result fragment, exact
// connection count and every recorded delivery byte for each original case.
func (f *fixture) compare(t *testing.T, packet map[string]any, want string) map[string]any {
	t.Helper()
	raw := f.checkedReference(t, request(packet), want)
	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("result is not JSON: %v", err)
	}
	return result
}

func normalizeRecord(record string) string { return record }

const (
	sessionA = "11111111-2222-4333-8444-555555555555"
	sessionB = "66666666-7777-4888-9999-aaaaaaaaaaaa"
	sessionC = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
	threadA  = "019a0000-0000-7000-8000-000000000001"
	revision = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)

// claudePane is a pane running one Claude whose inbox records deliveries.
func claudePane(t *testing.T, opts ...func(*paneOptions)) *fixture {
	t.Helper()
	o := paneOptions{program: "bin/claude", holdTranscript: true}
	for _, opt := range opts {
		opt(&o)
	}
	f := newFixture(t)
	transcript := f.path("claude/projects/p/" + sessionA + ".jsonl")
	f.write("claude/projects/p/"+sessionA+".jsonl", `{"type":"user","sessionId":"`+sessionA+`","message":{"content":"hi"}}`+"\n")
	program := f.path(o.program)
	if o.program == "versions" {
		program = f.path("home/.local/share/claude/versions/2.1.3")
		os.MkdirAll(filepath.Dir(program), 0o700)
		copyFile(t, f.bin, program)
	}
	args := []string{"--socket", f.path("s/c.sock"), "--record", f.path("rec")}
	if o.holdTranscript {
		args = append(args, "--open", transcript)
	}
	env := map[string]string{"CLAUDE_CONFIG_DIR": f.path("claude")}
	agents := []agentSpec{{name: "claude", program: program, args: args, env: env}}
	agents = append(agents, o.extra(f)...)
	f.start(agents, o.detached(f))
	if !o.noWorker {
		f.workerRecord(nil)
	}
	f.claudeSession("claude", sessionA, f.path("s/c.sock"), nil)
	return f
}

type paneOptions struct {
	program        string
	holdTranscript bool
	noWorker       bool
	extraAgents    func(*fixture) []agentSpec
	detachedAgents func(*fixture) []agentSpec
}

func (o paneOptions) extra(f *fixture) []agentSpec {
	if o.extraAgents == nil {
		return nil
	}
	return o.extraAgents(f)
}

func (o paneOptions) detached(f *fixture) []agentSpec {
	if o.detachedAgents == nil {
		return nil
	}
	return o.detachedAgents(f)
}

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	in, err := os.Open(from)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o700)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		t.Fatal(err)
	}
	out.Close()
}

// claudeBinding is relayd's verified binding of the pane's Claude.
func (f *fixture) claudeBinding(overrides map[string]any) map[string]any {
	binding := map[string]any{"version": 1, "producer": map[string]any{"pane_id": f.pane, "provider": "claude",
		"process_id": f.pids["claude"], "process_start": 4242, "sender_pid": 1},
		"session_id": sessionA, "transcript_path": f.path("claude/projects/p/" + sessionA + ".jsonl"),
		"observed_at": time.Now().UTC().Format(time.RFC3339Nano), "lifecycle": "idle", "revision": revision,
		"source": "native_claude_frontend"}
	for key, value := range overrides {
		if value == nil {
			delete(binding, key)
		} else {
			binding[key] = value
		}
	}
	f.write("fix/binding.json", binding)
	return binding
}

func discover() map[string]any { return map[string]any{"operation": "discover"} }

func TestDifferentialClaudeDiscovery(t *testing.T) {
	t.Run("unbound frontend proven by its own inbox", func(t *testing.T) {
		f := claudePane(t)
		result := f.compare(t, discover(), `"transport": "native_peer_socket"`)
		if endpoint, _ := result["endpoint"].(map[string]any); endpoint["sessionID"] != sessionA {
			t.Fatalf("endpoint = %v", result)
		}
	})
	t.Run("verified frontend", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(nil)
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("binding names another process", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(map[string]any{"producer": map[string]any{"pane_id": f.pane, "provider": "claude", "process_id": 1, "process_start": 1}})
		f.compare(t, discover(), "Authenticated producer does not match this conversation.")
	})
	t.Run("binding with an invalid start", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(map[string]any{"producer": map[string]any{"pane_id": f.pane, "provider": "claude", "process_id": f.pids["claude"], "process_start": true}})
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("relayd crash", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/binding.json", "CRASH")
		f.compare(t, discover(), "Process discovery is unavailable.")
	})
	t.Run("binding is not JSON", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/binding.json", "{")
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("binding names another session", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(map[string]any{"session_id": sessionB})
		f.compare(t, discover(), "Bound transcript does not identify this native session")
	})
	t.Run("binding withdrawn before the final check", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(nil)
		f.write("fix/binding.limit", "2")
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("binding changes during discovery", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(nil)
		f.write("fix/binding.limit", "1")
		f.compare(t, discover(), "Authenticated frontend binding changed while discovering its endpoint")
	})
	t.Run("missing worker record", func(t *testing.T) {
		f := claudePane(t, func(o *paneOptions) { o.noWorker = true })
		f.compare(t, discover(), "No such file or directory")
	})
	t.Run("worker not running", func(t *testing.T) {
		f := claudePane(t)
		f.workerRecord(map[string]any{"state": "exited"})
		f.compare(t, discover(), "No live durable worker owns this pane.")
	})
	t.Run("worker PID as text", func(t *testing.T) {
		f := claudePane(t)
		f.workerRecord(map[string]any{"worker_pid": fmt.Sprintf(" %d\n", f.worker)})
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("worker PID not a number", func(t *testing.T) {
		f := claudePane(t)
		f.workerRecord(map[string]any{"worker_pid": "12a"})
		f.compare(t, discover(), "invalid literal for int() with base 10: '12a'")
	})
	t.Run("worker record without shell", func(t *testing.T) {
		f := claudePane(t)
		f.workerRecord(map[string]any{"shell_pid": nil})
		f.compare(t, discover(), `"error": "'shell_pid'"`)
	})
	t.Run("worker incarnation changed", func(t *testing.T) {
		if runtime.GOOS != "linux" {
			t.Skip("the adapter checks the worker incarnation on Linux only")
		}
		f := claudePane(t)
		f.workerRecord(map[string]any{"worker_start_time": 1})
		f.compare(t, discover(), "The worker process incarnation changed.")
	})
	t.Run("shell not under its worker", func(t *testing.T) {
		f := claudePane(t)
		f.workerRecord(map[string]any{"worker_pid": f.pids["claude"]})
		if runtime.GOOS == "linux" {
			start, _ := json.Number(f.starts["claude"]).Int64()
			f.workerRecord(map[string]any{"worker_pid": f.pids["claude"], "worker_start_time": start})
		}
		f.compare(t, discover(), "The pane shell is not owned by its worker.")
	})
	t.Run("recovered worker records", func(t *testing.T) {
		f := claudePane(t)
		data, _ := os.ReadFile(f.path("state/relay/workers/" + f.pane + ".json"))
		f.write("state/relay/workers/recovered-1/"+f.pane+".json", data)
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
		f.write("state/relay/workers/recovered-2/"+f.pane+".json", data)
		f.compare(t, discover(), "Multiple recovered workers claim this pane.")
	})
	t.Run("two agents in the pane", func(t *testing.T) {
		f := claudePane(t, func(o *paneOptions) {
			o.extraAgents = func(f *fixture) []agentSpec {
				return []agentSpec{{name: "codex", program: f.path("bin/codex"), env: map[string]string{}}}
			}
		})
		f.compare(t, discover(), "An exact, unique foreground agent is required.")
	})
	t.Run("transcript from the session registry", func(t *testing.T) {
		f := claudePane(t, func(o *paneOptions) { o.holdTranscript = false })
		f.compare(t, discover(), `"transcriptIdentity": "`)
	})
	t.Run("session from the inbox alone", func(t *testing.T) {
		f := claudePane(t, func(o *paneOptions) { o.holdTranscript = false })
		os.Remove(f.path("claude/projects/p/" + sessionA + ".jsonl"))
		f.compare(t, discover(), `"transcriptIdentity": ""`)
	})
	t.Run("inbox key too short", func(t *testing.T) {
		f := claudePane(t)
		for _, name := range globFixture(f, "claude/sessions/*.key") {
			f.write(name, map[string]any{"peerToken": "short"})
		}
		f.compare(t, discover(), "This pane has no kernel-validated native session endpoint")
	})
	t.Run("inbox key not an object", func(t *testing.T) {
		f := claudePane(t)
		for _, name := range globFixture(f, "claude/sessions/*.key") {
			f.write(name, "[1]")
		}
		f.compare(t, discover(), "'list' object has no attribute 'get'")
	})
	t.Run("relay proxy row", func(t *testing.T) {
		f := claudePane(t)
		f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"relayProxy": true})
		f.compare(t, discover(), "This pane has no kernel-validated native session endpoint")
	})
	t.Run("stale procStart", func(t *testing.T) {
		f := claudePane(t)
		f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"procStart": 7})
		f.compare(t, discover(), "This pane has no kernel-validated native session endpoint")
	})
	t.Run("parked frontend without its job", func(t *testing.T) {
		f := claudePane(t)
		f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"parkedJobId": "abcdef12"})
		f.compare(t, discover(), "Parked Claude conversation has no verified background attachment")
	})
	t.Run("session record not JSON", func(t *testing.T) {
		f := claudePane(t)
		f.write(fmt.Sprintf("claude/sessions/%d.json", f.pids["claude"]), "\n  {\"pid\": 1,}")
		f.compare(t, discover(), "Expecting property name enclosed in double quotes: line 2 column 13 (char 13)")
	})
	t.Run("session record not an object", func(t *testing.T) {
		f := claudePane(t)
		f.write(fmt.Sprintf("claude/sessions/%d.json", f.pids["claude"]), "[1, 2.50, NaN]")
		f.compare(t, discover(), "'list' object has no attribute 'get'")
	})
	t.Run("session record is a symlink", func(t *testing.T) {
		f := claudePane(t)
		name := f.path(fmt.Sprintf("claude/sessions/%d.json", f.pids["claude"]))
		os.Rename(name, name+".real")
		os.Symlink(name+".real", name)
		f.compare(t, discover(), "Too many levels of symbolic links")
	})
	t.Run("session record writable by others", func(t *testing.T) {
		f := claudePane(t)
		os.Chmod(f.path(fmt.Sprintf("claude/sessions/%d.json", f.pids["claude"])), 0o620)
		f.compare(t, discover(), "Unsafe native session record")
	})
	t.Run("native installer version name", func(t *testing.T) {
		f := claudePane(t, func(o *paneOptions) { o.program = "versions" })
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("zombie Claude beside the live one", func(t *testing.T) {
		if runtime.GOOS != "linux" {
			t.Skip("procps names a zombie <defunct> on Linux")
		}
		f := claudePane(t, func(o *paneOptions) {
			o.extraAgents = func(f *fixture) []agentSpec {
				return []agentSpec{{name: "holder", program: f.path("bin/holder"),
					args: []string{"--zombie-child", f.path("bin/claude")}, env: map[string]string{}}}
			}
		})
		time.Sleep(300 * time.Millisecond)
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("invalid target", func(t *testing.T) {
		f := claudePane(t)
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": "x"}, "Invalid target session")
	})
	t.Run("target without its own binding", func(t *testing.T) {
		f := claudePane(t)
		f.claudeBinding(nil)
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": sessionB},
			"Target session is not a verified live background job of this pane")
	})
	t.Run("unknown operation", func(t *testing.T) {
		f := claudePane(t)
		f.compare(t, map[string]any{"operation": "observe"}, "Unknown messaging operation")
	})
}

func globFixture(f *fixture, pattern string) []string {
	matches, _ := filepath.Glob(f.path(pattern))
	var result []string
	for _, match := range matches {
		rel, _ := filepath.Rel(f.dir, match)
		result = append(result, rel)
	}
	sort.Strings(result)
	return result
}

// parkedPane is a Claude frontend whose conversation is parked in a
// background job running outside the pane.
func parkedPane(t *testing.T) (*fixture, map[string]any) {
	t.Helper()
	f := claudePane(t, func(o *paneOptions) {
		o.detachedAgents = func(f *fixture) []agentSpec {
			return []agentSpec{{name: "job", program: f.path("bin/claude"),
				args: []string{"--socket", f.path("s/j.sock"), "--record", f.path("rec")},
				env:  map[string]string{"CLAUDE_CONFIG_DIR": f.path("claude")}}}
		}
	})
	f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"parkedJobId": "abcdef12"})
	f.claudeSession("job", sessionB, f.path("s/j.sock"), map[string]any{"kind": "bg", "jobId": "abcdef12"})
	peer := map[string]any{"pid": f.pids["job"], "process_start": f.starts["job"], "socket": f.path("s/j.sock"),
		"socket_identity": f.socketIdentity(f.path("s/j.sock")), "job_id": "abcdef12", "frontend_session": sessionA}
	binding := f.claudeBinding(map[string]any{"session_id": sessionB, "transcript_path": "",
		"source": "native_parked_job_kernel_owner", "native_peer": peer})
	return f, binding
}

func TestDifferentialParkedClaude(t *testing.T) {
	t.Run("parked job inbox", func(t *testing.T) {
		f, _ := parkedPane(t)
		f.compare(t, discover(), `"bindingSource": "native_parked_job_kernel_owner"`)
	})
	t.Run("parked job inbox replaced", func(t *testing.T) {
		f, binding := parkedPane(t)
		binding["native_peer"].(map[string]any)["socket_identity"] = "1:2"
		f.write("fix/binding.json", binding)
		f.compare(t, discover(), "Native parked inbox changed")
	})
	t.Run("parked job publication changed", func(t *testing.T) {
		f, _ := parkedPane(t)
		f.claudeSession("job", sessionB, f.path("s/j.sock"), map[string]any{"kind": "bg", "jobId": "00000000"})
		f.compare(t, discover(), "Native parked conversation publication changed")
	})
	t.Run("parked proof invalid", func(t *testing.T) {
		f, binding := parkedPane(t)
		binding["native_peer"].(map[string]any)["pid"] = true
		f.write("fix/binding.json", binding)
		f.compare(t, discover(), "Invalid native parked conversation proof")
	})
	t.Run("binding withdrawn: the foreground still publishes the job", func(t *testing.T) {
		f, _ := parkedPane(t)
		f.write("fix/binding.limit", "2")
		f.compare(t, discover(), `"transport": "native_peer_socket"`)
	})
	t.Run("binding withdrawn and the foreground moved on", func(t *testing.T) {
		f, _ := parkedPane(t)
		f.write("fix/binding.limit", "2")
		f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"parkedJobId": "99999999"})
		// The first discovery already refuses a foreground without this job.
		f.compare(t, discover(), "error")
	})
	t.Run("pane job target", func(t *testing.T) {
		f, binding := parkedPane(t)
		binding["source"] = "native_pane_job_kernel_owner"
		f.write("fix/binding-"+sessionB+".json", binding)
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": sessionB}, `"socketPID": `)
	})
}

// codexPane is a pane running one Codex whose control socket is a fake
// app-server scripted by config.
func codexPane(t *testing.T, config codexConfig) *fixture {
	t.Helper()
	f := newFixture(t)
	transcript := f.path("codex/sessions/2026/rollout.jsonl")
	f.write("codex/sessions/2026/rollout.jsonl", `{"type":"session_meta","payload":{"id":"`+threadA+`","source":"cli"}}`+"\n")
	if config.Thread == nil {
		config.Thread = map[string]any{"id": threadA, "path": transcript}
	}
	if config.Turn == nil {
		config.Turn = map[string]any{"id": "turn-7"}
	}
	f.write("fix/codex.json", config)
	socket := f.path("codex/app-server-control/app-server-control.sock")
	f.start([]agentSpec{{name: "codex", program: f.path("bin/codex"),
		args: []string{"--mode", "codex", "--socket", socket, "--record", f.path("rec"), "--config", f.path("fix/codex.json"), "--open", transcript},
		env:  map[string]string{"CODEX_HOME": f.path("codex")}}}, nil)
	f.workerRecord(nil)
	return f
}

func (f *fixture) codexBinding(overrides map[string]any) map[string]any {
	binding := map[string]any{"version": 1, "producer": map[string]any{"pane_id": f.pane, "provider": "codex",
		"process_id": f.pids["codex"], "process_start": 4242, "sender_pid": 1},
		"session_id": threadA, "transcript_path": f.path("codex/sessions/2026/rollout.jsonl"),
		"observed_at": "2026-10-21T00:00:00Z", "lifecycle": "idle", "revision": revision, "source": "native_codex_frontend"}
	for key, value := range overrides {
		if value == nil {
			delete(binding, key)
		} else {
			binding[key] = value
		}
	}
	f.write("fix/binding.json", binding)
	return binding
}

func (f *fixture) stockProxy(overrides map[string]any) map[string]any {
	socket := f.path("codex/app-server-control/app-server-control.sock")
	binding := map[string]any{"source": "stock_app_server_proxy",
		"native_endpoint": map[string]any{"socket": socket, "daemon_pid": f.pids["codex"], "daemon_start": 777,
			"frontend_socket": "", "daemon_socket": socket, "origin": "stock", "device": 1, "inode": 2},
		"stock_proxy": map[string]any{"proxy_pid": 2, "proxy_start": 3, "control_socket": socket, "control_device": 4,
			"control_inode": 5, "connection": 6, "selection": 7}}
	for key, value := range overrides {
		binding[key] = value
	}
	return f.codexBinding(binding)
}

func TestDifferentialCodexDiscovery(t *testing.T) {
	loaded := [][]any{{"019a0000-0000-7000-8000-00000000000f"}, {threadA}}
	t.Run("unbound Codex has no proven endpoint", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.compare(t, discover(), "This pane has no kernel-validated native session endpoint")
	})
	t.Run("verified Codex on its default control socket", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "codex_app_server_message"`)
	})
	t.Run("thread not loaded", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: [][]any{{"other"}}})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("server requests and pings are refused or answered", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, Ping: true, ServerRequest: true})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "codex_app_server_message"`)
	})
	t.Run("handshake accept key wrong", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, BadAccept: true})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("handshake refused", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, Status: "403 Forbidden"})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("thread read rejected", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, RejectMethod: "thread/read"})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("thread at another path", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, Thread: map[string]any{"id": threadA, "path": "/elsewhere.jsonl"}})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("loaded list not an object", func(t *testing.T) {
		f := codexPane(t, codexConfig{Results: map[string]any{"thread/loaded/list": []any{1}}})
		f.codexBinding(nil)
		f.compare(t, discover(), "'list' object has no attribute 'get'")
	})
	t.Run("loaded list data is text", func(t *testing.T) {
		f := codexPane(t, codexConfig{Results: map[string]any{"thread/loaded/list": map[string]any{"data": "x" + threadA}}})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "codex_app_server_message"`)
	})
	t.Run("thread reply without thread", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded, Results: map[string]any{"thread/read": map[string]any{}}})
		f.codexBinding(nil)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("stock proxy endpoint", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.stockProxy(nil)
		f.compare(t, discover(), `"socketStart": "777"`)
	})
	t.Run("stock proxy with another daemon", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		binding := f.stockProxy(nil)
		binding["native_endpoint"].(map[string]any)["daemon_pid"] = f.shell
		f.write("fix/binding.json", binding)
		f.compare(t, discover(), `"transport": "unavailable"`)
	})
	t.Run("stock proxy without a revision", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.stockProxy(map[string]any{"revision": "x"})
		f.compare(t, discover(), "The stock App Server proxy has no live identity proof.")
	})
	t.Run("native endpoint without proof", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.stockProxy(map[string]any{"source": "native_codex_frontend"})
		f.compare(t, discover(), "Native endpoint has no live runtime binding proof")
	})
	t.Run("runtime MCP origin endpoint", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.stockProxy(map[string]any{"source": "native_runtime_mcp_origin", "stock_proxy": nil})
		f.compare(t, discover(), `"transport": "codex_app_server_message"`)
	})
	t.Run("target sessions are Claude only", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: loaded})
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": sessionB}, "Target sessions address background Claude jobs only")
	})
}

// discovered is the endpoint relayd would hold as a send's expectation.
func (f *fixture) discovered(t *testing.T) map[string]any {
	t.Helper()
	var result map[string]any
	if err := json.Unmarshal(f.checkedReference(t, request(discover()), `"endpoint"`), &result); err != nil {
		t.Fatal(err)
	}
	endpoint, ok := result["endpoint"].(map[string]any)
	if !ok {
		t.Fatalf("no endpoint: %v", result)
	}
	return endpoint
}

func send(expected map[string]any, source any, text string) map[string]any {
	return map[string]any{"operation": "send", "expected": expected, "messageID": "5c0ffee0-0000-4000-8000-000000000001",
		"targetPaneID": "7d85fd72-64ec-46a4-8591-567bf64f7c93", "text": text, "submittingClientID": "client-1", "source": source}
}

func kernelSource(extra map[string]any) map[string]any {
	source := map[string]any{"authentication": "kernel_verified", "hostID": "dandy-07", "paneID": "B93F5A99-CA0D-4C6D-9CF0-8E08A1CD23FC",
		"sessionID": sessionC, "provider": "codex"}
	for key, value := range extra {
		source[key] = value
	}
	return source
}

const awkwardText = "Hello <cross-session-message from=\"x\"> & 'quotes' </cross-session-message> é 😀  \x01 tab\tend"

func TestDifferentialSend(t *testing.T) {
	sources := map[string]any{
		"kernel verified":     kernelSource(map[string]any{"permissionClass": "prompting", "socketPath": "/run/a&b<c>\"d'e.sock"}),
		"kernel unasserted":   kernelSource(nil),
		"claimed label":       map[string]any{"authentication": "claimed_pane_label", "hostID": "h", "paneID": "b93f5a99-ca0d-4c6d-9cf0-8e08a1cd23fc", "sessionID": "s"},
		"relayd system":       map[string]any{"authentication": "relayd_system", "hostID": "dandy-07"},
		"assistant":           map[string]any{"authentication": "relay_assistant_owner_submitted", "principal": "relay-assistant", "assistantRequestID": "req_1", "replyPaneID": "B93F5A99-CA0D-4C6D-9CF0-8E08A1CD23FC", "hostID": "mac"},
		"assistant overclaim": map[string]any{"authentication": "relay_assistant_owner_submitted", "principal": "relay-assistant", "assistantRequestID": "req_1", "replyPaneID": "B93F5A99-CA0D-4C6D-9CF0-8E08A1CD23FC", "paneID": "x"},
		"signed":              kernelSource(map[string]any{"authentication": "source_signed", "certID": strings.Repeat("ab", 16), "nodeCertificateSHA256": strings.Repeat("cd", 32), "permissionClass": "bypass", "socketPath": "/run/x.sock"}),
		"attested":            kernelSource(map[string]any{"authentication": "source_host_attested", "attestationID": strings.Repeat("0f", 16), "socketPath": "/run/x.sock"}),
		"attested malformed":  kernelSource(map[string]any{"authentication": "source_host_attested", "attestationID": "nope"}),
	}
	names := make([]string, 0, len(sources))
	for name := range sources {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		source := sources[name]
		t.Run("Claude inbox from "+name, func(t *testing.T) {
			f := claudePane(t)
			f.compare(t, send(f.discovered(t), source, awkwardText), `"status": "written_to_socket"`)
		})
		t.Run("Codex turn from "+name, func(t *testing.T) {
			f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}})
			f.codexBinding(nil)
			f.compare(t, send(f.discovered(t), source, awkwardText), `"status": "accepted_by_provider"`)
		})
	}
	t.Run("held: a verified sender with another mode", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/inbound", "bypass")
		f.compare(t, send(f.discovered(t), sources["kernel verified"], "hi"), `"reason": "held_expected"`)
	})
	t.Run("held warning for an unverified sender", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/inbound", "bypass")
		f.compare(t, send(f.discovered(t), sources["claimed label"], "hi"), `"held_expected": "mode_mismatch"`)
	})
	t.Run("no hold for a matching mode", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/inbound", "prompting")
		f.compare(t, send(f.discovered(t), sources["kernel verified"], "hi"), `"status": "written_to_socket"`)
	})
	t.Run("unasserted sender to a bypass recipient", func(t *testing.T) {
		f := claudePane(t)
		f.write("fix/inbound", "bypass")
		f.compare(t, send(f.discovered(t), sources["kernel unasserted"], "hi"), `"held_expected": "no_mode_asserted"`)
	})
	t.Run("recipient changed before delivery", func(t *testing.T) {
		f := claudePane(t)
		expected := f.discovered(t)
		expected["socketPID"] = float64(1)
		expected["extra"] = "x"
		delete(expected, "rootStart")
		f.compare(t, send(expected, sources["claimed label"], "hi"), "changed: extra, rootStart, socketPID")
	})
	t.Run("expected is not an object", func(t *testing.T) {
		f := claudePane(t)
		packet := send(nil, sources["claimed label"], "hi")
		packet["expected"] = "x"
		f.compare(t, packet, `"status": "outcome_unknown"`)
	})
	t.Run("blank text", func(t *testing.T) {
		f := claudePane(t)
		f.compare(t, send(f.discovered(t), sources["claimed label"], " 　\x1c\n"), "Invalid collaborator message")
	})
	t.Run("oversized frame", func(t *testing.T) {
		f := claudePane(t)
		f.compare(t, send(f.discovered(t), sources["claimed label"], "a"+strings.Repeat("\x01", 11000)), "Native message exceeds frame limit")
	})
	t.Run("oversized Codex frame", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}})
		f.codexBinding(nil)
		f.compare(t, send(f.discovered(t), sources["claimed label"], "a"+strings.Repeat("\x01", 11000)), "Native message exceeds frame limit")
	})
	t.Run("missing source", func(t *testing.T) {
		f := claudePane(t)
		packet := send(f.discovered(t), nil, "hi")
		delete(packet, "source")
		f.compare(t, packet, `"error": "'source'"`)
	})
	t.Run("parked job", func(t *testing.T) {
		f, _ := parkedPane(t)
		f.compare(t, send(f.discovered(t), sources["kernel verified"], "to the job"), `"status": "written_to_socket"`)
	})
	t.Run("Codex turn rejected", func(t *testing.T) {
		f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}, RejectMethod: "turn/start"})
		f.codexBinding(nil)
		f.compare(t, send(f.discovered(t), sources["relayd system"], "hi"), "Native provider rejected turn/start")
	})
}

// foreignInboxPane publishes, for the pane's Claude, an inbox that another
// process (a detached job) listens on.
func foreignInboxPane(t *testing.T) *fixture {
	t.Helper()
	f := claudePane(t, func(o *paneOptions) {
		o.detachedAgents = func(f *fixture) []agentSpec {
			return []agentSpec{{name: "job", program: f.path("bin/claude"),
				args: []string{"--socket", f.path("s/j.sock"), "--record", f.path("rec")},
				env:  map[string]string{"CLAUDE_CONFIG_DIR": f.path("claude")}}}
		}
	})
	f.claudeSession("claude", sessionA, f.path("s/j.sock"), nil)
	return f
}

func TestDifferentialFences(t *testing.T) {
	t.Run("unverified inbox owned by another process", func(t *testing.T) {
		f := foreignInboxPane(t)
		f.compare(t, discover(), "Native inbox kernel owner mismatch")
	})
	t.Run("send to a verified pane's inbox owned by another process", func(t *testing.T) {
		f := foreignInboxPane(t)
		f.claudeBinding(nil)
		f.compare(t, send(f.discovered(t), kernelSource(nil), "hi"), "Native inbox kernel owner mismatch")
	})
	t.Run("binding is replaced during discovery", func(t *testing.T) {
		f := claudePane(t)
		binding := f.claudeBinding(nil)
		f.write("fix/binding.limit", "1")
		binding["revision"] = strings.Repeat("f", 64)
		f.write("fix/binding.after.json", binding)
		f.compare(t, discover(), "Authenticated frontend binding changed while discovering its endpoint")
	})
	t.Run("binding moves to another session after discovery", func(t *testing.T) {
		f := claudePane(t)
		binding := f.claudeBinding(nil)
		f.write("fix/binding.limit", "2")
		binding["session_id"] = sessionB
		f.write("fix/binding.after.json", binding)
		f.compare(t, discover(), "Native inbox session disagrees with the authenticated binding")
	})
	for _, size := range []int{15, 16, 256, 257} {
		t.Run(fmt.Sprintf("inbox token of %d characters", size), func(t *testing.T) {
			f := claudePane(t)
			for _, name := range globFixture(f, "claude/sessions/*.key") {
				f.write(name, map[string]any{"peerToken": strings.Repeat("é", size)})
			}
			want := `"transport": "native_peer_socket"`
			if size == 15 || size == 257 {
				want = "This pane has no kernel-validated native session endpoint"
			}
			f.compare(t, discover(), want)
		})
	}
	t.Run("target bound as a parked job is refused", func(t *testing.T) {
		f, binding := parkedPane(t)
		f.write("fix/binding-"+sessionB+".json", binding)
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": sessionB},
			"Target session is not a verified live background job of this pane")
	})
	t.Run("target bound to another session is refused", func(t *testing.T) {
		f, binding := parkedPane(t)
		binding["source"] = "native_pane_job_kernel_owner"
		f.write("fix/binding-"+sessionC+".json", binding)
		f.compare(t, map[string]any{"operation": "discover", "targetSessionID": sessionC},
			"Authenticated target session does not match.")
	})
	t.Run("transcript replaced by a symlink", func(t *testing.T) {
		f := claudePane(t)
		binding := f.claudeBinding(nil)
		link := f.path("claude/projects/p/link.jsonl")
		os.Symlink(binding["transcript_path"].(string), link)
		binding["transcript_path"] = link
		f.write("fix/binding.json", binding)
		f.compare(t, discover(), "Too many levels of symbolic links")
	})
	t.Run("transcript writable by others", func(t *testing.T) {
		f := claudePane(t)
		binding := f.claudeBinding(nil)
		os.Chmod(binding["transcript_path"].(string), 0o622)
		f.compare(t, discover(), "Bound transcript does not identify this native session")
	})
	t.Run("inbox socket writable by others", func(t *testing.T) {
		f := claudePane(t)
		os.Chmod(f.path("s/c.sock"), 0o760)
		f.compare(t, discover(), "This pane has no kernel-validated native session endpoint")
	})
}

// Every file and directory the adapter trusts must be writable by its owner
// alone; group write is as disqualifying as world write.
func TestDifferentialGroupWritable(t *testing.T) {
	for _, c := range []struct {
		name, want string
		hold       bool
		target     func(f *fixture) []string
		mode       os.FileMode
	}{
		{"worker record", "The source file is not an owner-controlled regular file.", true,
			func(f *fixture) []string { return []string{f.path("state/relay/workers/" + f.pane + ".json")} }, 0o620},
		{"session registry row", "Unsafe native session record", false,
			func(f *fixture) []string { return globFixture(f, "claude/sessions/*.json") }, 0o620},
		{"inbox key", `"transport": "unavailable"`, true,
			func(f *fixture) []string { return globFixture(f, "claude/sessions/*.key") }, 0o620},
		{"inbox directory", `"transport": "unavailable"`, true,
			func(f *fixture) []string { return []string{f.path("s")} }, 0o770},
		{"held transcript", "Bound transcript does not identify this native session", true,
			func(f *fixture) []string { return []string{f.path("claude/projects/p/" + sessionA + ".jsonl")} }, 0o620},
		{"registry transcript", `"transcriptIdentity": ""`, false,
			func(f *fixture) []string { return []string{f.path("claude/projects/p/" + sessionA + ".jsonl")} }, 0o620},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := claudePane(t, func(o *paneOptions) { o.holdTranscript = c.hold })
			if c.hold {
				f.claudeBinding(nil)
			}
			// The owner-only baseline succeeds with a full endpoint.
			baseline := f.compare(t, discover(), `"transport": "native_peer_socket"`)
			if endpoint, _ := baseline["endpoint"].(map[string]any); !c.hold && endpoint["transcriptIdentity"] == "" {
				t.Fatalf("baseline has no transcript: %v", baseline)
			}
			targets := c.target(f)
			if len(targets) == 0 {
				t.Fatal("nothing to change")
			}
			for _, target := range targets {
				if !filepath.IsAbs(target) {
					target = f.path(target)
				}
				if err := os.Chmod(target, c.mode); err != nil {
					t.Fatal(err)
				}
			}
			f.compare(t, discover(), c.want)
		})
	}
}
