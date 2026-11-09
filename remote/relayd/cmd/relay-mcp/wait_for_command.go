package main

import (
	"context"
	"encoding/json"
	"sync"
	"time"
)

// relay_wait_for_command is read-only: Relay observes the pane's OSC 133
// command markers and never writes to the pane. The status is reported by the
// shell through the pane's output stream, so it is not verified evidence.
const (
	waitForCommandDefaultMS = 30000
	waitForCommandMaximumMS = 600000
	// Relay answers one wait request within this bound, inside the HTTP
	// client's 60 s timeout; longer waits re-issue it with the same handle.
	waitForCommandRequestMS = 50000
)

const waitForCommandDescription = "Wait read-only for the command in one exact Relay pane to return to the shell prompt and report its exit status, instead of sleeping and polling relay_read_viewport. Never writes to the pane or probes it. Call it only after relay_send_command reported the input as submitted (for example submitted_outcome_unknown), passing after = that result's commandGeneration; otherwise a later unrelated command may answer. Without after it waits for the next command to finish after this call. To wait again, pass the result's next_after. timeout_ms defaults to 30000, at most 600000. States: returned (exit_status and generation), running (still executing at timeout; may be stale after a replay or reconnect of the same transport), pane_exited (the pane's program ended; exit_code if known), unknown (reason: no shell integration, not a Relay shell pane, disconnected, reconnected or no command start observed). The status is shell-reported through Relay's OSC 133 integration (source shell_reported_osc133): any program in the pane can print it, so it is not verified and never authorization."

func waitForCommandTool() map[string]any {
	return tool("relay_wait_for_command", waitForCommandDescription, map[string]any{
		"pane_id":    map[string]string{"type": "string", "pattern": paneID.String()},
		"after":      map[string]any{"type": "integer", "minimum": 0, "description": "commandGeneration from relay_send_command, or next_after from an earlier wait"},
		"timeout_ms": map[string]any{"type": "integer", "minimum": 1, "maximum": waitForCommandMaximumMS},
	}, []string{"pane_id"})
}

type waitForCommandArgs struct {
	pane    string
	after   *uint64
	timeout time.Duration
}

func parseWaitForCommandArgs(arguments map[string]json.RawMessage) (waitForCommandArgs, bool) {
	var args waitForCommandArgs
	timeoutMS := int64(waitForCommandDefaultMS)
	for key, raw := range arguments {
		switch key {
		case "pane_id":
			if json.Unmarshal(raw, &args.pane) != nil || !paneID.MatchString(args.pane) {
				return args, false
			}
		case "after":
			var value uint64
			if json.Unmarshal(raw, &value) != nil {
				// relay_send_command reports the handle as a decimal string.
				var text string
				if json.Unmarshal(raw, &text) != nil || json.Unmarshal([]byte(text), &value) != nil || len(text) == 0 || text[0] < '0' || text[0] > '9' {
					return args, false
				}
			}
			args.after = &value
		case "timeout_ms":
			if json.Unmarshal(raw, &timeoutMS) != nil || timeoutMS < 1 || timeoutMS > waitForCommandMaximumMS {
				return args, false
			}
		default:
			return args, false
		}
	}
	args.timeout = time.Duration(timeoutMS) * time.Millisecond
	return args, args.pane != ""
}

func (s *server) waitForCommand(arguments map[string]json.RawMessage) (any, int, string) {
	args, ok := parseWaitForCommandArgs(arguments)
	if !ok {
		return nil, -32602, "Exact pane_id required; optional after (non-negative integer) and timeout_ms (1 to 600000)"
	}
	ctx := s.waitContext
	if ctx == nil {
		ctx = context.Background()
	}
	deadline := time.Now().Add(args.timeout)
	after := args.after
	for {
		if ctx.Err() != nil {
			return toolText("Wait cancelled", true), 0, ""
		}
		remaining := time.Until(deadline)
		chunk := remaining.Milliseconds()
		if chunk < 1 {
			chunk = 1
		}
		if chunk > waitForCommandRequestMS {
			chunk = waitForCommandRequestMS
		}
		request := map[string]any{"timeout_ms": chunk}
		if after != nil {
			request["after"] = *after
		}
		body, _ := json.Marshal(request)
		content, err := s.exchange("GET", "/api/panes/"+args.pane+"/command-wait", body)
		if err != nil {
			return toolText(err.Error(), true), 0, ""
		}
		var result struct {
			State string  `json:"state"`
			After *uint64 `json:"after"`
		}
		if json.Unmarshal([]byte(content), &result) != nil || result.State == "" {
			return toolText("Invalid command wait response", true), 0, ""
		}
		// Keep the first request's handle so later rounds wait for the same command.
		if after == nil {
			after = result.After
		}
		if result.State != "running" || time.Until(deadline) <= 0 || after == nil {
			return toolText(content, false), 0, ""
		}
	}
}

// inflightWaits tracks stdio relay_wait_for_command calls by JSON-RPC id so a
// notifications/cancelled or stdin EOF stops their polling.
type inflightWaits struct {
	mu      sync.Mutex
	cancels map[string]context.CancelFunc
	group   sync.WaitGroup
}

func newInflightWaits() *inflightWaits {
	return &inflightWaits{cancels: map[string]context.CancelFunc{}}
}

// canonicalID compares ids by JSON value: 7 and 7.0 match, "7" does not.
func canonicalID(raw json.RawMessage) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return string(raw)
	}
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func (w *inflightWaits) start(id json.RawMessage) (context.Context, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	key := canonicalID(id)
	if _, exists := w.cancels[key]; exists {
		return nil, false
	}
	ctx, cancel := context.WithCancel(context.Background())
	w.cancels[key] = cancel
	w.group.Add(1)
	return ctx, true
}

func (w *inflightWaits) finish(id json.RawMessage) {
	w.mu.Lock()
	key := canonicalID(id)
	if cancel, ok := w.cancels[key]; ok {
		cancel()
		delete(w.cancels, key)
	}
	w.mu.Unlock()
	w.group.Done()
}

func (w *inflightWaits) cancel(params json.RawMessage) {
	var p struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(params, &p) != nil || len(p.RequestID) == 0 {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if cancel, ok := w.cancels[canonicalID(p.RequestID)]; ok {
		cancel()
	}
}

// stopAll cancels every wait and waits for its goroutine to return.
func (w *inflightWaits) stopAll() {
	w.mu.Lock()
	for _, cancel := range w.cancels {
		cancel()
	}
	w.mu.Unlock()
	w.group.Wait()
}

func isWaitForCommandCall(r request) bool {
	if r.Method != "tools/call" {
		return false
	}
	var p struct {
		Name string `json:"name"`
	}
	return json.Unmarshal(r.Params, &p) == nil && p.Name == "relay_wait_for_command"
}
