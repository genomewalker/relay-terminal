// relay-codex-session owns a Codex app-server child. Its stdin is a trusted local
// transport boundary, not a public listener. One JSON Message per line enters;
// JSON-RPC responses and notifications leave stdout. No automatic replay.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"

	"github.com/relay-terminal/relayd/internal/codexsession"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	binary := flag.String("codex", "", "Explicit path to official Codex executable")
	cwd := flag.String("cwd", "", "Session working directory")
	flag.Parse()
	if *binary == "" || *cwd == "" {
		return fmt.Errorf("--codex and --cwd are required")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	cmd := exec.CommandContext(ctx, *binary, "app-server", "--stdio")
	cmd.Dir = *cwd
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err = cmd.Start(); err != nil {
		return err
	}
	defer func() { cancel(); in.Close(); _ = cmd.Wait() }()
	var outputMu sync.Mutex
	emit := func(v any) { outputMu.Lock(); defer outputMu.Unlock(); _ = json.NewEncoder(os.Stdout).Encode(v) }
	replies := make(chan map[string]json.RawMessage, 8)
	go func() {
		defer close(replies)
		s := bufio.NewScanner(out)
		s.Buffer(make([]byte, 4096), 4<<20)
		for s.Scan() {
			var r map[string]json.RawMessage
			if json.Unmarshal(s.Bytes(), &r) != nil {
				cancel()
				return
			}
			// Never approve server requests automatically.
			if r["method"] != nil && r["id"] != nil {
				emit(map[string]any{"error": "unexpected server request; session stopped"})
				cancel()
				return
			}
			if r["id"] != nil {
				select {
				case replies <- r:
				case <-ctx.Done():
					return
				}
			} else {
				emit(r)
			}
		}
		cancel()
	}()
	seq := 0
	call := func(method string, params any) (map[string]json.RawMessage, error) {
		seq++
		if err := json.NewEncoder(in).Encode(map[string]any{"id": seq, "method": method, "params": params}); err != nil {
			return nil, err
		}
		select {
		case r, ok := <-replies:
			if !ok {
				return nil, fmt.Errorf("Codex disconnected; delivery may be ambiguous")
			}
			if r["error"] != nil {
				return nil, fmt.Errorf("Codex rejected request: %s", r["error"])
			}
			return r, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if _, err = call("initialize", map[string]any{"clientInfo": map[string]string{"name": "relay_codex_session", "version": "0.1"}}); err != nil {
		return err
	}
	r, err := call("thread/start", map[string]any{"cwd": *cwd, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true})
	if err != nil {
		return err
	}
	var result struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if err = json.Unmarshal(r["result"], &result); err != nil {
		return err
	}
	if result.Thread.ID == "" {
		return fmt.Errorf("missing owned thread id")
	}
	emit(map[string]string{"type": "ready", "threadId": result.Thread.ID})
	s := bufio.NewScanner(os.Stdin)
	s.Buffer(make([]byte, 4096), codexsession.MaxMessageBytes+1)
	for s.Scan() {
		var m codexsession.Message
		if err := json.Unmarshal(s.Bytes(), &m); err != nil {
			return err
		}
		params, err := codexsession.TurnParams(result.Thread.ID, m)
		if err != nil {
			return err
		}
		r, err := call("turn/start", params)
		if err != nil {
			return err
		}
		emit(map[string]any{"type": "admitted", "messageId": m.ID, "response": r})
	}
	return s.Err()
}
