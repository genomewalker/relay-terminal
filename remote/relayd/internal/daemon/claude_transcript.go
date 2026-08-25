package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func observeClaudeTranscript(rootPID int) (<-chan protocol.Frame, func()) {
	frames := make(chan protocol.Frame, 64)
	stopped := make(chan struct{})
	go func() {
		defer close(frames)
		timer := time.NewTimer(0)
		defer timer.Stop()
		readers := make(map[int]*claudeTranscriptReader)
		poll := func() bool {
			processes := descendantAgentProcesses(rootPID)
			for pid, agent := range processes {
				if agent != "claude" {
					continue
				}
				reader := readers[pid]
				if reader == nil {
					reader = &claudeTranscriptReader{rootPID: pid, known: make(map[string]bool), active: make(map[string]bool)}
					readers[pid] = reader
				}
				if !reader.poll(frames, stopped) {
					return false
				}
			}
			for pid := range readers {
				if processes[pid] != "claude" {
					delete(readers, pid)
				}
			}
			return true
		}
		for {
			select {
			case <-timer.C:
				if !poll() {
					return
				}
				delay := 2 * time.Second
				if len(readers) > 0 {
					delay = 250 * time.Millisecond
				}
				timer.Reset(delay)
			case <-stopped:
				return
			}
		}
	}()
	return frames, func() { close(stopped) }
}

type claudeTranscriptReader struct {
	rootPID             int
	path                string
	offset              int64
	known               map[string]bool
	active              map[string]bool
	discardingOversized bool
	identity            [2]uint64
}

func (reader *claudeTranscriptReader) poll(frames chan<- protocol.Frame, stopped <-chan struct{}) bool {
	path := reader.path
	if path == "" {
		path = claudeRootTranscript(reader.rootPID)
	}
	if path == "" {
		return true
	}
	if path != reader.path {
		reader.path = path
		reader.offset = 0
	}
	cancelled := false
	readTranscriptLines(path, &reader.offset, &reader.discardingOversized, &reader.identity, func(line []byte) {
		if cancelled {
			return
		}
		for _, event := range claudeTranscriptEvents(line) {
			identifier := transcriptEventIdentifier(event)
			if event.Event.HookEventName == "SubagentStart" {
				if reader.active[identifier] {
					continue
				}
				reader.known[identifier] = true
				reader.active[identifier] = true
			} else if event.Event.HookEventName == "SubagentStop" {
				if reader.known[identifier] && !reader.active[identifier] {
					continue
				}
				reader.known[identifier] = true
				reader.active[identifier] = false
			}
			payload, marshalErr := json.Marshal(event)
			if marshalErr == nil {
				select {
				case frames <- protocol.Frame{Type: protocol.AgentEvent, Payload: payload}:
				case <-stopped:
					cancelled = true
					return
				}
			}
		}
	})
	return !cancelled
}

func claudeTranscriptEvents(line []byte) []codexTranscriptEnvelope {
	var row struct {
		Timestamp     string `json:"timestamp"`
		Type          string `json:"type"`
		ToolUseResult struct {
			IsAsync     bool   `json:"isAsync"`
			Status      string `json:"status"`
			AgentID     string `json:"agentId"`
			Description string `json:"description"`
		} `json:"toolUseResult"`
		Message struct {
			Content any `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &row) != nil {
		return nil
	}
	if row.Type == "user" && row.ToolUseResult.AgentID != "" &&
		(row.ToolUseResult.IsAsync || row.ToolUseResult.Status == "async_launched") {
		label := strings.TrimSpace(row.ToolUseResult.Description)
		if label == "" {
			label = "Subagent"
		}
		return []codexTranscriptEnvelope{{
			Agent: "claude",
			Event: codexTranscriptEvent{
				HookEventName: "SubagentStart",
				AgentID:       row.ToolUseResult.AgentID,
				AgentType:     label,
				OccurredAt:    row.Timestamp,
				Source:        "claude-transcript",
			},
		}}
	}
	content := claudeMessageText(row.Message.Content)
	if row.Type == "assistant" {
		if events := claudePeerToolEvents(row.Message.Content, row.Timestamp); len(events) > 0 {
			return events
		}
	}
	if row.Type == "user" {
		if sender, message := claudeTeammateMessage(content); sender != "" && message != "" {
			return []codexTranscriptEnvelope{{
				Agent: "claude",
				Event: codexTranscriptEvent{
					HookEventName: "PeerMessage", AgentID: sender, AgentType: sender,
					Message: message, OccurredAt: row.Timestamp, Source: "claude-transcript",
					FromPeerID: sender, ToPeerID: "claude-root", MessageType: "message", Delivery: "async",
				},
			}}
		}
	}
	if row.Type != "user" || !strings.Contains(content, "<task-notification>") ||
		!strings.Contains(content, "<status>completed</status>") {
		return nil
	}
	identifier := xmlLikeValue(content, "task-id")
	if identifier == "" {
		return nil
	}
	label := "Subagent"
	if summary := xmlLikeValue(content, "summary"); summary != "" {
		if start := strings.Index(summary, "Agent \""); start >= 0 {
			remainder := summary[start+len("Agent \""):]
			if end := strings.Index(remainder, "\""); end >= 0 {
				label = remainder[:end]
			}
		}
	}
	return []codexTranscriptEnvelope{{
		Agent: "claude",
		Event: codexTranscriptEvent{
			HookEventName: "SubagentStop",
			AgentID:       identifier,
			AgentType:     label,
			Message:       xmlLikeValue(content, "result"),
			OccurredAt:    row.Timestamp,
			Source:        "claude-transcript",
		},
	}}
}

func claudePeerToolEvents(content any, occurredAt string) []codexTranscriptEnvelope {
	items, ok := content.([]any)
	if !ok {
		return nil
	}
	events := make([]codexTranscriptEnvelope, 0)
	for _, item := range items {
		object, ok := item.(map[string]any)
		if !ok || object["type"] != "tool_use" {
			continue
		}
		name, _ := object["name"].(string)
		if name != "SendMessage" && name != "send_message" && name != "send_message_to_thread" {
			continue
		}
		input, _ := object["input"].(map[string]any)
		recipient := firstString(input, "recipient", "target", "thread_id", "agent_id")
		message := firstString(input, "message", "content", "prompt")
		if recipient == "" || message == "" {
			continue
		}
		events = append(events, codexTranscriptEnvelope{
			Agent: "claude",
			Event: codexTranscriptEvent{
				HookEventName: "PeerMessage", AgentID: recipient, AgentType: recipient,
				Message: message, OccurredAt: occurredAt, Source: "claude-transcript",
				FromPeerID: "claude-root", ToPeerID: recipient, MessageType: "message", Delivery: "async",
			},
		})
	}
	return events
}

func firstString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func claudeTeammateMessage(content string) (string, string) {
	const marker = `<teammate-message`
	start := strings.Index(content, marker)
	if start < 0 {
		return "", ""
	}
	remainder := content[start+len(marker):]
	endTag := strings.Index(remainder, ">")
	if endTag < 0 {
		return "", ""
	}
	header := remainder[:endTag]
	sender := ""
	for _, attribute := range []string{"teammate_id", "agent_id", "sender"} {
		needle := attribute + `="`
		if index := strings.Index(header, needle); index >= 0 {
			value := header[index+len(needle):]
			if end := strings.Index(value, `"`); end >= 0 {
				sender = value[:end]
				break
			}
		}
	}
	body := remainder[endTag+1:]
	if end := strings.Index(body, "</teammate-message>"); end >= 0 {
		body = body[:end]
	}
	return strings.TrimSpace(sender), strings.TrimSpace(body)
}

func claudeMessageText(content any) string {
	switch typed := content.(type) {
	case string:
		return typed
	case []any:
		var result strings.Builder
		for _, item := range typed {
			if object, ok := item.(map[string]any); ok {
				if text, ok := object["text"].(string); ok {
					result.WriteString(text)
				}
			}
		}
		return result.String()
	default:
		return ""
	}
}

func xmlLikeValue(text, tag string) string {
	startMarker := "<" + tag + ">"
	endMarker := "</" + tag + ">"
	start := strings.Index(text, startMarker)
	if start < 0 {
		return ""
	}
	remainder := text[start+len(startMarker):]
	end := strings.Index(remainder, endMarker)
	if end < 0 {
		return ""
	}
	return strings.TrimSpace(remainder[:end])
}

func claudeRootTranscript(pid int) string {
	if entries, err := os.ReadDir(filepath.Join("/proc", strconv.Itoa(pid), "fd")); err == nil {
		type openCandidate struct {
			path    string
			updated time.Time
		}
		candidates := make([]openCandidate, 0)
		seen := make(map[string]bool)
		for _, entry := range entries {
			target, readErr := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "fd", entry.Name()))
			if readErr != nil || seen[target] || !strings.HasSuffix(target, ".jsonl") ||
				!strings.Contains(target, string(filepath.Separator)+".claude"+string(filepath.Separator)+"projects"+string(filepath.Separator)) {
				continue
			}
			seen[target] = true
			if info, statErr := os.Stat(target); statErr == nil {
				candidates = append(candidates, openCandidate{path: target, updated: info.ModTime()})
			}
		}
		sort.Slice(candidates, func(left, right int) bool { return candidates[left].updated.After(candidates[right].updated) })
		if len(candidates) > 0 {
			return candidates[0].path
		}
	}
	cwd, err := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "cwd"))
	if err != nil || cwd == "" {
		return ""
	}
	home := processEnvironmentValue(pid, "HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	projectDirectory := filepath.Join(home, ".claude", "projects", strings.ReplaceAll(cwd, string(filepath.Separator), "-"))
	paths, _ := filepath.Glob(filepath.Join(projectDirectory, "*.jsonl"))
	sort.Slice(paths, func(left, right int) bool {
		leftInfo, leftErr := os.Stat(paths[left])
		rightInfo, rightErr := os.Stat(paths[right])
		if leftErr != nil {
			return false
		}
		if rightErr != nil {
			return true
		}
		return leftInfo.ModTime().After(rightInfo.ModTime())
	})
	if len(paths) == 0 {
		return ""
	}
	return paths[0]
}

func processEnvironmentValue(pid int, name string) string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "environ"))
	if err != nil {
		return ""
	}
	prefix := name + "="
	for _, entry := range strings.Split(string(data), "\x00") {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}
	return ""
}
