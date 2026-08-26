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
	lagged chan struct{}
	once   sync.Once
}

func newClient(capacity int) *client {
	return &client{frames: make(chan protocol.Frame, capacity), lagged: make(chan struct{})}
}

func (viewer *client) markLagged() {
	viewer.once.Do(func() { close(viewer.lagged) })
}

type Session struct {
	id      string
	command string
	pty     *os.File
	process *exec.Cmd

	mu                 sync.Mutex
	sequence           uint64
	replay             []record
	replayBytes        int
	clients            map[*client]struct{}
	agentClients       map[*client]struct{}
	exited             bool
	exitCode           int
	latestAgentEvent   []byte
	activeSubagents    map[string][]byte
	activeAgentRoots   map[string][]byte
	eventSequence      uint64
	eventHistory       []protocol.Frame
	eventHistoryBytes  int
	eventJournal       *agentEventJournal
	eventHashes        map[[32]byte]struct{}
	eventHashOrder     [][32]byte
	eventJournalError  string
	inputSequences     map[[16]byte]uint64
	artifactDetector   artifactDetector
	controlClientID    string
	controlConnections int
	controlGraceUntil  time.Time
	done               chan struct{}
}

func (session *Session) acquireControl(clientID string) bool {
	if clientID == "" {
		clientID = "legacy"
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	now := time.Now()
	if session.controlClientID == clientID {
		session.controlConnections++
		return true
	}
	if session.controlClientID == "" || session.controlConnections == 0 && !session.controlGraceUntil.After(now) {
		session.controlClientID = clientID
		session.controlConnections = 1
		session.controlGraceUntil = time.Time{}
		return true
	}
	return false
}

func (session *Session) releaseControl(clientID string) {
	if clientID == "" {
		clientID = "legacy"
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.controlClientID != clientID || session.controlConnections == 0 {
		return
	}
	session.controlConnections--
	if session.controlConnections == 0 {
		session.controlGraceUntil = time.Now().Add(5 * time.Second)
	}
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
		"TERM_PROGRAM":  "relay",
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
		activeSubagents: make(map[string][]byte), activeAgentRoots: make(map[string][]byte), done: make(chan struct{}),
		inputSequences: make(map[[16]byte]uint64),
		eventHashes:    make(map[[32]byte]struct{}),
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
		"rehash 2>/dev/null || true\n" +
		zshSemanticPromptIntegration
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
		"hash -r 2>/dev/null || true\n" +
		bashSemanticPromptIntegration
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

// OSC 133 divides terminal output into prompt, input, and command-output
// regions. Besides making scrollback structurally useful, Ghostty uses the
// prompt/input region to implement exact click-to-move for readline and ZLE.
// Keep this integration owned by Relay: remote nodes need only the relayd
// binary, and a user's shell configuration remains the source of their prompt.
const bashSemanticPromptIntegration = `
# Relay semantic prompt integration (OSC 133).
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  __relay_command_active=""

  __relay_preexec() {
    builtin printf '\e]133;C\a'
    __relay_command_active=1
  }

  __relay_prompt_hook() {
    builtin local command_status=$?

    if [[ "$__relay_command_active" == "1" ]]; then
      builtin printf '\e]133;D;%s\a' "$command_status"
    fi

    # OSC 7 makes the working directory structured terminal state. Ghostty
    # consumes it for directory tracking while Relay mirrors it into the pane
    # model. HOSTNAME and PWD are shell-owned values, so no subprocess runs on
    # every prompt.
    builtin printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"

    # Restore the clean prompt before running this hook again. This lets
    # dynamic prompt tools replace PS1 without accumulating markers.
    if [[ -n "${__relay_marked_ps1+x}" && "$PS1" == "$__relay_marked_ps1" ]]; then
      PS1="$__relay_clean_ps1"
      PS2="$__relay_clean_ps2"
    fi
    __relay_clean_ps1="$PS1"
    __relay_clean_ps2="$PS2"
    PS1='\[\e]133;P;k=i\a\]'"$PS1"'\[\e]133;B\a\]'
    PS2='\[\e]133;P;k=s\a\]'"$PS2"'\[\e]133;B\a\]'
    __relay_marked_ps1="$PS1"

    builtin printf '\e]133;A;redraw=last;cl=line\a'
    __relay_command_active=0

    if [[ "$PS0" != *"__relay_preexec"* ]]; then
      # Bash 4.4 is common on HPC nodes. Command substitution is the portable
      # preexec hook there; redirecting to the TTY keeps OSC out of substitution.
      PS0+='$(__relay_preexec >/dev/tty)'
    fi
  }

  if [[ ";${PROMPT_COMMAND[*]:-};" != *";__relay_prompt_hook 2>/dev/null;"* ]]; then
    if [[ -z "${PROMPT_COMMAND[*]:-}" ]]; then
      PROMPT_COMMAND="__relay_prompt_hook 2>/dev/null"
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a "* ]]; then
      PROMPT_COMMAND+=("__relay_prompt_hook 2>/dev/null")
    else
      [[ "$PROMPT_COMMAND" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=';'
      PROMPT_COMMAND+="__relay_prompt_hook 2>/dev/null"
    fi
  fi
fi
`

const zshSemanticPromptIntegration = `
# Relay semantic prompt integration (OSC 133).
if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  typeset -g __relay_command_active=0

  __relay_precmd() {
    local command_status=$?
    if (( __relay_command_active )); then
      print -rn -- $'\e]133;D;'${command_status}$'\a' > /dev/tty
    fi

    print -rn -- $'\e]7;file://'${HOST:-localhost}${PWD}$'\a' > /dev/tty

    if [[ -n ${__relay_marked_ps1+x} && $PS1 == $__relay_marked_ps1 ]]; then
      PS1=$__relay_clean_ps1
      PS2=$__relay_clean_ps2
    fi
    __relay_clean_ps1=$PS1
    __relay_clean_ps2=$PS2
    local primary=$'%{\e]133;A;cl=line\a%}'
    local secondary=$'%{\e]133;P;k=s\a%}'
    local input=$'%{\e]133;B\a%}'
    PS1=${primary}${PS1}${input}
    PS2=${secondary}${PS2}${input}
    __relay_marked_ps1=$PS1
    __relay_command_active=0
  }

  __relay_preexec() {
    print -rn -- $'\e]133;C\a' > /dev/tty
    __relay_command_active=1
  }

  add-zsh-hook precmd __relay_precmd
  add-zsh-hook preexec __relay_preexec
fi
`

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
	known := make(map[int]string)
	for range ticker.C {
		session.mu.Lock()
		exited := session.exited
		rootPID := session.process.Process.Pid
		session.mu.Unlock()
		if exited {
			return
		}
		current := descendantAgentProcesses(rootPID)
		for pid, agent := range known {
			if _, exists := current[pid]; !exists {
				session.publishDetectedAgent(agent, "SessionEnd", pid)
			}
		}
		for pid, agent := range current {
			if known[pid] != agent {
				session.publishDetectedAgent(agent, "SessionStart", pid)
			}
		}
		known = current
	}
}

func (session *Session) publishDetectedAgent(agent, eventName string, pid int) {
	startTime, _ := processStartTime(pid)
	payload, err := json.Marshal(map[string]any{
		"agent": agent,
		"event": map[string]any{
			"hook_event_name": eventName,
			"source":          "process-tree",
			"root_id":         fmt.Sprintf("%s:%d:%d", agent, pid, startTime),
			"occurred_at":     time.Now().UTC().Format(time.RFC3339Nano),
		},
	})
	if err == nil {
		session.agentEvent(payload)
	}
}

func descendantAgent(rootPID int) string {
	agent, _ := descendantAgentProcess(rootPID)
	return agent
}

func descendantAgentProcesses(rootPID int) map[int]string {
	result := make(map[int]string)
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
			result[pid] = agent
		}
		children, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "task", strconv.Itoa(pid), "children"))
		for _, value := range strings.Fields(string(children)) {
			if child, err := strconv.Atoi(value); err == nil {
				stack = append(stack, child)
			}
		}
	}
	return result
}

func descendantAgentProcess(rootPID int) (string, int) {
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
			return agent, pid
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
	return "", 0
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
			session.artifactDetector.markLoaded(path)
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
		// Delivery is all-or-nothing for a replay record. In particular, never
		// deliver the output sequence while dropping a following artifact: the
		// client's resume cursor would otherwise skip that artifact forever.
		if cap(viewer.frames)-len(viewer.frames) < 1+len(artifactFrames) {
			viewer.markLagged()
			delete(session.clients, viewer)
			continue
		}
		viewer.frames <- frame
		for _, artifact := range artifactFrames {
			viewer.frames <- artifact
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
		if cap(viewer.frames)-len(viewer.frames) < 1 {
			viewer.markLagged()
			delete(session.clients, viewer)
			continue
		}
		viewer.frames <- protocol.Frame{Type: protocol.Status, Payload: status}
	}
	for observer := range session.agentClients {
		if cap(observer.frames)-len(observer.frames) < 1 {
			observer.markLagged()
			delete(session.agentClients, observer)
			continue
		}
		observer.frames <- protocol.Frame{Type: protocol.Status, Payload: status}
	}
	session.mu.Unlock()
}

func (session *Session) snapshot() (sequence uint64, eventSequence uint64, exited bool, exitCode int) {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.sequence, session.eventSequence, session.exited, session.exitCode
}

func (session *Session) processID() int {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.process == nil || session.process.Process == nil {
		return 0
	}
	return session.process.Process.Pid
}

func (session *Session) attach(lastSequence, lastEventSequence uint64) (*client, []protocol.Frame, bool, bool) {
	session.mu.Lock()
	defer session.mu.Unlock()
	viewer := newClient(512)
	session.clients[viewer] = struct{}{}
	outputReset := replayCursorHasGap(session.replay, lastSequence)
	if lastSequence > session.sequence {
		outputReset = true
	}
	if outputReset {
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
	eventReset := session.eventCursorHasGap(lastEventSequence)
	if eventReset || lastEventSequence == 0 {
		frames = append(frames, session.agentStateSnapshot())
		if eventReset {
			lastEventSequence = 0
		}
	}
	frames = append(frames, session.eventFramesAfter(lastEventSequence)...)
	return viewer, frames, outputReset, eventReset
}

func replayCursorHasGap(replay []record, sequence uint64) bool {
	if sequence == 0 || len(replay) == 0 {
		return false
	}
	return sequence+1 < replay[0].sequence
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

func (session *Session) observeAgents(lastEventSequence uint64) (*client, []protocol.Frame, bool) {
	session.mu.Lock()
	defer session.mu.Unlock()
	observer := newClient(256)
	session.agentClients[observer] = struct{}{}
	eventReset := session.eventCursorHasGap(lastEventSequence)
	frames := session.eventFramesAfter(lastEventSequence)
	if eventReset || lastEventSequence == 0 {
		if eventReset {
			frames = session.eventFramesAfter(0)
		}
		frames = append([]protocol.Frame{session.agentStateSnapshot()}, frames...)
	}
	if session.exited {
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "exited", ExitCode: session.exitCode})
		frames = append(frames, status)
	}
	return observer, frames, eventReset
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

func (session *Session) acknowledgedInput(clientID [16]byte, sequence uint64, data []byte) error {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.exited {
		return io.ErrClosedPipe
	}
	if sequence <= session.inputSequences[clientID] {
		return nil
	}
	remaining := data
	for len(remaining) > 0 {
		written, err := session.pty.Write(remaining)
		if err != nil {
			return err
		}
		remaining = remaining[written:]
	}
	session.inputSequences[clientID] = sequence
	if len(session.inputSequences) > 64 {
		for key := range session.inputSequences {
			if key != clientID {
				delete(session.inputSequences, key)
				break
			}
		}
	}
	return nil
}

func (session *Session) resize(cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	return pty.Setsize(session.pty, &pty.Winsize{Cols: cols, Rows: rows})
}

func (session *Session) agentEvent(payload []byte) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.eventHashes == nil {
		session.eventHashes = make(map[[32]byte]struct{})
	}
	hash := semanticAgentEventHash(payload)
	if _, duplicate := session.eventHashes[hash]; duplicate {
		return
	}
	session.eventHashes[hash] = struct{}{}
	session.eventHashOrder = append(session.eventHashOrder, hash)
	if len(session.eventHashOrder) > 4_096 {
		oldest := session.eventHashOrder[0]
		session.eventHashOrder = session.eventHashOrder[1:]
		delete(session.eventHashes, oldest)
	}
	session.eventSequence++
	payload = indexedAgentPayload(payload, session.eventSequence)
	frame := protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), payload...)}
	if session.eventJournal != nil {
		if err := session.eventJournal.append(session.eventSequence, payload); err != nil {
			session.eventJournalError = err.Error()
			fmt.Fprintf(os.Stderr, "relay: agent journal append failed: %v\n", err)
		}
	}
	session.appendEventHistory(frame)
	session.latestAgentEvent = append(session.latestAgentEvent[:0], payload...)
	session.updateActiveSubagents(payload)
	for viewer := range session.clients {
		if cap(viewer.frames)-len(viewer.frames) < 1 {
			viewer.markLagged()
			delete(session.clients, viewer)
			continue
		}
		viewer.frames <- frame
	}
	for observer := range session.agentClients {
		if cap(observer.frames)-len(observer.frames) < 1 {
			observer.markLagged()
			delete(session.agentClients, observer)
			continue
		}
		observer.frames <- frame
	}
}

func (session *Session) eventCursorHasGap(sequence uint64) bool {
	if sequence == 0 || len(session.eventHistory) == 0 {
		return false
	}
	return sequence+1 < indexedAgentSequence(session.eventHistory[0].Payload)
}

func (session *Session) agentStateSnapshot() protocol.Frame {
	events := make([]json.RawMessage, 0, len(session.activeAgentRoots)+len(session.activeSubagents))
	for _, payload := range session.activeAgentRoots {
		events = append(events, append(json.RawMessage(nil), payload...))
	}
	for _, payload := range session.activeSubagents {
		events = append(events, append(json.RawMessage(nil), payload...))
	}
	payload, _ := json.Marshal(map[string]any{
		"agent":           "relay",
		"relay_event_seq": session.eventSequence,
		"event": map[string]any{
			"type":   "RelayStateSnapshot",
			"events": events,
		},
	})
	return protocol.Frame{Type: protocol.AgentEvent, Payload: payload}
}

func (session *Session) eventFramesAfter(sequence uint64) []protocol.Frame {
	frames := make([]protocol.Frame, 0, len(session.eventHistory))
	for _, frame := range session.eventHistory {
		if indexedAgentSequence(frame.Payload) <= sequence {
			continue
		}
		frames = append(frames, protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), frame.Payload...)})
	}
	return frames
}

func (session *Session) appendEventHistory(frame protocol.Frame) {
	session.eventHistory = append(session.eventHistory, frame)
	session.eventHistoryBytes += len(frame.Payload)
	for (session.eventHistoryBytes > 16<<20 || len(session.eventHistory) > 10_000) && len(session.eventHistory) > 1 {
		session.eventHistoryBytes -= len(session.eventHistory[0].Payload)
		session.eventHistory = session.eventHistory[1:]
	}
}

func (session *Session) enableEventJournal(path string) error {
	journal, records, err := openAgentEventJournal(path)
	if err != nil {
		return err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	session.eventJournal = journal
	for _, record := range records {
		if record.Sequence <= session.eventSequence {
			continue
		}
		session.eventSequence = record.Sequence
		frame := protocol.Frame{Type: protocol.AgentEvent, Payload: record.Payload}
		session.appendEventHistory(frame)
		session.latestAgentEvent = append(session.latestAgentEvent[:0], record.Payload...)
		session.updateActiveSubagents(record.Payload)
	}
	return nil
}

func (session *Session) updateActiveSubagents(payload []byte) {
	if session.activeSubagents == nil {
		session.activeSubagents = make(map[string][]byte)
	}
	if session.activeAgentRoots == nil {
		session.activeAgentRoots = make(map[string][]byte)
	}
	var envelope struct {
		Agent string `json:"agent"`
		Event struct {
			HookEventName string `json:"hook_event_name"`
			Type          string `json:"type"`
			AgentID       string `json:"agent_id"`
			SubagentID    string `json:"subagent_id"`
			ThreadID      string `json:"thread_id"`
			AgentType     string `json:"agent_type"`
			RootID        string `json:"root_id"`
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
	case "SessionStart":
		rootID := envelope.Event.RootID
		if rootID == "" {
			rootID = envelope.Agent
		}
		if rootID != "" {
			session.activeAgentRoots[rootID] = append([]byte(nil), payload...)
		}
	case "SessionEnd":
		rootID := envelope.Event.RootID
		if rootID == "" {
			rootID = envelope.Agent
		}
		delete(session.activeAgentRoots, rootID)
		providerStillRunning := false
		for _, activePayload := range session.activeAgentRoots {
			var activeEnvelope struct {
				Agent string `json:"agent"`
			}
			if json.Unmarshal(activePayload, &activeEnvelope) == nil && activeEnvelope.Agent == envelope.Agent {
				providerStillRunning = true
				break
			}
		}
		if !providerStillRunning {
			for key, activePayload := range session.activeSubagents {
				var activeEnvelope struct {
					Agent string `json:"agent"`
				}
				if json.Unmarshal(activePayload, &activeEnvelope) == nil && activeEnvelope.Agent == envelope.Agent {
					delete(session.activeSubagents, key)
				}
			}
		}
	case "SubagentStart":
		if identifier != "" {
			session.activeSubagents[envelope.Agent+"\x00"+identifier] = append([]byte(nil), payload...)
		}
	case "SubagentStop":
		if identifier != "" {
			delete(session.activeSubagents, envelope.Agent+"\x00"+identifier)
		} else {
			for key, activePayload := range session.activeSubagents {
				var activeEnvelope struct {
					Agent string `json:"agent"`
				}
				if json.Unmarshal(activePayload, &activeEnvelope) == nil && activeEnvelope.Agent == envelope.Agent {
					delete(session.activeSubagents, key)
					break
				}
			}
		}
	}
}

func (session *Session) signal(signal syscall.Signal) error {
	return session.process.Process.Signal(signal)
}

func (session *Session) terminate() {
	session.mu.Lock()
	if session.exited || session.process == nil || session.process.Process == nil {
		session.mu.Unlock()
		return
	}
	pid := session.process.Process.Pid
	session.mu.Unlock()
	// pty.Start creates a new session/process group. Signal the group so an
	// explicit Relay termination does not orphan agent descendants.
	_ = syscall.Kill(-pid, syscall.SIGHUP)
	_ = session.process.Process.Signal(syscall.SIGTERM)
}
