package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/relay-terminal/relayd/internal/protocol"
)

const replayLimit = 8 << 20

type record struct {
	sequence  uint64
	data      []byte
	artifacts []protocol.Frame
}

type client struct {
	frames chan protocol.Frame
}

type Session struct {
	id      string
	command string
	pty     *os.File
	process *exec.Cmd

	mu               sync.Mutex
	sequence         uint64
	replay           []record
	replayBytes      int
	clients          map[*client]struct{}
	agentClients     map[*client]struct{}
	exited           bool
	exitCode         int
	latestAgentEvent []byte
	activeSubagents  map[string][]byte
	artifactDetector artifactDetector
	done             chan struct{}
}

func startSession(id, command, workingDirectory string, cols, rows uint16) (*Session, error) {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	shimPath := filepath.Join(home, ".local", "share", "relay", "shims")
	child, err := sessionCommand(shell, command, home, shimPath)
	if err != nil {
		return nil, err
	}
	if workingDirectory != "" {
		child.Dir = workingDirectory
	}
	child.Env = environmentWithOverrides(os.Environ(), map[string]string{
		"TERM":          "xterm-256color",
		"COLORTERM":     "truecolor",
		"RELAY_SESSION": id,
		"PATH":          shimPath + string(os.PathListSeparator) + os.Getenv("PATH"),
	})
	if cols == 0 {
		cols = 120
	}
	if rows == 0 {
		rows = 36
	}
	terminal, err := pty.StartWithSize(child, &pty.Winsize{Cols: cols, Rows: rows})
	if err != nil {
		return nil, err
	}
	session := &Session{
		id: id, command: command, pty: terminal, process: child,
		clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), done: make(chan struct{}),
	}
	go session.readOutput()
	go session.wait()
	go session.monitorAgentProcesses()
	return session, nil
}

func sessionCommand(shell, command, home, shimPath string) (*exec.Cmd, error) {
	if command != "" {
		wrapped := "export PATH=" + shellQuote(shimPath) + ":$PATH; hash -r 2>/dev/null || true; " + command
		return exec.Command(shell, "-lc", wrapped), nil
	}

	switch filepath.Base(shell) {
	case "bash":
		rcPath, err := writeBashIntegration(home, shimPath)
		if err != nil {
			return nil, err
		}
		launch := "exec " + shellQuote(shell) + " --rcfile " + shellQuote(rcPath) + " -i"
		return exec.Command(shell, "-l", "-c", launch), nil
	case "zsh":
		zdotDirectory, err := writeZshIntegration(home, shimPath)
		if err != nil {
			return nil, err
		}
		launch := "export RELAY_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"; export ZDOTDIR=" +
			shellQuote(zdotDirectory) + "; exec " + shellQuote(shell) + " -i"
		return exec.Command(shell, "-l", "-c", launch), nil
	case "fish":
		return exec.Command(shell, "-l", "-C", "set -gx PATH "+shellQuote(shimPath)+" $PATH"), nil
	default:
		return exec.Command(shell, "-l"), nil
	}
}

func writeZshIntegration(home, shimPath string) (string, error) {
	directory := filepath.Join(home, ".local", "share", "relay", "shell", "zsh")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	contents := "# Managed by Relay Terminal.\n" +
		"if [ -r \"${RELAY_ORIGINAL_ZDOTDIR:-$HOME}/.zshrc\" ]; then source \"${RELAY_ORIGINAL_ZDOTDIR:-$HOME}/.zshrc\"; fi\n" +
		"export PATH=" + shellQuote(shimPath) + ":$PATH\n" +
		"rehash 2>/dev/null || true\n"
	if err := os.WriteFile(filepath.Join(directory, ".zshrc"), []byte(contents), 0o600); err != nil {
		return "", err
	}
	return directory, nil
}

func writeBashIntegration(home, shimPath string) (string, error) {
	directory := filepath.Join(home, ".local", "share", "relay", "shell")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(directory, "bashrc")
	contents := "# Managed by Relay Terminal.\n" +
		"if [ -r \"$HOME/.bashrc\" ]; then . \"$HOME/.bashrc\"; fi\n" +
		"export PATH=" + shellQuote(shimPath) + ":$PATH\n" +
		"hash -r 2>/dev/null || true\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func environmentWithOverrides(environment []string, overrides map[string]string) []string {
	result := make([]string, 0, len(environment)+len(overrides))
	for _, entry := range environment {
		name, _, found := strings.Cut(entry, "=")
		if found {
			if _, replaced := overrides[name]; replaced {
				continue
			}
		}
		result = append(result, entry)
	}
	for name, value := range overrides {
		result = append(result, name+"="+value)
	}
	return result
}

func (session *Session) monitorAgentProcesses() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lastAgent := ""
	for range ticker.C {
		session.mu.Lock()
		exited := session.exited
		rootPID := session.process.Process.Pid
		session.mu.Unlock()
		if exited {
			return
		}
		agent := descendantAgent(rootPID)
		if agent == lastAgent {
			continue
		}
		if lastAgent != "" {
			session.publishDetectedAgent(lastAgent, "SessionEnd")
		}
		if agent != "" {
			session.publishDetectedAgent(agent, "SessionStart")
		}
		lastAgent = agent
	}
}

func (session *Session) publishDetectedAgent(agent, eventName string) {
	payload, err := json.Marshal(map[string]any{
		"agent": agent,
		"event": map[string]any{
			"hook_event_name": eventName,
			"source":          "process-tree",
		},
	})
	if err == nil {
		session.agentEvent(payload)
	}
}

func descendantAgent(rootPID int) string {
	stack := []int{rootPID}
	seen := make(map[int]bool)
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		command, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
		arguments, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if agent := classifyAgentProcess(string(command), string(arguments)); agent != "" {
			return agent
		}
		children, _ := os.ReadFile(filepath.Join(
			"/proc", strconv.Itoa(pid), "task", strconv.Itoa(pid), "children",
		))
		for _, value := range strings.Fields(string(children)) {
			if child, err := strconv.Atoi(value); err == nil {
				stack = append(stack, child)
			}
		}
	}
	return ""
}

func classifyAgentProcess(command, arguments string) string {
	command = strings.ToLower(strings.TrimSpace(command))
	arguments = strings.ToLower(strings.ReplaceAll(arguments, "\x00", " "))
	if command == "codex" || strings.Contains(arguments, "/codex ") || strings.HasSuffix(arguments, "/codex") {
		return "codex"
	}
	if command == "claude" || strings.Contains(arguments, "/claude ") || strings.HasSuffix(arguments, "/claude") {
		return "claude"
	}
	return ""
}

func (session *Session) workingDirectory() string {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.exited || session.process == nil || session.process.Process == nil {
		return ""
	}
	// Linux exposes the shell's current directory here. On other Unix hosts this
	// simply falls back to the login directory when /proc is unavailable.
	directory, err := os.Readlink(fmt.Sprintf("/proc/%d/cwd", session.process.Process.Pid))
	if err != nil {
		return ""
	}
	return directory
}

func (session *Session) hasExited() bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.exited
}

func (session *Session) readOutput() {
	buffer := make([]byte, 32<<10)
	for {
		count, err := session.pty.Read(buffer)
		if count > 0 {
			session.publish(buffer[:count])
		}
		if err != nil {
			return
		}
	}
}

func (session *Session) publish(data []byte) {
	copyOfData := append([]byte(nil), data...)
	artifactFrames := make([]protocol.Frame, 0)
	for _, path := range session.artifactDetector.ingest(copyOfData) {
		if image, err := loadInlineArtifact(path); err == nil {
			artifactFrames = append(artifactFrames, protocol.ArtifactFrame(path, image))
		}
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	session.sequence++
	session.replay = append(session.replay, record{sequence: session.sequence, data: copyOfData, artifacts: artifactFrames})
	session.replayBytes += len(copyOfData)
	for _, artifact := range artifactFrames {
		session.replayBytes += len(artifact.Payload)
	}
	for session.replayBytes > replayLimit && len(session.replay) > 1 {
		session.replayBytes -= len(session.replay[0].data)
		for _, artifact := range session.replay[0].artifacts {
			session.replayBytes -= len(artifact.Payload)
		}
		session.replay = session.replay[1:]
	}
	frame := protocol.OutputFrame(session.sequence, copyOfData)
	for viewer := range session.clients {
		select {
		case viewer.frames <- frame:
		default:
			// A stalled viewer may miss frames; its next reconnect repairs the gap from replay.
		}
		for _, artifact := range artifactFrames {
			select {
			case viewer.frames <- artifact:
			default:
			}
		}
	}
}

func (session *Session) wait() {
	defer close(session.done)
	err := session.process.Wait()
	exitCode := 0
	if err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			exitCode = exitError.ExitCode()
		} else {
			exitCode = -1
		}
	}
	status, _ := json.Marshal(protocol.StatusPayload{State: "exited", ExitCode: exitCode})
	session.mu.Lock()
	session.exited = true
	session.exitCode = exitCode
	for viewer := range session.clients {
		select {
		case viewer.frames <- protocol.Frame{Type: protocol.Status, Payload: status}:
		default:
		}
	}
	for observer := range session.agentClients {
		select {
		case observer.frames <- protocol.Frame{Type: protocol.Status, Payload: status}:
		default:
		}
	}
	session.mu.Unlock()
}

func (session *Session) snapshot() (sequence uint64, exited bool, exitCode int) {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.sequence, session.exited, session.exitCode
}

func (session *Session) processID() int {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.process == nil || session.process.Process == nil {
		return 0
	}
	return session.process.Process.Pid
}

func (session *Session) attach(lastSequence uint64) (*client, []protocol.Frame) {
	session.mu.Lock()
	defer session.mu.Unlock()
	viewer := &client{frames: make(chan protocol.Frame, 512)}
	session.clients[viewer] = struct{}{}
	if lastSequence > session.sequence {
		lastSequence = 0
	}
	startRecord, startOffset := replayStart(session.replay, lastSequence)
	frames := make([]protocol.Frame, 0, len(session.replay)-startRecord)
	for index, item := range session.replay {
		if item.sequence > lastSequence {
			if index < startRecord {
				continue
			}
			data := item.data
			if index == startRecord && startOffset > 0 {
				data = append([]byte("\x1bc"), data[startOffset:]...)
			}
			frames = append(frames, protocol.OutputFrame(item.sequence, data))
			frames = append(frames, item.artifacts...)
		}
	}
	if session.exited {
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "exited", ExitCode: session.exitCode})
		frames = append(frames, status)
	}
	if len(session.latestAgentEvent) > 0 {
		frames = append(frames, protocol.Frame{
			Type:    protocol.AgentEvent,
			Payload: append([]byte(nil), session.latestAgentEvent...),
		})
	}
	for _, payload := range session.activeSubagents {
		if bytes.Equal(payload, session.latestAgentEvent) {
			continue
		}
		frames = append(frames, protocol.Frame{
			Type: protocol.AgentEvent, Payload: append([]byte(nil), payload...),
		})
	}
	return viewer, frames
}

// A new local renderer only needs the latest complete terminal redraw. Sending
// the full cursor-addressed history is both slower and incorrect when the pane
// has changed size since the TUI emitted it. Incremental reconnects stay exact.
func replayStart(replay []record, lastSequence uint64) (int, int) {
	if lastSequence != 0 {
		return 0, 0
	}
	clears := [][]byte{[]byte("\x1b[2J"), []byte("\x1b[3J"), []byte("\x1bc")}
	for index := len(replay) - 1; index >= 0; index-- {
		latest := -1
		for _, clear := range clears {
			if offset := bytes.LastIndex(replay[index].data, clear); offset > latest {
				latest = offset
			}
		}
		if latest >= 0 {
			return index, latest
		}
	}
	return 0, 0
}

func (session *Session) detach(viewer *client) {
	session.mu.Lock()
	delete(session.clients, viewer)
	session.mu.Unlock()
}

func (session *Session) observeAgents() (*client, []protocol.Frame) {
	session.mu.Lock()
	defer session.mu.Unlock()
	observer := &client{frames: make(chan protocol.Frame, 64)}
	session.agentClients[observer] = struct{}{}
	frames := make([]protocol.Frame, 0, 2)
	if len(session.latestAgentEvent) > 0 {
		frames = append(frames, protocol.Frame{
			Type:    protocol.AgentEvent,
			Payload: append([]byte(nil), session.latestAgentEvent...),
		})
	}
	for _, payload := range session.activeSubagents {
		if bytes.Equal(payload, session.latestAgentEvent) {
			continue
		}
		frames = append(frames, protocol.Frame{
			Type: protocol.AgentEvent, Payload: append([]byte(nil), payload...),
		})
	}
	if session.exited {
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "exited", ExitCode: session.exitCode})
		frames = append(frames, status)
	}
	return observer, frames
}

func (session *Session) detachAgentObserver(observer *client) {
	session.mu.Lock()
	delete(session.agentClients, observer)
	session.mu.Unlock()
}

func (session *Session) input(data []byte) error {
	session.mu.Lock()
	exited := session.exited
	session.mu.Unlock()
	if exited {
		return io.ErrClosedPipe
	}
	_, err := session.pty.Write(data)
	return err
}

func (session *Session) resize(cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	return pty.Setsize(session.pty, &pty.Winsize{Cols: cols, Rows: rows})
}

func (session *Session) agentEvent(payload []byte) {
	frame := protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), payload...)}
	session.mu.Lock()
	defer session.mu.Unlock()
	session.latestAgentEvent = append(session.latestAgentEvent[:0], payload...)
	session.updateActiveSubagents(payload)
	for viewer := range session.clients {
		select {
		case viewer.frames <- frame:
		default:
		}
	}
	for observer := range session.agentClients {
		select {
		case observer.frames <- frame:
		default:
		}
	}
}

func (session *Session) updateActiveSubagents(payload []byte) {
	var envelope struct {
		Event struct {
			HookEventName string `json:"hook_event_name"`
			Type          string `json:"type"`
			AgentID       string `json:"agent_id"`
			SubagentID    string `json:"subagent_id"`
			ThreadID      string `json:"thread_id"`
			AgentType     string `json:"agent_type"`
		} `json:"event"`
	}
	if json.Unmarshal(payload, &envelope) != nil {
		return
	}
	eventName := envelope.Event.HookEventName
	if eventName == "" {
		eventName = envelope.Event.Type
	}
	identifier := envelope.Event.AgentID
	if identifier == "" {
		identifier = envelope.Event.SubagentID
	}
	if identifier == "" {
		identifier = envelope.Event.ThreadID
	}
	if identifier == "" {
		identifier = envelope.Event.AgentType
	}
	switch eventName {
	case "SessionStart", "SessionEnd":
		clear(session.activeSubagents)
	case "SubagentStart":
		if identifier != "" {
			session.activeSubagents[identifier] = append([]byte(nil), payload...)
		}
	case "SubagentStop":
		if identifier != "" {
			delete(session.activeSubagents, identifier)
		} else {
			for key := range session.activeSubagents {
				delete(session.activeSubagents, key)
				break
			}
		}
	}
}

func (session *Session) signal(signal syscall.Signal) error {
	return session.process.Process.Signal(signal)
}
