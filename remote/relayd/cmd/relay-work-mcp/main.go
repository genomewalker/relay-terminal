// relay-work-mcp is the stable native MCP transport. It retains the provider
// pipes while each request uses the currently installed qualified handler.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

var handlerPath = "/Applications/Relay.app/Contents/MacOS/relay-mcp"

const maxFrame = 1 << 20

type executor func([]byte) ([]byte, error)
type lockedOutput struct {
	mu     sync.Mutex
	writer io.Writer
}

func (o *lockedOutput) write(value []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	_, err := o.writer.Write(append(bytes.TrimSpace(value), '\n'))
	return err
}
func execute(request []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 95*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, handlerPath, "--work-request")
	// The handler proves its origin by this pipe's live writer, so the writer
	// stays open until the handler exits. The request is one newline frame.
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, errors.New("qualified Work handler unavailable; no request submitted")
	}
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		return nil, errors.New("qualified Work handler unavailable; no request submitted")
	}
	if _, err := stdin.Write(append(bytes.TrimSpace(request), '\n')); err != nil {
		_ = cmd.Wait()
		return nil, errors.New("qualified Work handler unavailable or outcome unknown; inspect the original receipt before any retry")
	}
	if err := cmd.Wait(); err != nil {
		return nil, errors.New("qualified Work handler unavailable or outcome unknown; inspect the original receipt before any retry")
	}
	if out.Len() > maxFrame || !json.Valid(bytes.TrimSpace(out.Bytes())) {
		return nil, errors.New("qualified Work response unavailable; inspect the original receipt before any retry")
	}
	return out.Bytes(), nil
}
func serve(in io.Reader, out io.Writer, run executor) error {
	writer := &lockedOutput{writer: out}
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), maxFrame)
	var lastFile os.FileInfo
	initialized := false
	for scanner.Scan() {
		raw := append([]byte(nil), scanner.Bytes()...)
		var request struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Method  string          `json:"method"`
		}
		if json.Unmarshal(raw, &request) != nil || request.JSONRPC != "2.0" {
			return errors.New("invalid native MCP frame")
		}
		if len(request.ID) == 0 {
			continue
		}
		if initialized {
			if current, err := os.Stat(handlerPath); err == nil {
				if lastFile != nil && !os.SameFile(current, lastFile) {
					if err := writer.write([]byte(`{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`)); err != nil {
						return err
					}
				}
				lastFile = current
			}
		}
		response, err := run(raw)
		if err != nil {
			response, _ = json.Marshal(map[string]any{"jsonrpc": "2.0", "id": request.ID, "error": map[string]any{"code": -32603, "message": err.Error()}})
		}
		if err := writer.write(response); err != nil {
			return err
		}
		if request.Method == "initialize" && err == nil {
			initialized = true
			lastFile, _ = os.Stat(handlerPath)
		}
	}
	return scanner.Err()
}
func main() {
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "Usage: relay-work-mcp")
		os.Exit(2)
	}
	if err := serve(os.Stdin, os.Stdout, execute); err != nil {
		fmt.Fprintln(os.Stderr, "Work MCP transport stopped:", err)
		os.Exit(1)
	}
}
