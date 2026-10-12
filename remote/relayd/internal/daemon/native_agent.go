package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// CanonicalAgentEnvelope projects provider-native JSONL/JSON-RPC events onto a
// small versioned event model. It intentionally does not retain arbitrary
// request arguments, prompts, command output, or assistant text.
func CanonicalAgentEnvelope(provider string, raw []byte, source string) ([]byte, error) {
	var input map[string]any
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, err
	}
	provider = strings.ToLower(strings.TrimSpace(provider))
	if provider == "" {
		provider = "unknown"
	}
	event := canonicalNativeEvent(provider, input)
	// JSON-RPC IDs belong to the outer request, not params.approvalId. Read
	// them as raw JSON so large integer IDs survive without float conversion.
	if provider == "codex" {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				RequestID json.RawMessage `json:"requestId"`
			} `json:"params"`
		}
		if json.Unmarshal(raw, &frame) == nil {
			var id json.RawMessage
			switch frame.Method {
			case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
				id = frame.ID
			case "serverRequest/resolved":
				id = frame.Params.RequestID
			}
			if key, ok := codexRequestID(id); ok {
				event["approval_id"] = key
			}
		}
	}
	event["source"] = source
	if _, ok := event["occurred_at"]; !ok {
		event["occurred_at"] = time.Now().UTC().Format(time.RFC3339Nano)
	}
	return json.Marshal(map[string]any{
		"schema_version": 1,
		"agent":          provider, "provider": provider, "source": source, "event": event,
	})
}

func canonicalNativeEvent(provider string, input map[string]any) map[string]any {
	if input["hook_event_name"] != nil || input["event_type"] != nil {
		event := copyAgentMetadata(input)
		if provider == "claude" && input["hook_event_name"] == "PostToolUse" && (input["tool_name"] == "TaskCreate" || input["tool_name"] == "TaskUpdate") {
			arguments, _ := input["tool_input"].(map[string]any)
			response, _ := input["tool_response"].(map[string]any)
			task, _ := response["task"].(map[string]any)
			id, _ := task["id"].(string)
			if id == "" {
				id, _ = arguments["taskId"].(string)
			}
			subject, _ := task["subject"].(string)
			if subject == "" {
				subject, _ = arguments["subject"].(string)
			}
			status, _ := task["status"].(string)
			if status == "" {
				status, _ = arguments["status"].(string)
			}
			if input["tool_name"] == "TaskCreate" && status == "" {
				status = "pending"
			}
			if id != "" && len(id) <= 256 && len(subject) <= 2048 && (status == "" || status == "pending" || status == "in_progress" || status == "completed" || status == "deleted") {
				event["hook_event_name"] = "TaskChanged"
				event["task_id"], event["task_subject"], event["task_status"] = id, subject, status
			}
		}
		if input["hook_event_name"] == "PostToolUse" && input["tool_name"] == "TodoWrite" {
			arguments, _ := input["tool_input"].(map[string]any)
			if rows, ok := arguments["todos"].([]any); ok && len(rows) <= 100 {
				steps := make([]taskPlanStep, 0, len(rows))
				for _, row := range rows {
					entry, _ := row.(map[string]any)
					text, _ := entry["content"].(string)
					status, _ := entry["status"].(string)
					steps = append(steps, taskPlanStep{Step: text, Status: status})
				}
				if validTaskPlan(steps) {
					event["hook_event_name"] = "PlanUpdated"
					event["plan"] = steps
				}
			}
		}
		return event
	}
	method, _ := input["method"].(string)
	params, _ := input["params"].(map[string]any)
	if params == nil {
		params = input
	}
	event := copyAgentMetadata(params)
	event["type"] = method
	event["provider_event"] = method
	copyStringAlias(event, params, "thread_id", "threadId", "session_id", "sessionId")
	copyStringAlias(event, params, "turn_id", "turnId")
	copyStringAlias(event, params, "item_id", "itemId")
	copyStringAlias(event, params, "approval_id", "approvalId")
	if thread, ok := params["thread"].(map[string]any); ok {
		copyStringAlias(event, thread, "thread_id", "id")
	}

	if item, ok := params["item"].(map[string]any); ok {
		copyStringAlias(event, item, "item_id", "id")
		copyStringAlias(event, item, "tool_name", "tool", "type")
		copyStringAlias(event, item, "status", "status")
		copyStringAlias(event, item, "from_peer_id", "senderThreadId")
		if receivers, ok := item["receiverThreadIds"].([]any); ok && len(receivers) > 0 {
			if receiver, ok := receivers[0].(string); ok {
				event["to_peer_id"] = receiver
				event["agent_id"] = receiver
			}
		}
	}

	switch method {
	case "thread/started":
		event["hook_event_name"] = "SessionStart"
	case "thread/status/changed":
		event["hook_event_name"] = "ThreadStatus"
	case "turn/started":
		event["hook_event_name"] = "turn/started"
	case "turn/completed":
		event["hook_event_name"] = "turn/completed"
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
		event["hook_event_name"] = "PermissionRequest"
	case "serverRequest/resolved":
		event["hook_event_name"] = "PermissionResolved"
	case "turn/plan/updated":
		event["hook_event_name"] = "PlanUpdated"
		if rows, ok := params["plan"].([]any); ok && len(rows) <= 100 {
			steps := make([]taskPlanStep, 0, len(rows))
			for _, row := range rows {
				entry, _ := row.(map[string]any)
				text, _ := entry["step"].(string)
				status, _ := entry["status"].(string)
				if status == "inProgress" {
					status = "in_progress"
				}
				steps = append(steps, taskPlanStep{Step: text, Status: status})
			}
			if validTaskPlan(steps) {
				event["plan"] = steps
			}
		}
	case "item/mcpToolCall/progress":
		event["hook_event_name"] = "AgentProgress"
	case "thread/tokenUsage/updated":
		event["hook_event_name"] = "ResourceUsage"
		if usage, ok := params["tokenUsage"].(map[string]any); ok {
			if total, ok := usage["total"].(map[string]any); ok {
				copyNumberAlias(event, total, "input_tokens", "inputTokens")
				copyNumberAlias(event, total, "cached_input_tokens", "cachedInputTokens")
				copyNumberAlias(event, total, "output_tokens", "outputTokens")
			}
		}
	case "turn/diff/updated":
		event["hook_event_name"] = "ArtifactUpdate"
		event["artifact_type"] = "diff"
	case "item/started", "item/completed":
		item, _ := params["item"].(map[string]any)
		itemType, _ := item["type"].(string)
		tool, _ := item["tool"].(string)
		completed := method == "item/completed"
		if itemType == "collabAgentToolCall" {
			switch tool {
			case "spawnAgent":
				if completed {
					event["hook_event_name"] = "SubagentUpdate"
					if states, ok := item["agentsStates"].(map[string]any); ok {
						if target, ok := event["agent_id"].(string); ok {
							if state, ok := states[target].(map[string]any); ok {
								copyStringAlias(event, state, "status", "status")
								if terminalAgentStatus(event["status"]) {
									event["hook_event_name"] = "SubagentStop"
								}
							}
						}
					}
				} else {
					event["hook_event_name"] = "SubagentStart"
				}
			case "sendInput":
				if completed {
					event["hook_event_name"] = "PeerInteraction"
				} else {
					event["hook_event_name"] = "PeerMessage"
					if message, ok := item["prompt"].(string); ok {
						event["message"] = boundedAgentString(message, 16_384)
					}
				}
			default:
				event["hook_event_name"] = "PeerInteraction"
			}
		} else if completed {
			event["hook_event_name"] = "PostToolUse"
		} else {
			event["hook_event_name"] = "PreToolUse"
		}
	default:
		if provider == "claude" {
			canonicalizeClaudeStreamEvent(event, input)
		}
	}
	return event
}

func terminalAgentStatus(value any) bool {
	status, _ := value.(string)
	switch strings.ToLower(status) {
	case "completed", "errored", "error", "interrupted", "shutdown", "notfound", "not_found":
		return true
	default:
		return false
	}
}

func boundedAgentString(value string, limit int) string {
	runes := []rune(value)
	if len(runes) > limit {
		runes = runes[:limit]
	}
	return string(runes)
}

func canonicalizeClaudeStreamEvent(event map[string]any, input map[string]any) {
	typeName, _ := input["type"].(string)
	event["type"] = typeName
	switch typeName {
	case "system":
		event["hook_event_name"] = "SessionStart"
	case "result":
		event["hook_event_name"] = "turn/completed"
	case "assistant", "stream_event":
		event["hook_event_name"] = "AgentProgress"
	}
}

func copyAgentMetadata(input map[string]any) map[string]any {
	allowed := map[string]bool{
		"hook_event_name": true, "event_type": true, "type": true, "tool_name": true,
		"notification_type": true, "message": true, "agent_id": true, "subagent_id": true,
		"agent_type": true, "thread_id": true, "turn_id": true, "item_id": true,
		"root_id": true, "occurred_at": true, "status": true, "from_peer_id": true,
		"to_peer_id": true, "message_type": true, "delivery": true, "approval_id": true,
		"progress_percent": true, "artifact_type": true, "input_tokens": true,
		"cached_input_tokens": true, "output_tokens": true,
		"task_id": true, "task_subject": true, "task_status": true,
	}
	result := make(map[string]any)
	for key, value := range input {
		if allowed[key] {
			result[key] = value
		}
	}
	return result
}

func copyStringAlias(output, input map[string]any, destination string, candidates ...string) {
	for _, candidate := range candidates {
		if value, ok := input[candidate].(string); ok && value != "" {
			output[destination] = value
			return
		}
	}
}

func copyNumberAlias(output, input map[string]any, destination string, candidates ...string) {
	for _, candidate := range candidates {
		if value, ok := input[candidate].(float64); ok {
			output[destination] = value
			return
		}
	}
}

func ValidateNativeAgentSource(source string) error {
	switch source {
	case "hook", "codex-app-server", "claude-stream-json", "provider-native":
		return nil
	default:
		return fmt.Errorf("unsupported agent event source %q", source)
	}
}

// canonical request IDs for observed provider events.
func codexRequestID(raw json.RawMessage) (string, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || len(raw) > 512 {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if s == "" {
			return "", false
		}
		encoded, _ := json.Marshal(s)
		return string(encoded), true
	}
	for i, b := range raw {
		if b == '-' && i == 0 {
			continue
		}
		if b < '0' || b > '9' {
			return "", false
		}
	}
	if !json.Valid(raw) {
		return "", false
	}
	return string(raw), true
}
