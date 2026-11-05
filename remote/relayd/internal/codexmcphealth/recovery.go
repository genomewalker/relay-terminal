package codexmcphealth

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// RecoveryFixture is a disposable native app-server test. It cannot address existing threads.
func RecoveryFixture(ctx context.Context, args []string, out, errout io.Writer) (resultErr error) {
	f := flag.NewFlagSet("native-mcp-recovery", flag.ContinueOnError)
	f.SetOutput(errout)
	binaryArg := f.String("binary", "", "staged codex binary with matching native workers")
	resultArg := f.String("result", "", "result file")
	if e := f.Parse(args); e != nil {
		return e
	}
	if *binaryArg == "" || *resultArg == "" || f.NArg() != 0 {
		return errors.New("binary and result required")
	}
	binary, e := filepath.Abs(*binaryArg)
	if e != nil {
		return e
	}
	binary, e = filepath.EvalSymlinks(binary)
	if e != nil {
		return e
	}
	hashes := map[string]string{}
	for _, name := range []string{"codex", "codex-peer-worker", "codex-code-mode-host"} {
		file, e := os.Open(filepath.Join(filepath.Dir(binary), name))
		if e != nil {
			return e
		}
		h := sha256.New()
		_, copyErr := io.Copy(h, file)
		closeErr := file.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		hashes[name] = hex.EncodeToString(h.Sum(nil))
	}
	root, e := os.MkdirTemp("", "relay-mcp-recovery-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(root)
	home := filepath.Join(root, "home")
	codexHome := filepath.Join(home, ".codex")
	if e = os.MkdirAll(codexHome, 0700); e != nil {
		return e
	}
	self, e := os.Executable()
	if e != nil {
		return e
	}
	var config strings.Builder
	for _, s := range []struct{ name, fixture string }{{"relayDesktopR", "broken"}, {"healthy", "healthy"}} {
		command, _ := json.Marshal(self)
		argv, _ := json.Marshal([]string{"--fixture-helper", root, s.fixture})
		fmt.Fprintf(&config, "[mcp_servers.%s]\ncommand = %s\nargs = %s\nstartup_timeout_sec = 5\n", s.name, command, argv)
	}
	if e = os.WriteFile(filepath.Join(codexHome, "config.toml"), []byte(config.String()), 0600); e != nil {
		return e
	}
	if e = os.MkdirAll(filepath.Dir(*resultArg), 0700); e != nil {
		return e
	}
	stderrPath := strings.TrimSuffix(*resultArg, filepath.Ext(*resultArg)) + ".stderr.log"
	stderr, e := os.OpenFile(stderrPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if e != nil {
		return e
	}
	defer stderr.Close()
	cmd := exec.CommandContext(ctx, binary, "app-server", "--listen", "stdio://")
	cmd.Dir = root
	cmd.Env = privateEnvironment(home, codexHome)
	cmd.Stderr = stderr
	input, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	output, e := cmd.StdoutPipe()
	if e != nil {
		return e
	}
	if e = cmd.Start(); e != nil {
		return e
	}
	rpc := newRecoveryRPC(input, output)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer func() {
		_ = input.Close()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				resultErr = errors.New("private fixture process did not terminate within 5 seconds")
			}
		}
	}()
	thread, brokenStarts, e := VerifyRecovery(rpc, root)
	if e != nil {
		return e
	}
	result := map[string]any{"passed": true, "binary": binary, "files": hashes, "thread": thread, "tool_count": 1, "healthy_processes_preserved": true, "failed_process_starts": brokenStarts, "model_turns": 0}
	raw, e := json.MarshalIndent(result, "", "  ")
	if e != nil {
		return e
	}
	if e = os.WriteFile(*resultArg, append(raw, '\n'), 0600); e != nil {
		return e
	}
	fmt.Fprintln(out, "PASS: failed MCP recovered, healthy process and thread preserved; no model turn")
	return nil
}
func privateEnvironment(home, codexHome string) []string {
	out := []string{}
	for _, s := range os.Environ() {
		if !strings.HasPrefix(s, "HOME=") && !strings.HasPrefix(s, "CODEX_HOME=") && !strings.HasPrefix(s, "RELAY_NATIVE_MESSAGES=") {
			out = append(out, s)
		}
	}
	return append(out, "HOME="+home, "CODEX_HOME="+codexHome, "RELAY_NATIVE_MESSAGES=1")
}

type RecoveryRPC interface {
	Call(string, any) (map[string]any, error)
	Status(string, string, string, time.Duration) error
}

func VerifyRecovery(rpc RecoveryRPC, root string) (string, int, error) {
	if _, e := rpc.Call("initialize", map[string]any{"clientInfo": map[string]any{"name": "relay_recovery_fixture", "version": "1"}, "capabilities": map[string]any{"experimentalApi": true}}); e != nil {
		return "", 0, e
	}
	v, e := rpc.Call("thread/start", map[string]any{"cwd": root, "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only"})
	if e != nil {
		return "", 0, e
	}
	threadObj, e := obj(v["thread"])
	if e != nil {
		return "", 0, e
	}
	thread, ok := threadObj["id"].(string)
	if !ok || thread == "" {
		return "", 0, errors.New("missing fixture thread")
	}
	if e = rpc.Status(thread, "healthy", "ready", 30*time.Second); e != nil {
		return "", 0, e
	}
	if e = rpc.Status(thread, "relayDesktopR", "failed", 30*time.Second); e != nil {
		return "", 0, e
	}
	before, e := starts(root, "healthy")
	if e != nil {
		return "", 0, e
	}
	if e = os.WriteFile(filepath.Join(root, "repaired"), []byte("fixture helper repaired\n"), 0600); e != nil {
		return "", 0, e
	}
	if e = rpc.Status(thread, "relayDesktopR", "ready", 80*time.Second); e != nil {
		return "", 0, e
	}
	v, e = rpc.Call("mcpServerStatus/list", map[string]any{"threadId": thread, "serverName": "relayDesktopR", "detail": "toolsAndAuthOnly", "limit": 100})
	if e != nil {
		return "", 0, e
	}
	rows, e := array(v["data"])
	if e != nil {
		return "", 0, e
	}
	found := false
	for _, row := range rows {
		server, e := obj(row)
		if e != nil {
			return "", 0, e
		}
		if server["name"] == "relayDesktopR" {
			tools, e := obj(server["tools"])
			if e != nil || len(tools) != 1 || server["toolsError"] != nil {
				return "", 0, errors.New("recovered catalog must have one tool and no tools error")
			}
			found = true
			break
		}
	}
	if !found {
		return "", 0, errors.New("recovered MCP server absent")
	}
	after, e := starts(root, "healthy")
	if e != nil {
		return "", 0, e
	}
	if strings.Join(after, "\n") != strings.Join(before, "\n") {
		return "", 0, errors.New("healthy MCP process restarted")
	}
	broken, e := starts(root, "broken")
	if e != nil {
		return "", 0, e
	}
	if len(broken) < 2 {
		return "", 0, errors.New("failed MCP process was not replaced")
	}
	v, e = rpc.Call("thread/loaded/list", map[string]any{})
	if e != nil {
		return "", 0, e
	}
	loaded, e := array(v["data"])
	if e != nil || len(loaded) != 1 || loaded[0] != thread {
		return "", 0, errors.New("thread identity changed during recovery")
	}
	return thread, len(broken), nil
}
func starts(root, name string) ([]string, error) {
	raw, e := os.ReadFile(filepath.Join(root, name+".starts"))
	if e != nil {
		return nil, e
	}
	return strings.Fields(string(raw)), nil
}

type recoveryMessage struct {
	value map[string]any
	err   error
}
type recoveryRPC struct {
	input    io.Writer
	incoming chan recoveryMessage
	events   []map[string]any
	sequence int
}

func newRecoveryRPC(input io.Writer, output io.Reader) *recoveryRPC {
	r := &recoveryRPC{input: input, incoming: make(chan recoveryMessage, 4096)}
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 4096), Limit)
		for scanner.Scan() {
			var v map[string]any
			e := json.Unmarshal(scanner.Bytes(), &v)
			r.incoming <- recoveryMessage{v, e}
			if e != nil {
				return
			}
		}
		e := scanner.Err()
		if e == nil {
			e = io.EOF
		}
		r.incoming <- recoveryMessage{err: e}
	}()
	return r
}
func (r *recoveryRPC) receive(deadline time.Time) (map[string]any, error) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return nil, errors.New("native recovery fixture timed out")
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case row := <-r.incoming:
		if row.err != nil {
			return nil, row.err
		}
		if row.value["method"] == "turn/started" {
			return nil, errors.New("recovery unexpectedly started a model turn")
		}
		return row.value, nil
	case <-timer.C:
		return nil, errors.New("native recovery fixture timed out")
	}
}
func (r *recoveryRPC) remember(v map[string]any) {
	if len(r.events) == 4096 {
		copy(r.events, r.events[1:])
		r.events = r.events[:4095]
	}
	r.events = append(r.events, v)
}
func (r *recoveryRPC) Call(method string, params any) (map[string]any, error) {
	r.sequence++
	id := r.sequence
	if e := json.NewEncoder(r.input).Encode(map[string]any{"id": id, "method": method, "params": params}); e != nil {
		return nil, e
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		v, e := r.receive(deadline)
		if e != nil {
			return nil, e
		}
		if v["id"] == float64(id) {
			if _, ok := v["error"]; ok {
				return nil, errors.New("native fixture request rejected")
			}
			return obj(v["result"])
		}
		r.remember(v)
	}
}
func (r *recoveryRPC) Status(thread, server, status string, timeout time.Duration) error {
	matches := func(v map[string]any) bool {
		p, _ := v["params"].(map[string]any)
		return v["method"] == "mcpServer/startupStatus/updated" && p["threadId"] == thread && p["name"] == server && p["status"] == status
	}
	for _, v := range r.events {
		if matches(v) {
			return nil
		}
	}
	deadline := time.Now().Add(timeout)
	for {
		v, e := r.receive(deadline)
		if e != nil {
			return e
		}
		r.remember(v)
		if matches(v) {
			return nil
		}
	}
}
func FixtureHelper(args []string, input io.Reader, out io.Writer) error {
	if len(args) != 2 || args[1] != "broken" && args[1] != "healthy" {
		return errors.New("invalid private fixture helper arguments")
	}
	root, name := args[0], args[1]
	f, e := os.OpenFile(filepath.Join(root, name+".starts"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	_, e = fmt.Fprintln(f, os.Getpid())
	closeErr := f.Close()
	if e != nil {
		return e
	}
	if closeErr != nil {
		return closeErr
	}
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), Limit)
	for scanner.Scan() {
		var req map[string]any
		if e = json.Unmarshal(scanner.Bytes(), &req); e != nil {
			return e
		}
		if name == "broken" {
			if _, e = os.Stat(filepath.Join(root, "repaired")); os.IsNotExist(e) {
				return errors.New("fixture intentionally broken")
			}
		}
		id, exists := req["id"]
		if !exists || id == nil {
			continue
		}
		var result any
		switch req["method"] {
		case "initialize":
			params, _ := obj(req["params"])
			result = map[string]any{"protocolVersion": params["protocolVersion"], "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": name, "version": "1"}}
		case "tools/list":
			result = map[string]any{"tools": []any{map[string]any{"name": "fixture_read", "description": "Read-only fixture", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}, "annotations": map[string]any{"readOnlyHint": true}}}}
		case "ping":
			result = map[string]any{}
		default:
			if e = json.NewEncoder(out).Encode(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": -32601, "message": "unsupported fixture request"}}); e != nil {
				return e
			}
			continue
		}
		if e = json.NewEncoder(out).Encode(map[string]any{"jsonrpc": "2.0", "id": id, "result": result}); e != nil {
			return e
		}
	}
	return scanner.Err()
}
