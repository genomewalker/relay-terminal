// Package codexshared implements the explicitly opted-in two-client acceptance
// test. Run is the only entrypoint that launches a signed backend or links auth.
package codexshared

import (
	"context"
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

	"github.com/relay-terminal/relayd/internal/codexmcphealth"
)

const RPCTimeout = 20 * time.Second
const CollectionTimeout = 60 * time.Second
const ReadyAttempts = 100
const ReadyInterval = 50 * time.Millisecond
const TokenA = "RELAY_SHARED_A"
const TokenB = "RELAY_SHARED_B"

type Client interface {
	Send([]byte, byte) error
	Receive() (map[string]any, error)
	SetDeadline(time.Time) error
	Close() error
}

func send(c Client, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	return c.Send(b, 1)
}
func rpc(c Client, id int, method string, params any) (map[string]any, error) {
	if e := c.SetDeadline(time.Now().Add(RPCTimeout)); e != nil {
		return nil, e
	}
	if e := send(c, map[string]any{"id": id, "method": method, "params": params}); e != nil {
		return nil, e
	}
	for {
		if e := c.SetDeadline(time.Now().Add(RPCTimeout)); e != nil {
			return nil, e
		}
		v, e := c.Receive()
		if e != nil {
			return nil, e
		}
		if v["id"] == float64(id) {
			if _, bad := v["error"]; bad {
				return nil, errors.New("provider RPC rejected")
			}
			r, ok := v["result"].(map[string]any)
			if !ok {
				return nil, errors.New("provider result is not an object")
			}
			return r, nil
		}
	}
}
func nestedID(v map[string]any, key string) (string, error) {
	m, ok := v[key].(map[string]any)
	if !ok {
		return "", errors.New("missing " + key)
	}
	id, ok := m["id"].(string)
	if !ok || id == "" {
		return "", errors.New("missing " + key + " id")
	}
	return id, nil
}

// Collect checks actual completed agent items, both tokens, and terminal status.
func Collect(c Client) (string, error) {
	if e := c.SetDeadline(time.Now().Add(CollectionTimeout)); e != nil {
		return "", e
	}
	var text []string
	size := 0
	for {
		v, e := c.Receive()
		if e != nil {
			return "", e
		}
		params, _ := v["params"].(map[string]any)
		switch v["method"] {
		case "item/completed":
			item, _ := params["item"].(map[string]any)
			if item["type"] == "agentMessage" {
				s, ok := item["text"].(string)
				if !ok {
					return "", errors.New("invalid agent text")
				}
				size += len(s)
				if size > 4<<20 {
					return "", errors.New("reply exceeds limit")
				}
				text = append(text, s)
			}
		case "turn/completed":
			turn, _ := params["turn"].(map[string]any)
			if turn["status"] != "completed" {
				return "", errors.New("turn did not complete")
			}
			result := strings.Join(text, "\n")
			if !strings.Contains(result, TokenA) || !strings.Contains(result, TokenB) {
				return "", errors.New("missing reply token")
			}
			return result, nil
		}
	}
}
func Exercise(a, b Client, cwd string, out io.Writer) error {
	for _, c := range []Client{a, b} {
		if _, e := rpc(c, 1, "initialize", map[string]any{"clientInfo": map[string]any{"name": "relay_shared_test", "version": "0.1"}, "capabilities": map[string]any{"experimentalApi": true}}); e != nil {
			return e
		}
		if e := send(c, map[string]any{"method": "initialized"}); e != nil {
			return e
		}
	}
	r, e := rpc(a, 2, "thread/start", map[string]any{"cwd": cwd, "model": "gpt-6-astra", "sandbox": "read-only", "approvalPolicy": "never", "developerInstructions": "Connectivity test. Never call tools. Echo the exact contents of each external tool output, verbatim."})
	if e != nil {
		return e
	}
	thread, e := nestedID(r, "thread")
	if e != nil {
		return e
	}
	_, e = rpc(a, 10, "turn/start", map[string]any{"threadId": thread, "input": []any{map[string]any{"type": "text", "text": "We are testing message delivery. Reply READY now. For subsequent relay_peer tool outputs, echo their exact token verbatim. Never use tools."}}})
	if e != nil {
		return e
	}
	if e = a.SetDeadline(time.Now().Add(CollectionTimeout)); e != nil {
		return e
	}
	for {
		v, e := a.Receive()
		if e != nil {
			return e
		}
		if v["method"] == "turn/completed" {
			break
		}
	}
	if _, e = rpc(b, 2, "thread/resume", map[string]any{"threadId": thread}); e != nil {
		return e
	}
	turns := []string{}
	for i, c := range []Client{a, b} {
		token := []string{TokenA, TokenB}[i]
		r, e := rpc(c, 3, "turn/start", map[string]any{"threadId": thread, "input": []any{}, "toolOutput": map[string]any{"name": "relay_peer", "output": token}})
		if e != nil {
			return e
		}
		id, e := nestedID(r, "turn")
		if e != nil {
			return e
		}
		turns = append(turns, id)
	}
	if turns[0] != turns[1] {
		return errors.New("message did not join active turn")
	}
	type result struct {
		index int
		err   error
	}
	done := make(chan result, 2)
	for i, c := range []Client{a, b} {
		go func(i int, c Client) { _, e := Collect(c); done <- result{i, e} }(i, c)
	}
	var first error
	for range 2 {
		r := <-done
		if r.err != nil {
			if first == nil {
				first = r.err
			}
			a.Close()
			b.Close()
		} else {
			fmt.Fprintf(out, "PASS client %d: both reply tokens; completed notification\n", r.index)
		}
	}
	return first
}
func Run(args []string, out, errout io.Writer) error {
	fs := flag.NewFlagSet("relay-test-codex-shared", flag.ContinueOnError)
	fs.SetOutput(errout)
	live := fs.Bool("live", false, "explicitly authorize isolated live signed-backend acceptance using existing login")
	binary := fs.String("binary", os.Getenv("RELAY_TEST_CODEX_BINARY"), "installed signed Codex backend")
	if e := fs.Parse(args); e != nil {
		return e
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected arguments")
	}
	if !*live {
		return errors.New("live acceptance requires explicit --live; no provider launched")
	}
	home, e := os.UserHomeDir()
	if e != nil {
		return e
	}
	candidates := []string{*binary}
	if *binary == "" {
		candidates = []string{"/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", filepath.Join(home, ".local/bin/codex")}
	}
	selected := ""
	for _, p := range candidates {
		st, e := os.Stat(p)
		if e == nil && st.Mode().IsRegular() && syscall.Access(p, 1) == nil {
			selected = p
			break
		}
	}
	if selected == "" {
		return errors.New("no installed Codex backend; pass --binary /absolute/path/to/codex")
	}
	selected, e = filepath.Abs(selected)
	if e != nil {
		return e
	}
	tmp, e := os.MkdirTemp("/tmp", "relay-shared-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(tmp)
	if e = os.Symlink(filepath.Join(home, ".codex/auth.json"), filepath.Join(tmp, "auth.json")); e != nil {
		return e
	}
	socket := filepath.Join(tmp, "server.sock")
	cmd := exec.Command(selected, "app-server", "--listen", "unix://"+socket)
	cmd.Dir = tmp
	for _, v := range os.Environ() {
		if !strings.HasPrefix(v, "CODEX_HOME=") {
			cmd.Env = append(cmd.Env, v)
		}
	}
	cmd.Env = append(cmd.Env, "CODEX_HOME="+tmp)
	if e = cmd.Start(); e != nil {
		return e
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	exited := false
	defer func() {
		if exited {
			return
		}
		cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	}()
	ready := false
	for i := 0; i < ReadyAttempts; i++ {
		if _, e = os.Stat(socket); e == nil {
			ready = true
			break
		}
		select {
		case <-done:
			exited = true
			return errors.New("server exited before readiness")
		case <-time.After(ReadyInterval):
		}
	}
	if !ready {
		return errors.New("server socket not ready")
	}
	a, e := codexmcphealth.Dial(context.Background(), socket)
	if e != nil {
		return e
	}
	defer a.Close()
	b, e := codexmcphealth.Dial(context.Background(), socket)
	if e != nil {
		return e
	}
	defer b.Close()
	return Exercise(a, b, tmp, out)
}
