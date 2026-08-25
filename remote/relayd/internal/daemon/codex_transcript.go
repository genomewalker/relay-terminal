package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// observeCodexTranscript recovers structured collaboration events from Codex's
// append-only session log. This also works for Codex processes started before
// Relay's hooks were installed because the supervisor observes the process from
// outside the durable pane worker.
func observeCodexTranscript(rootPID int) (<-chan protocol.Frame, func()) {
	frames := make(chan protocol.Frame, 64)
	stopped := make(chan struct{})
	go func() {
		defer close(frames)
		timer := time.NewTimer(0)
		defer timer.Stop()
		readers := make(map[int]*codexTranscriptReader)
		poll := func() bool {
			processes := descendantAgentProcesses(rootPID)
			for pid, agent := range processes {
				if agent != "codex" {
					continue
				}
				reader := readers[pid]
				if reader == nil {
					reader = &codexTranscriptReader{rootPID: pid, known: make(map[string]bool), active: make(map[string]bool)}
					readers[pid] = reader
				}
				if !reader.poll(frames, stopped) {
					return false
				}
			}
			for pid := range readers {
				if processes[pid] != "codex" {
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

type codexTranscriptReader struct {
	rootPID             int
	path                string
	offset              int64
	known               map[string]bool
	active              map[string]bool
	discardingOversized bool
	identity            [2]uint64
}

func (reader *codexTranscriptReader) poll(frames chan<- protocol.Frame, stopped <-chan struct{}) bool {
	path := reader.path
	if path == "" {
		path = codexRootTranscript(reader.rootPID)
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
	HookEventName string `json:"hook_event_name"`
	AgentID       string `json:"agent_id"`
	AgentType     string `json:"agent_type,omitempty"`
	ThreadID      string `json:"thread_id,omitempty"`
	Message       string `json:"message,omitempty"`
	OccurredAt    string `json:"occurred_at,omitempty"`
	Source        string `json:"source"`
	FromPeerID    string `json:"from_peer_id,omitempty"`
	ToPeerID      string `json:"to_peer_id,omitempty"`
	MessageType   string `json:"message_type,omitempty"`
	Delivery      string `json:"delivery,omitempty"`
	Status        string `json:"status,omitempty"`
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
	entries, err := os.ReadDir(filepath.Join("/proc", strconv.Itoa(pid), "fd"))
	if err != nil {
		return ""
	}
	type candidate struct {
		path    string
		updated time.Time
		root    bool
	}
	candidates := make([]candidate, 0, len(entries))
	seen := make(map[string]bool)
	for _, entry := range entries {
		target, readErr := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "fd", entry.Name()))
		if readErr != nil || seen[target] || !strings.HasSuffix(target, ".jsonl") ||
			!strings.Contains(target, string(filepath.Separator)+".codex"+string(filepath.Separator)+"sessions"+string(filepath.Separator)) {
			continue
		}
		seen[target] = true
		info, statErr := os.Stat(target)
		if statErr != nil {
			continue
		}
		candidates = append(candidates, candidate{
			path: target, updated: info.ModTime(), root: codexTranscriptIsRoot(target),
		})
	}
	sort.Slice(candidates, func(left, right int) bool {
		if candidates[left].root != candidates[right].root {
			return candidates[left].root
		}
		return candidates[left].updated.After(candidates[right].updated)
	})
	if len(candidates) == 0 {
		return ""
	}
	return candidates[0].path
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
