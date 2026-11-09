package main

import (
	"encoding/json"
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

const waitForCommandDescription = "Wait read-only for the command in one exact Relay pane to return to the shell prompt and report its exit status, instead of sleeping and polling relay_read_viewport. Never writes to the pane or probes it. Pass after = commandGeneration from relay_send_command's result; without after it waits for the next command to finish after this call. timeout_ms defaults to 30000, at most 600000. States: returned (exit_status and generation), running (still executing at timeout), pane_exited (the pane's program ended; exit_code if known), unknown (reason: no shell integration, not a Relay shell pane, disconnected, reconnected or no command start observed). The status is shell-reported through Relay's OSC 133 integration (source shell_reported_osc133): any program in the pane can print it, so it is not verified and never authorization."

func waitForCommandTool() map[string]any {
	return tool("relay_wait_for_command", waitForCommandDescription, map[string]any{
		"pane_id":    map[string]string{"type": "string", "pattern": paneID.String()},
		"after":      map[string]any{"type": "integer", "minimum": 0, "description": "commandGeneration from relay_send_command, or a generation from an earlier wait"},
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
	deadline := time.Now().Add(args.timeout)
	after := args.after
	for {
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
