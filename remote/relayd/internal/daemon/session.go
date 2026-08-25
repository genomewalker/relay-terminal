package daemon

import (
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
	exited           bool
	exitCode         int
	latestAgentEvent []byte
	artifactDetector artifactDetector
	done             chan struct{}
}

func startSession(id, command, workingDirectory string, cols, rows uint16) (*Session, error) {
	var child *exec.Cmd
	if command == "" {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/sh"
		}
		child = exec.Command(shell, "-l")
	} else {
		child = exec.Command("/bin/sh", "-lc", command)
	}
	if workingDirectory != "" {
		child.Dir = workingDirectory
	}
	home, _ := os.UserHomeDir()
	shimPath := filepath.Join(home, ".local", "share", "relay", "shims")
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
		clients: make(map[*client]struct{}), done: make(chan struct{}),
	}
	go session.readOutput()
	go session.wait()
	go session.monitorAgentProcesses()
	return session, nil
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
	frames := make([]protocol.Frame, 0, len(session.replay))
	for _, item := range session.replay {
		if item.sequence > lastSequence {
			frames = append(frames, protocol.OutputFrame(item.sequence, item.data))
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
	return viewer, frames
}

func (session *Session) detach(viewer *client) {
	session.mu.Lock()
	delete(session.clients, viewer)
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
	for viewer := range session.clients {
		select {
		case viewer.frames <- frame:
		default:
		}
	}
}

func (session *Session) signal(signal syscall.Signal) error {
	return session.process.Process.Signal(signal)
}
