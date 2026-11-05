package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/relay-terminal/relayd/internal/workorigin"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const workRequestLimit = 1 << 20

var workLinkID = regexp.MustCompile(`^[0-9a-f]{64}$`)
var workUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var workAuthenticate = workorigin.AuthenticateWorker
var workRevalidate = func(e workorigin.Evidence) error { return e.Revalidate() }
var workDelegate = workDaemonRequest

func workTools() []any {
	defs := []struct {
		name, description string
		readonly          bool
		properties        map[string]any
		required          []string
	}{
		{"relay_work_link_status", "Inspect the exact saved pane/Work relationship and its connected, stale, recoverable or blocked state. Does not change a conversation.", true, map[string]any{"link_id": map[string]any{"type": "string"}}, []string{"link_id"}},
		{"relay_repair_work_link", "Repair only the same exact saved conversations using fresh native evidence and the expected link revision. Refuse replacements. Reconcile the original request receipt after uncertainty.", false, map[string]any{"link_id": map[string]any{"type": "string"}, "expected_revision": map[string]any{"type": "integer", "minimum": 1}, "request_id": map[string]any{"type": "string"}}, []string{"link_id", "expected_revision", "request_id"}},
		{"relay_work_message", "Send through the user's exact saved pane/Work link. Native provider metadata or kernel pane ownership establishes the sender; never supply a source identity. Keep message_id after uncertainty; never replay blindly.", false, map[string]any{"link_id": map[string]any{"type": "string"}, "message_id": map[string]any{"type": "string"}, "text": map[string]any{"type": "string", "minLength": 1, "maxLength": 16384}}, []string{"link_id", "message_id", "text"}},
		{"relay_work_receipt", "Read the original durable pane/Work message receipt. An admitted request is not proof of processing or reading.", true, map[string]any{"link_id": map[string]any{"type": "string"}, "message_id": map[string]any{"type": "string"}}, []string{"link_id", "message_id"}},
	}
	result := make([]any, 0, len(defs))
	for _, d := range defs {
		result = append(result, map[string]any{"name": d.name, "description": d.description, "inputSchema": map[string]any{"type": "object", "properties": d.properties, "required": d.required, "additionalProperties": false}, "annotations": map[string]any{"readOnlyHint": d.readonly, "destructiveHint": false, "idempotentHint": true}})
	}
	return result
}
func workPacket(name string, args map[string]json.RawMessage) (map[string]any, error) {
	operation := map[string]string{"relay_work_message": "send", "relay_work_receipt": "receipt", "relay_work_link_status": "status", "relay_repair_work_link": "repair"}[name]
	if operation == "" {
		return nil, errors.New("unknown Work tool")
	}
	allowed := map[string]bool{"link_id": true}
	switch operation {
	case "send":
		allowed["message_id"] = true
		allowed["text"] = true
	case "receipt":
		allowed["message_id"] = true
	case "repair":
		allowed["expected_revision"] = true
		allowed["request_id"] = true
	}
	if len(args) != len(allowed) {
		return nil, errors.New("invalid Work tool arguments")
	}
	p := map[string]any{"operation": operation}
	for k, raw := range args {
		if !allowed[k] {
			return nil, errors.New("unexpected Work tool argument")
		}
		if k == "expected_revision" {
			var n uint64
			if json.Unmarshal(raw, &n) != nil || n == 0 {
				return nil, errors.New("expected_revision must be positive")
			}
			p[k] = n
			continue
		}
		var v string
		if json.Unmarshal(raw, &v) != nil {
			return nil, errors.New("Work identifiers and text must be strings")
		}
		switch k {
		case "link_id":
			if !workLinkID.MatchString(v) {
				return nil, errors.New("invalid link_id")
			}
		case "message_id", "request_id":
			if !workUUID.MatchString(v) {
				return nil, errors.New("invalid request identity")
			}
		case "text":
			if len(v) == 0 || len(v) > 16384 || !utf8.ValidString(v) || strings.TrimSpace(v) == "" {
				return nil, errors.New("invalid message text")
			}
		}
		p[k] = v
	}
	return p, nil
}
func runWorkRequest(in io.Reader, out io.Writer) error {
	raw, err := readWorkFrame(in, workRequestLimit)
	if err != nil {
		return err
	}
	var r request
	if json.Unmarshal(raw, &r) != nil || r.JSONRPC != "2.0" {
		return errors.New("invalid Work MCP request")
	}
	if len(r.ID) == 0 {
		return nil
	}
	result, code, detail := handleWorkRequest(r)
	response := map[string]any{"jsonrpc": "2.0", "id": r.ID}
	if code != 0 {
		response["error"] = map[string]any{"code": code, "message": detail}
	} else {
		response["result"] = result
	}
	return json.NewEncoder(out).Encode(response)
}
func handleWorkRequest(r request) (any, int, string) {
	switch r.Method {
	case "initialize":
		return map[string]any{"protocolVersion": "2024-11-05", "capabilities": map[string]any{"tools": map[string]any{"listChanged": true}}, "serverInfo": map[string]any{"name": "relay-work", "version": "1"}}, 0, ""
	case "ping":
		return map[string]any{}, 0, ""
	case "tools/list":
		return map[string]any{"tools": workTools()}, 0, ""
	case "tools/call":
		var p struct {
			Name      string                     `json:"name"`
			Arguments map[string]json.RawMessage `json:"arguments"`
			Meta      map[string]json.RawMessage `json:"_meta"`
		}
		if json.Unmarshal(r.Params, &p) != nil {
			return nil, -32602, "invalid Work call"
		}
		packet, err := workPacket(p.Name, p.Arguments)
		if err != nil {
			return nil, -32602, err.Error()
		}
		var thread string
		if json.Unmarshal(p.Meta["threadId"], &thread) == nil && workUUID.MatchString(thread) {
			if source, e := workAuthenticate(os.Getpid(), thread); e == nil {
				if e = workRevalidate(source.Transport); e != nil {
					return workToolError("Native Work transport changed; no request submitted."), 0, ""
				}
				packet["protected_thread_id"] = source.Thread
			}
		}
		// A missing Work origin may still be a real native pane or separately
		// authorized Miko actor. The daemon verifies that actor independently.
		if token := os.Getenv("RELAY_MCP_CALLER_TOKEN"); token != "" {
			if len(token) > 200 {
				return nil, -32602, "invalid native client credential"
			}
			packet["client_token"] = token
		}
		result, err := workDelegate(packet)
		if err != nil {
			return workToolError(err.Error()), 0, ""
		}
		return map[string]any{"content": []map[string]any{{"type": "text", "text": string(result)}}}, 0, ""
	default:
		return nil, -32601, "unknown Work MCP method"
	}
}
func workToolError(text string) any {
	return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": true}
}
func workDaemonRequest(packet map[string]any) ([]byte, error) {
	payload, err := json.Marshal(packet)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 70*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, workorigin.CLIPath, "communication-work")
	// Keep the writer open for the CLI's lifetime: the CLI proves its caller by
	// this pipe's live writer. The CLI reads exactly one newline-framed request.
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("Native Work request not submitted: %v", err)
	}
	if _, err := stdin.Write(append(payload, '\n')); err != nil {
		_ = cmd.Wait()
		return nil, errors.New("Native Work request failed or outcome unknown; reconcile the original ID.")
	}
	if err := cmd.Wait(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if len(message) > 300 {
			message = message[:300]
		}
		return nil, fmt.Errorf("Native Work request failed or outcome unknown; reconcile the original ID. %s", message)
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return nil, errors.New("Native Work result unavailable; reconcile the original ID, do not replay")
	}
	return out.Bytes(), nil
}

// readWorkFrame reads one request terminated by newline or EOF. It must not
// wait for EOF: the frontend keeps its writer open so the origin proof holds.
func readWorkFrame(in io.Reader, limit int) ([]byte, error) {
	data := make([]byte, 0, 4096)
	var b [1]byte
	for {
		n, err := in.Read(b[:])
		if n == 1 {
			if b[0] == '\n' {
				return data, nil
			}
			if len(data) >= limit {
				return nil, errors.New("Work MCP request exceeds limit")
			}
			data = append(data, b[0])
		}
		if err == io.EOF {
			return data, nil
		}
		if err != nil {
			return nil, err
		}
	}
}
