package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type codexTranscriptReader struct {
	rootPID             int
	rootStart           uint64
	path                string
	offset              int64
	known               map[string]bool
	active              map[string]bool
	discardingOversized bool
	identity            [2]uint64
}

func (reader *codexTranscriptReader) poll(frames chan<- protocol.Frame, stopped <-chan struct{}) bool {
	path := codexRootTranscript(reader.rootPID)
	if path != reader.path {
		reader.path = path
		reader.offset = 0
		reader.identity = [2]uint64{}
		reader.discardingOversized = false
		reader.known = make(map[string]bool)
		reader.active = make(map[string]bool)
	}
	if path == "" {
		return true
	}
	cancelled := false
	readTranscriptLines(path, &reader.offset, &reader.discardingOversized, &reader.identity, func(line []byte) {
		if cancelled {
			return
		}
		// Do not emit buffered activity after the producer exited or PID reuse.
		start, err := processStartTime(reader.rootPID)
		if err != nil || start != reader.rootStart {
			return
		}
		for _, event := range codexTranscriptEvents(line) {
			identifier := transcriptEventIdentifier(event)
			if identifier == "" {
				continue
			}
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

type codexTranscriptEnvelope struct {
	Agent string               `json:"agent"`
	Event codexTranscriptEvent `json:"event"`
}

type codexTranscriptEvent struct {
	Plan          []taskPlanStep `json:"plan"`
	HookEventName string         `json:"hook_event_name"`
	AgentID       string         `json:"agent_id"`
	AgentType     string         `json:"agent_type,omitempty"`
	ThreadID      string         `json:"thread_id,omitempty"`
	Message       string         `json:"message,omitempty"`
	OccurredAt    string         `json:"occurred_at,omitempty"`
	Source        string         `json:"source"`
	FromPeerID    string         `json:"from_peer_id,omitempty"`
	ToPeerID      string         `json:"to_peer_id,omitempty"`
	MessageType   string         `json:"message_type,omitempty"`
	Delivery      string         `json:"delivery,omitempty"`
	Status        string         `json:"status,omitempty"`
}

func transcriptEventIdentifier(event codexTranscriptEnvelope) string {
	if event.Event.AgentID != "" {
		return event.Event.AgentID
	}
	return event.Event.ThreadID
}

func codexTranscriptEvents(line []byte) []codexTranscriptEnvelope {
	var row struct {
		Timestamp string          `json:"timestamp"`
		Type      string          `json:"type"`
		Payload   json.RawMessage `json:"payload"`
	}
	if json.Unmarshal(line, &row) != nil {
		return nil
	}
	if row.Type == "event_msg" {
		var plan struct {
			Type     string         `json:"type"`
			Plan     []taskPlanStep `json:"plan"`
			ThreadID string         `json:"thread_id"`
		}
		if json.Unmarshal(row.Payload, &plan) == nil && plan.Type == "plan_update" && validTaskPlan(plan.Plan) {
			owner := plan.ThreadID
			if owner == "" {
				owner = "root"
			}
			return []codexTranscriptEnvelope{{Agent: "codex", Event: codexTranscriptEvent{
				HookEventName: "PlanUpdated", AgentID: owner, ThreadID: plan.ThreadID,
				OccurredAt: row.Timestamp, Source: "codex-transcript", Plan: plan.Plan,
			}}}
		}
	}
	switch row.Type {
	case "event_msg":
		var payload struct {
			Type string `json:"type"`
			Item struct {
				Type          string `json:"type"`
				Kind          string `json:"kind"`
				ID            string `json:"id"`
				AgentPath     string `json:"agent_path"`
				AgentThreadID string `json:"agent_thread_id"`
			} `json:"item"`
		}
		if json.Unmarshal(row.Payload, &payload) != nil ||
			payload.Type != "item_completed" || payload.Item.Type != "SubAgentActivity" ||
			payload.Item.AgentPath == "" {
			return nil
		}
		eventName := ""
		status := ""
		switch strings.ToLower(payload.Item.Kind) {
		case "started":
			eventName = "SubagentStart"
		case "interacted":
			eventName = "PeerInteraction"
		case "interrupted":
			eventName = "SubagentStop"
			status = "interrupted"
		default:
			return nil
		}
		return []codexTranscriptEnvelope{{
			Agent: "codex",
			Event: codexTranscriptEvent{
				HookEventName: eventName,
				AgentID:       payload.Item.AgentPath,
				AgentType:     filepath.Base(payload.Item.AgentPath),
				ThreadID:      payload.Item.AgentThreadID,
				OccurredAt:    row.Timestamp,
				Source:        "codex-transcript",
				Status:        status,
			},
		}}
	case "response_item":
		var payload struct {
			Type      string                   `json:"type"`
			Author    string                   `json:"author"`
			Recipient string                   `json:"recipient"`
			Content   []codexTranscriptContent `json:"content"`
		}
		if json.Unmarshal(row.Payload, &payload) != nil || payload.Type != "agent_message" ||
			payload.Author == "" || payload.Recipient == "" {
			return nil
		}
		finalAnswer := false
		messages := make([]string, 0, len(payload.Content))
		messageType := "message"
		for _, content := range payload.Content {
			if strings.Contains(content.Text, "Message Type: FINAL_ANSWER") {
				finalAnswer = true
				messageType = "final_answer"
			}
			if message := codexCollaboratorMessage(content.Text); message != "" {
				messages = append(messages, message)
			}
		}
		progressMessage := strings.Join(messages, "\n")
		events := make([]codexTranscriptEnvelope, 0, 2)
		if progressMessage != "" {
			events = append(events, codexTranscriptEnvelope{
				Agent: "codex",
				Event: codexTranscriptEvent{
					HookEventName: "PeerMessage",
					AgentID:       payload.Author,
					AgentType:     filepath.Base(payload.Author),
					Message:       progressMessage,
					OccurredAt:    row.Timestamp,
					Source:        "codex-transcript",
					FromPeerID:    payload.Author,
					ToPeerID:      payload.Recipient,
					MessageType:   messageType,
					Delivery:      "async",
				},
			})
		}
		if finalAnswer && strings.HasPrefix(payload.Author, payload.Recipient+"/") {
			events = append(events, codexTranscriptEnvelope{
				Agent: "codex",
				Event: codexTranscriptEvent{
					HookEventName: "SubagentStop",
					AgentID:       payload.Author,
					AgentType:     filepath.Base(payload.Author),
					OccurredAt:    row.Timestamp,
					Source:        "codex-transcript",
				},
			})
		}
		return events
	}
	return nil
}

type taskPlanStep struct {
	Step   string `json:"step"`
	Status string `json:"status"`
}

func validTaskPlan(steps []taskPlanStep) bool {
	if steps == nil || len(steps) > 100 {
		return false
	}
	for _, step := range steps {
		if strings.TrimSpace(step.Step) == "" || len(step.Step) > 2048 {
			return false
		}
		switch step.Status {
		case "pending", "in_progress", "completed":
		default:
			return false
		}
	}
	return true
}

type codexTranscriptContent struct {
	Text string `json:"text"`
}

func codexCollaboratorMessage(text string) string {
	const payloadMarker = "Payload:\n"
	if index := strings.Index(text, payloadMarker); index >= 0 {
		message := text[index+len(payloadMarker):]
		for _, marker := range []string{"\n  hook context:", "\nhook context:"} {
			if context := strings.Index(message, marker); context >= 0 {
				message = message[:context]
			}
		}
		return strings.TrimSpace(message)
	}
	if strings.Contains(text, "Message Type:") {
		return ""
	}
	return strings.TrimSpace(text)
}

func codexRootTranscript(pid int) string {
	return uniqueOpenProviderTranscript(pid, ".codex", "sessions", true)
}

// Exact open-descriptor discovery deliberately fails closed on ambiguity.
func uniqueOpenProviderTranscript(pid int, provider, directory string, requireRoot bool) string {
	start, err := processStartTime(pid)
	if err != nil || start == 0 {
		return ""
	}
	fdDirectory := filepath.Join("/proc", strconv.Itoa(pid), "fd")
	entries, err := os.ReadDir(fdDirectory)
	if err != nil || len(entries) > 16384 {
		return ""
	}
	seen := make(map[string]bool)
	selected := ""
	marker := string(filepath.Separator) + provider + string(filepath.Separator) + directory + string(filepath.Separator)
	// A process on a non-default account (CLAUDE_CONFIG_DIR or CODEX_HOME)
	// matches only below its own account directory, by logical or real path.
	var prefixes []string
	if override, err := agentConfigOverride(pid, strings.TrimPrefix(provider, ".")); err == nil && override != "" {
		prefixes = append(prefixes, filepath.Join(override, directory)+string(filepath.Separator))
		if real, err := filepath.EvalSymlinks(override); err == nil && real != override {
			prefixes = append(prefixes, filepath.Join(real, directory)+string(filepath.Separator))
		}
	}
	inNamespace := func(target string) bool {
		if prefixes == nil {
			return strings.Contains(target, marker)
		}
		for _, prefix := range prefixes {
			if strings.HasPrefix(target, prefix) {
				return true
			}
		}
		return false
	}
	for _, entry := range entries {
		target, readErr := os.Readlink(filepath.Join(fdDirectory, entry.Name()))
		if readErr != nil || seen[target] || !strings.HasSuffix(target, ".jsonl") || !inNamespace(target) {
			continue
		}
		seen[target] = true
		info, statErr := os.Lstat(target)
		if statErr != nil || !info.Mode().IsRegular() {
			continue
		}
		if requireRoot && !codexTranscriptIsRoot(target) {
			continue
		}
		if selected != "" {
			return ""
		}
		selected = target
	}
	current, err := processStartTime(pid)
	if err != nil || current != start {
		return ""
	}
	return selected
}

func codexTranscriptIsRoot(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	reader := bufio.NewReaderSize(file, 64<<10)
	line, err := reader.ReadBytes('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false
	}
	var row struct {
		Type    string `json:"type"`
		Payload struct {
			ThreadSource string `json:"thread_source"`
		} `json:"payload"`
	}
	return json.Unmarshal(line, &row) == nil && row.Type == "session_meta" && row.Payload.ThreadSource == "user"
}
