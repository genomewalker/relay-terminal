package daemon

import (
	"bufio"
	"encoding/json"
	"io"
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
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		reader := claudeTranscriptReader{
			rootPID: rootPID,
			known:   make(map[string]bool),
			active:  make(map[string]bool),
		}
		reader.poll(frames)
		for {
			select {
			case <-ticker.C:
				reader.poll(frames)
			case <-stopped:
				return
			}
		}
	}()
	return frames, func() { close(stopped) }
}

type claudeTranscriptReader struct {
	rootPID int
	path    string
	offset  int64
	known   map[string]bool
	active  map[string]bool
}

func (reader *claudeTranscriptReader) poll(frames chan<- protocol.Frame) {
	agent, pid := descendantAgentProcess(reader.rootPID)
	if agent != "claude" || pid == 0 {
		return
	}
	path := reader.path
	if path == "" {
		path = claudeRootTranscript(pid)
	}
	if path == "" {
		return
	}
	if path != reader.path {
		reader.path = path
		reader.offset = 0
	}
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	if _, err := file.Seek(reader.offset, io.SeekStart); err != nil {
		return
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 8<<20)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		reader.offset += int64(len(line) + 1)
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
				frames <- protocol.Frame{Type: protocol.AgentEvent, Payload: payload}
			}
		}
	}
}

func claudeTranscriptEvents(line []byte) []codexTranscriptEnvelope {
	var row struct {
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
				Source:        "claude-transcript",
			},
		}}
	}
	content := claudeMessageText(row.Message.Content)
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
			Source:        "claude-transcript",
		},
	}}
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
