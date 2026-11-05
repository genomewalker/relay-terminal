package daemon

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
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
	"unsafe"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"

	"github.com/relay-terminal/relayd/internal/programstatus"
	"github.com/relay-terminal/relayd/internal/protocol"
	relayterminfo "github.com/relay-terminal/relayd/internal/terminfo"
)

const replayLimit = 8 << 20

type record struct {
	sequence  uint64
	data      []byte
	artifacts []protocol.Frame
}

type client struct {
	frames               chan protocol.Frame
	lagged               chan struct{}
	once                 sync.Once
	includeProgramStatus bool
	includeAgentEvents   bool
}

func newClient(capacity int) *client {
	return &client{
		frames: make(chan protocol.Frame, capacity), lagged: make(chan struct{}), includeAgentEvents: true,
	}
}

func (viewer *client) markLagged() {
	viewer.once.Do(func() { close(viewer.lagged) })
}

type Session struct {
	nativeRotationMu        sync.Mutex
	nativeRotation          *hostNativeRotationBridge
	hostRotation            *hostRotationSupervisor
	promptEditorMu          sync.Mutex
	promptEditor            *promptEditorPending
	id                      string
	command                 string
	pty                     *os.File
	process                 *exec.Cmd
	resizeMu                sync.Mutex
	inputMu                 sync.Mutex
	humanInputRevision      uint64 // inputMu; invalidates enrollment prepared outside this lock
	automationInputRevision uint64 // inputMu; Relay's own input also invalidates a prepared enrollment
	rotationControlled      bool
	rotationGuardDirectory  string
	rotationHumanInputSeen  bool
	rotationGuardInstalled  bool
	eventMu                 sync.Mutex

	mu                    sync.Mutex
	sequence              uint64
	outputChanged         chan struct{}
	replay                []record
	replayBytes           int
	replayTrimmed         bool // set only when retained PTY records are evicted
	clients               map[*client]struct{}
	agentClients          map[*client]struct{}
	exited                bool
	exitCode              int
	latestAgentEvent      []byte
	activeSubagents       map[string][]byte
	activeAgentRoots      map[string][]byte
	agentProcesses        map[int]string
	agentProcessesChanged chan struct{}
	eventSequence         uint64
	eventHistory          []protocol.Frame
	eventHistoryBytes     int
	eventJournal          agentEventWriter
	eventHashes           map[[32]byte]struct{}
	eventHashOrder        [][32]byte
	eventJournalError     string
	inputSequences        map[[16]byte]uint64
	artifactDetector      artifactDetector
	programStatusReplies  chan int
	programStatusRevision uint64
	programStatus         programstatus.Tracker
	terminalModes         terminalModeState
	controlClientID       string
	controlConnections    int
	controlGraceUntil     time.Time
	done                  chan struct{}

	// The PTY reader can be stopped between reads so a worker can hand the
	// master to a re-executed image without losing or duplicating output.
	reader *outputReader
	// Set when agentProcesses was carried from a previous worker image, so
	// processes already announced are not announced again.
	agentProcessesSeeded bool
	// The upgrade operation that produced this image, reported by probes.
	reexecOperation string
	// Handles an authenticated worker upgrade request; nil outside a worker.
	workerUpgrade func(*protocol.Writer, json.RawMessage)
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

func (session *Session) releaseControl(clientID string, graceful bool) {
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
		if graceful {
			session.controlClientID = ""
			session.controlGraceUntil = time.Time{}
		} else {
			session.controlGraceUntil = time.Now().Add(5 * time.Second)
		}
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
	child.Dir = home
	if workingDirectory != "" {
		child.Dir = workingDirectory
	}
	environmentOverrides := relayterminfo.PreferredEnvironment()
	environmentOverrides["COLORTERM"] = "truecolor"
	environmentOverrides["TERM_PROGRAM"] = "relay"
	environmentOverrides["RELAY_SESSION"] = id
	// Configure only newly launched shells. The official Claude shim can
	// prepare its editor bridge before exec without rebinding live providers.
	environmentOverrides["RELAY_PROMPT_EDITOR_ENABLE"] = promptEditorLaunchSetting(os.Environ())
	environmentOverrides["PATH"] = shimPath + string(os.PathListSeparator) + os.Getenv("PATH")
	child.Env = TerminalEnvironment(environmentWithOverrides(os.Environ(), environmentOverrides))
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
	session := newSession(id, command, terminal, child)
	// Seed the shared process snapshot once so transcript observers can attach
	// immediately. Thereafter one monitor owns /proc traversal for the pane and
	// broadcasts changes to both Codex and Claude readers.
	session.agentProcesses = descendantAgentProcesses(child.Process.Pid)
	session.start()
	return session, nil
}

func newSession(id, command string, terminal *os.File, child *exec.Cmd) *Session {
	return &Session{
		id: id, command: command, pty: terminal, process: child,
		sequence: initialOutputSequence(),
		clients:  make(map[*client]struct{}), agentClients: make(map[*client]struct{}),
		activeSubagents: make(map[string][]byte), activeAgentRoots: make(map[string][]byte), done: make(chan struct{}),
		agentProcesses: make(map[int]string), agentProcessesChanged: make(chan struct{}),
		inputSequences:       make(map[[16]byte]uint64),
		eventHashes:          make(map[[32]byte]struct{}),
		outputChanged:        make(chan struct{}),
		terminalModes:        newTerminalModeState(),
		programStatusReplies: make(chan int, 8),
	}
}

func (session *Session) start() {
	go session.writeProgramStatusReplies()
	session.startOutputReader()
	go session.wait()
	go session.monitorAgentProcesses()
}

// Every worker owns a distinct output sequence space. Starting from a random
// high-water value makes a cursor retained from a dead worker unambiguously
// outside a replacement worker's replay range: it is either ahead of the new
// tail or behind the new ring head, and attach therefore requests a reset.
// A zero-based counter could alias after a restart and silently skip the new
// shell's first N output records.
func initialOutputSequence() uint64 {
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err == nil {
		return outputSequenceFromEntropy(binary.BigEndian.Uint64(raw[:]))
	}
	return outputSequenceFromEntropy(uint64(time.Now().UnixNano()))
}

func outputSequenceFromEntropy(value uint64) uint64 {
	const marker = uint64(1) << 62
	return marker | (value & (marker - 1))
}

func sessionCommand(shell, command, home, shimPath string) (*exec.Cmd, error) {
	if command != "" {
		// Startup commands are children of the pane bootstrap. Even an `exec`
		// in a configured agent command must not consume the persistent shell.
		interactive, err := sessionCommand(shell, "", home, shimPath)
		if err != nil {
			return nil, err
		}
		followup := "exec " + shellQuote(interactive.Path)
		for _, arg := range interactive.Args[1:] {
			followup += " " + shellQuote(arg)
		}
		launch := shellQuote(shell) + " -lc " + shellQuote(command)
		wrapped := "export PATH=" + shellQuote(shimPath) + ":$PATH; hash -r 2>/dev/null || true; " + launch + "; " + followup
		if filepath.Base(shell) == "fish" {
			wrapped = "set -gx PATH " + shellQuote(shimPath) + " $PATH; " + launch + "; " + followup
		}
		return exec.Command(shell, "-lc", wrapped), nil
	}

	switch filepath.Base(shell) {
	case "bash":
		rcPath, err := writeBashIntegration(home, shimPath)
		if err != nil {
			return nil, err
		}
		// Load profile and interactive setup in the same process. A login
		// bootstrap followed by exec loses non-exported prompt functions.
		return exec.Command(shell, "--rcfile", rcPath, "-i"), nil
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
		relayCodexShellFunction(shimPath) +
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
		// This is an interactive non-login Bash using --rcfile. On RHEL-like
		// hosts /etc/profile sources /etc/bashrc, which then sources every
		// /etc/profile.d script again because login_shell is off. Mark the
		// system bashrc as already handled while loading the login profile.
		// Otherwise readonly declarations in profile.d fail on every split.
		"if [ -r /etc/profile ]; then BASHRCSOURCED=Y; . /etc/profile; fi\n" +
		"__relay_profile_loaded=0\n" +
		"for __relay_profile in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do\n" +
		"  if [ -r \"$__relay_profile\" ]; then . \"$__relay_profile\"; __relay_profile_loaded=1; break; fi\n" +
		"done\n" +
		// Login profiles decide whether to load ~/.bashrc. Loading it here as
		// well runs the user's interactive configuration twice on common hosts.
		"if [ \"$__relay_profile_loaded\" -eq 0 ] && [ -r \"$HOME/.bashrc\" ]; then . \"$HOME/.bashrc\"; fi\n" +
		"unset __relay_profile __relay_profile_loaded\n" +
		"export PATH=" + shellQuote(shimPath) + ":$PATH\n" +
		"hash -r 2>/dev/null || true\n" +
		relayCodexShellFunction(shimPath) +
		bashSemanticPromptIntegration
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

// Environment activators can reorder PATH after shell startup. Keep interactive
// Codex launches on the managed entry point without changing other tools' PATH.
func relayCodexShellFunction(shimPath string) string {
	shim := shellQuote(filepath.Join(shimPath, "codex"))
	return "if [ -x " + shim + " ]; then\n" +
		"  unalias codex 2>/dev/null || true\n" +
		"  function codex { command " + shim + " \"$@\"; }\n" +
		"fi\n"
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
  # Always empty: PS0 expands one of its elements to mark a command started.
  __relay_ps0=()

  __relay_prompt_hook() {
    builtin local command_status=$? __relay_function
    builtin local -a __relay_others

    # Stay the last bash-preexec precmd function, so the markers wrap the
    # PS1 that other functions (such as its own precmd) leave behind.
    if [[ " ${precmd_functions[*]:-} " == *" __relay_prompt_hook "* &&
          "${precmd_functions[-1]}" != __relay_prompt_hook ]]; then
      for __relay_function in "${precmd_functions[@]}"; do
        [[ "$__relay_function" == __relay_prompt_hook ]] || __relay_others+=("$__relay_function")
      done
      precmd_functions=("${__relay_others[@]}" __relay_prompt_hook)
    fi

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

    if [[ "$PS0" != *"__relay_command_active=1"* ]]; then
      # Bash 4.4 is common on HPC nodes and has no preexec hook. PS0 expands
      # in this shell, so the subscript's assignment marks the command as
      # started here (a command substitution would set it in a subshell),
      # and the empty element adds nothing to the output.
      PS0+='${__relay_ps0[__relay_command_active=1]}\e]133;C\a'
    fi
  }

  # bash-preexec installs itself at the first prompt, and older releases then
  # replace PROMPT_COMMAND, dropping a hook appended after it was sourced.
  # While it is installed or pending, run through its precmd functions.
  if builtin declare -F __bp_precmd_invoke_cmd >/dev/null &&
     [[ "${PROMPT_COMMAND[*]:-}" == *__bp_install* || "${PROMPT_COMMAND[*]:-}" == *__bp_precmd_invoke_cmd* ]]; then
    if [[ " ${precmd_functions[*]:-} " != *" __relay_prompt_hook "* ]]; then
      precmd_functions+=(__relay_prompt_hook)
    fi
  elif [[ ";${PROMPT_COMMAND[*]:-};" != *";__relay_prompt_hook 2>/dev/null;"* ]]; then
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

func promptEditorLaunchSetting(environment []string) string {
	for _, entry := range environment {
		if value, found := strings.CutPrefix(entry, "RELAY_PROMPT_EDITOR_ENABLE="); found {
			return value
		}
	}
	return "1"
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
	timer := time.NewTimer(0)
	defer timer.Stop()
	known := make(map[int]detectedAgentProcess)
	session.mu.Lock()
	if session.agentProcessesSeeded {
		// Carried from the previous worker image, which already announced them.
		known = observedAgentProcesses(session.agentProcesses, nil, processStartIdentity)
	}
	session.mu.Unlock()
	for range timer.C {
		session.mu.Lock()
		exited := session.exited
		rootPID := session.process.Process.Pid
		session.mu.Unlock()
		if exited {
			return
		}
		current := descendantAgentProcesses(rootPID)
		observed := observedAgentProcesses(current, known, processStartIdentity)
		for _, change := range agentProcessTransitions(known, observed) {
			session.publishDetectedAgent(change.process.agent, change.event, change.pid, change.process.startIdentity)
		}
		known = observed
		session.updateAgentProcesses(current)
		timer.Reset(agentProcessPollInterval(len(current)))
	}
}

func (session *Session) updateAgentProcesses(current map[int]string) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if agentProcessMapsEqual(session.agentProcesses, current) {
		return
	}
	session.agentProcesses = cloneAgentProcesses(current)
	close(session.agentProcessesChanged)
	session.agentProcessesChanged = make(chan struct{})
}

func (session *Session) agentProcessSnapshot() (map[int]string, <-chan struct{}) {
	session.mu.Lock()
	defer session.mu.Unlock()
	return cloneAgentProcesses(session.agentProcesses), session.agentProcessesChanged
}

func cloneAgentProcesses(source map[int]string) map[int]string {
	result := make(map[int]string, len(source))
	for pid, agent := range source {
		result[pid] = agent
	}
	return result
}

func agentProcessMapsEqual(left, right map[int]string) bool {
	if len(left) != len(right) {
		return false
	}
	for pid, agent := range left {
		if right[pid] != agent {
			return false
		}
	}
	return true
}

func agentProcessPollInterval(activeAgents int) time.Duration {
	if activeAgents > 0 {
		return time.Second
	}
	// Provider hooks and transcript streams remain the fast path. Process-tree
	// detection is a compatibility safety net, so idle shells do not need one
	// /proc traversal per second for their entire lifetime.
	return 5 * time.Second
}

func transcriptPollInterval(activeReaders, idlePolls int) time.Duration {
	if activeReaders > 0 {
		switch idlePolls {
		case 0:
			return 250 * time.Millisecond
		case 1:
			return 500 * time.Millisecond
		case 2:
			return time.Second
		default:
			// Transcript files commonly live on shared NFS. Hooks and native
			// streams are immediate; an idle compatibility reader should not
			// issue two NFS opens/stats every second forever.
			return 2 * time.Second
		}
	}
	return 5 * time.Second
}

func (session *Session) publishDetectedAgent(agent, eventName string, pid int, startIdentity string) {
	payload, err := json.Marshal(map[string]any{
		"agent": agent,
		"event": map[string]any{
			"hook_event_name": eventName,
			"source":          "process-tree",
			"root_id":         fmt.Sprintf("%s:%d:%s", agent, pid, startIdentity),
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

func classifyAgentProcess(command, arguments string) string {
	return classifyHarnessProcess(command, arguments)
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

type outputReader struct {
	wake     *os.File // read end, readable once a stop is requested
	wakeFD   int
	stop     *os.File // write end
	done     chan struct{}
	stopped  bool // the reader returned because of a stop, not a PTY error
	gated    bool // reads wait in select, so a stop never interrupts a read
	stopOnce sync.Once
}

// startOutputReader reads the PTY on its own goroutine. Each read first waits
// in select(2) on the master and a wake pipe, so stopOutputReader can stop the
// reader between reads: bytes the reader has not consumed stay in the kernel
// for the next owner. select is used rather than poll because Darwin's poll
// does not support terminal devices. Without a wake pipe, or for a descriptor
// select cannot hold, the reader cannot be stopped and an upgrade is refused.
const selectableFDLimit = int(unsafe.Sizeof(unix.FdSet{})) * 8

func (session *Session) startOutputReader() {
	reader := &outputReader{done: make(chan struct{})}
	// Fd puts the master in blocking mode, so a read after select reports
	// readiness returns without parking on Go's poller.
	ptyFD := int(session.pty.Fd())
	if wake, stop, err := os.Pipe(); err == nil {
		if wakeFD := int(wake.Fd()); ptyFD < selectableFDLimit && wakeFD < selectableFDLimit {
			reader.wake, reader.wakeFD, reader.stop, reader.gated = wake, wakeFD, stop, true
		} else {
			_ = wake.Close()
			_ = stop.Close()
		}
	}
	session.mu.Lock()
	session.reader = reader
	session.mu.Unlock()
	go session.readOutput(reader, ptyFD)
}

func (session *Session) readOutput(reader *outputReader, ptyFD int) {
	defer close(reader.done)
	buffer := make([]byte, 32<<10)
	for {
		if reader.gated {
			wakeFD := reader.wakeFD
			var readable unix.FdSet
			readable.Set(ptyFD)
			readable.Set(wakeFD)
			if _, err := unix.Select(max(ptyFD, wakeFD)+1, &readable, nil, nil, nil); err != nil {
				if errors.Is(err, unix.EINTR) {
					continue
				}
				return
			}
			if readable.IsSet(wakeFD) {
				reader.stopped = true
				return
			}
		}
		count, err := session.pty.Read(buffer)
		if count > 0 {
			session.publish(buffer[:count])
		}
		if err != nil {
			return
		}
	}
}

// stopOutputReader stops the reader between reads and reports whether it did;
// false means the reader cannot be stopped or had already ended on a PTY
// error. Every byte read before the stop has been published.
func (session *Session) stopOutputReader() bool {
	session.mu.Lock()
	reader := session.reader
	session.mu.Unlock()
	if reader == nil || !reader.gated {
		return false
	}
	reader.stopOnce.Do(func() { _, _ = reader.stop.Write([]byte{0}) })
	<-reader.done
	_ = reader.wake.Close()
	_ = reader.stop.Close()
	return reader.stopped
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
	session.terminalModes.ingest(copyOfData)
	// Collect only fresh owned PTY output. Attach replay never updates metadata.
	// Detection is deliberately not answered until client/server ownership is negotiated.
	programEvents := session.programStatus.Feed(copyOfData)
	session.queueProgramStatusReplies(programEvents.DetectionQueries)
	if programEvents.Changed {
		session.programStatusRevision++
		session.broadcastProgramStatusLocked()
	}
	session.sequence++
	if session.outputChanged != nil {
		close(session.outputChanged)
	}
	session.outputChanged = make(chan struct{})
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
		session.replayTrimmed = true
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
	if session.programStatus.DropRunning() {
		session.programStatusRevision++
		session.broadcastProgramStatusLocked()
	}
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

func (session *Session) attach(
	lastSequence, lastEventSequence uint64,
	includeAgentEvents bool,
) (*client, []protocol.Frame, bool, bool, int) {
	return session.attachWithProgramStatus(lastSequence, lastEventSequence, includeAgentEvents, false)
}

func (session *Session) attachWithProgramStatus(lastSequence, lastEventSequence uint64, includeAgentEvents, includeProgramStatus bool) (*client, []protocol.Frame, bool, bool, int) {
	session.mu.Lock()
	defer session.mu.Unlock()
	viewer := newClient(512)
	viewer.includeAgentEvents = includeAgentEvents
	viewer.includeProgramStatus = includeProgramStatus
	session.clients[viewer] = struct{}{}
	session.broadcastClientCountLocked()
	outputReset := outputCursorNeedsReset(session.replay, lastSequence, session.sequence)
	if outputReset {
		lastSequence = 0
	}
	startRecord, startOffset := replayStart(session.replay, lastSequence)
	// A trimmed ring without a complete repaint has no reconstructable base.
	// Never hand a new parser an arbitrary mid-CSI/UTF-8 suffix. The attach
	// geometry repaint supplies fresh output; presentation reset is seq zero.
	unsafePrefix := lastSequence == 0 && len(session.replay) > 0 &&
		session.replayTrimmed && !hasPrimaryReplayBoundary(session.replay)
	frames := make([]protocol.Frame, 0, len(session.replay)-startRecord)
	if includeProgramStatus {
		frames = append(frames, session.programStatusFrameLocked(true))
	}
	if unsafePrefix {
		startRecord = len(session.replay)
		frames = append(frames, protocol.OutputFrame(0, []byte("\x1bc")))
	}
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
	// Reapply input modes after the bounded screen replay. Sequence zero is
	// presentation-only and cannot advance or invalidate the durable cursor.
	// Emitting this after replay makes it authoritative even when the retained
	// suffix contains an older push/pop command.
	if prelude := session.terminalModes.presentationPrelude(); len(prelude) > 0 {
		frames = append(frames, protocol.OutputFrame(0, prelude))
	}
	if session.exited {
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "exited", ExitCode: session.exitCode})
		frames = append(frames, status)
	}
	eventReset := false
	if includeAgentEvents {
		eventReset = session.eventCursorHasGap(lastEventSequence)
		if eventReset || lastEventSequence == 0 {
			frames = append(frames, session.agentStateSnapshot())
			if eventReset {
				lastEventSequence = 0
			}
		}
		frames = append(frames, session.eventFramesAfter(lastEventSequence)...)
	}
	return viewer, frames, outputReset, eventReset, len(session.clients)
}

func hasPrimaryReplayBoundary(replay []record) bool {
	var stream []byte
	for _, item := range replay {
		stream = append(stream, item.data...)
	}
	return safePrimaryScreenReplayStart(stream) >= 0
}

func (session *Session) needsFreshAttachReplay(sequence uint64) bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	return outputCursorNeedsReset(session.replay, sequence, session.sequence) ||
		(sequence == 0 && len(session.replay) > 0 && session.replayTrimmed &&
			!hasPrimaryReplayBoundary(session.replay))
}

func replayCursorHasGap(replay []record, sequence uint64) bool {
	if sequence == 0 || len(replay) == 0 {
		return false
	}
	return sequence+1 < replay[0].sequence
}

func outputCursorNeedsReset(replay []record, sequence, current uint64) bool {
	return sequence > current || replayCursorHasGap(replay, sequence)
}

// A new local renderer only needs the latest complete terminal redraw. Sending
// the full cursor-addressed history is both slower and incorrect when the pane
// has changed size since the TUI emitted it. Incremental reconnects stay exact.
func replayStart(replay []record, lastSequence uint64) (int, int) {
	if lastSequence != 0 {
		return 0, 0
	}
	var stream []byte
	recordStarts := make([]int, len(replay))
	for index, item := range replay {
		recordStarts[index] = len(stream)
		stream = append(stream, item.data...)
	}
	if latest := safePrimaryScreenReplayStart(stream); latest >= 0 {
		for index := len(recordStarts) - 1; index >= 0; index-- {
			if latest >= recordStarts[index] {
				return index, latest - recordStarts[index]
			}
		}
	}
	return 0, 0
}

func safePrimaryScreenReplayStart(stream []byte) int {
	// ED 3 erases saved scrollback, not the visible cells. It is not a
	// reconstruction boundary and must retain the preceding screen state.
	clears := [][]byte{[]byte("\x1b[2J"), []byte("\x1bc")}
	alternateEntries := [][]byte{[]byte("\x1b[?1049h"), []byte("\x1b[?1047h"), []byte("\x1b[?47h")}
	alternateExits := [][]byte{[]byte("\x1b[?1049l"), []byte("\x1b[?1047l"), []byte("\x1b[?47l")}
	inAlternateScreen := false
	latestPrimaryClear := -1

	for index := 0; index < len(stream); {
		if length := terminalSequenceLengthAt(stream, index, alternateEntries); length > 0 {
			inAlternateScreen = true
			index += length
			continue
		}
		if length := terminalSequenceLengthAt(stream, index, alternateExits); length > 0 {
			inAlternateScreen = false
			index += length
			continue
		}
		if !inAlternateScreen {
			if length := terminalSequenceLengthAt(stream, index, clears); length > 0 {
				latestPrimaryClear = index
				index += length
				continue
			}
		}
		index++
	}
	return latestPrimaryClear
}

func terminalSequenceLengthAt(stream []byte, index int, sequences [][]byte) int {
	for _, sequence := range sequences {
		if index+len(sequence) <= len(stream) && bytes.Equal(stream[index:index+len(sequence)], sequence) {
			return len(sequence)
		}
	}
	return 0
}

func (session *Session) detach(viewer *client) {
	session.mu.Lock()
	if _, attached := session.clients[viewer]; attached {
		delete(session.clients, viewer)
		session.broadcastClientCountLocked()
	}
	session.mu.Unlock()
}

// Client count is presentation state, not terminal history. It is emitted only
// when attachments change and never enters the replay ring, so observing the
// metric adds no polling or PTY work.
func (session *Session) broadcastClientCountLocked() {
	frame, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "clients", ClientCount: len(session.clients),
	})
	if err != nil {
		return
	}
	for viewer := range session.clients {
		select {
		case viewer.frames <- frame:
		default:
			// A diagnostic update must never evict a terminal client. The next
			// attachment change will refresh the value.
		}
	}
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

// Focus reports are generated by the terminal renderer, including during pane
// selection and reconnect. Keep them flowing without cancelling context work.
// Reconnect can coalesce complete reports in one frame. Keys, pastes and
// mixed or partial frames retain the human-takeover and guarded-input behavior.
func terminalFocusReport(data []byte) bool {
	if len(data) == 0 || len(data)%3 != 0 {
		return false
	}
	for offset := 0; offset < len(data); offset += 3 {
		if data[offset] != 0x1b || data[offset+1] != '[' || (data[offset+2] != 'I' && data[offset+2] != 'O') {
			return false
		}
	}
	return true
}

// Focus and SGR motion with no button pressed cannot edit or submit a draft.
// A reconnect backlog may combine them. Any other byte keeps human ownership
// checks, including wheel, drag, button releases and partial reports.
func terminalPassiveReport(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	for offset := 0; offset < len(data); {
		if offset+3 <= len(data) && terminalFocusReport(data[offset:offset+3]) {
			offset += 3
			continue
		}
		if length := terminalDeviceReply(data[offset:]); length > 0 {
			offset += length
			continue
		}
		if offset+3 >= len(data) || data[offset] != 0x1b || data[offset+1] != '[' || data[offset+2] != '<' {
			return false
		}
		offset += 3
		for field := 0; field < 3; field++ {
			start := offset
			var value uint64
			for offset < len(data) && data[offset] >= '0' && data[offset] <= '9' {
				if offset-start >= 10 {
					return false
				}
				value = value*10 + uint64(data[offset]-'0')
				if value > 1_000_000_000 {
					return false
				}
				offset++
			}
			if offset == start || offset >= len(data) {
				return false
			}
			// Cb <= 63 excludes both wheel (64) and extended buttons (128).
			if (field == 0 && (value > 63 || value&0x23 != 0x23)) || (field > 0 && value == 0) {
				return false
			}
			if (field < 2 && data[offset] != ';') || (field == 2 && data[offset] != 'M') {
				return false
			}
			offset++
		}
	}
	return true
}

// terminalDeviceReply returns the length of one complete terminal reply to a
// program's capability query at the start of data, or 0. The terminal sends
// these by itself (for example when an agent or editor starts), so they are
// not human input. Only reply grammars that no key or mouse report produces
// are accepted: DA1/DA2 (CSI ? ... c, CSI > ... c), DECRPM (CSI ? n ; n $ y),
// the kitty keyboard flags reply (CSI ? n u), window-size reports
// (CSI 4|6|8|9 ; n ; n t) and cursor-position reports, except those that are
// identical to modified F3 (CSI 1 ; 2..16 R).
func terminalDeviceReply(data []byte) int {
	if len(data) < 4 || data[0] != 0x1b || data[1] != '[' {
		return 0
	}
	end := 2
	for end < len(data) && end < 64 && (data[end] < 0x40 || data[end] > 0x7e) {
		end++
	}
	if end >= len(data) || end >= 64 {
		return 0
	}
	params, final := data[2:end], data[end]
	digits := func(b []byte, separators string) bool {
		if len(b) == 0 {
			return false
		}
		for _, c := range b {
			if (c < '0' || c > '9') && !strings.ContainsRune(separators, rune(c)) {
				return false
			}
		}
		return b[0] != ';' && b[len(b)-1] != ';'
	}
	fields := func(b []byte) []int {
		var out []int
		for _, part := range strings.Split(string(b), ";") {
			if len(part) == 0 || len(part) > 6 {
				return nil
			}
			value, err := strconv.Atoi(part)
			if err != nil {
				return nil
			}
			out = append(out, value)
		}
		return out
	}
	ok := false
	switch final {
	case 'c':
		ok = len(params) > 1 && (params[0] == '?' || params[0] == '>') && digits(params[1:], ";")
	case 'y':
		ok = len(params) > 3 && params[0] == '?' && params[len(params)-1] == '$' &&
			len(fields(params[1:len(params)-1])) == 2
	case 'u':
		ok = len(params) > 1 && params[0] == '?' && digits(params[1:], "")
	case 't':
		values := fields(params)
		ok = len(values) == 3 && (values[0] == 4 || values[0] == 6 || values[0] == 8 || values[0] == 9)
	case 'R':
		values := fields(params)
		ok = len(values) == 2 && values[0] >= 1 && values[1] >= 1 && !(values[0] == 1 && values[1] >= 2 && values[1] <= 16)
	}
	if !ok {
		return 0
	}
	return end + 1
}

func (session *Session) input(data []byte) error {
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	humanInput := len(data) > 0 && !terminalPassiveReport(data)
	if session.rotationControlled && humanInput {
		if session.rotationGuardInstalled {
			return errors.New("rotation owns terminal input")
		}
		session.rotationHumanInputSeen = true
	}
	session.mu.Lock()
	exited := session.exited
	supervisor := session.hostRotation
	session.mu.Unlock()
	if exited {
		return io.ErrClosedPipe
	}
	if humanInput {
		session.humanInputRevision++
		if supervisor != nil {
			supervisor.humanInput()
		}
	}
	_, err := session.pty.Write(data)
	return err
}

func (session *Session) acknowledgedInput(clientID [16]byte, sequence uint64, data []byte) error {
	return session.acknowledgedInputFrom(clientID, sequence, data, false)
}

// acknowledgedInputFrom writes one acknowledged input frame. Automation input
// is Relay's own native maintenance or compiled-prompt keystrokes: it is not a
// human takeover and does not advance humanInputRevision, but it still cancels
// any outstanding rotation decision and is refused while rotation owns input.
func (session *Session) acknowledgedInputFrom(clientID [16]byte, sequence uint64, data []byte, automation bool) error {
	// PTY writes may block when the foreground process stops draining its input.
	// Serialize those writes independently so output publication, snapshots,
	// reconnects, status and agent events never wait behind terminal input.
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	session.mu.Lock()
	if session.exited {
		session.mu.Unlock()
		return io.ErrClosedPipe
	}
	if sequence <= session.inputSequences[clientID] {
		session.mu.Unlock()
		return nil
	}
	active := len(data) > 0 && !terminalPassiveReport(data)
	humanInput := active && !automation
	if session.rotationControlled && active && session.rotationGuardInstalled {
		session.mu.Unlock()
		return errors.New("rotation owns terminal input")
	}
	if session.rotationControlled && humanInput {
		session.rotationHumanInputSeen = true
	}
	supervisor := session.hostRotation
	session.mu.Unlock()
	if humanInput {
		session.humanInputRevision++
		if supervisor != nil {
			supervisor.humanInput()
		}
	} else if active {
		session.automationInputRevision++
		if supervisor != nil {
			supervisor.automationInput()
		}
	}
	remaining := data
	for len(remaining) > 0 {
		written, err := session.pty.Write(remaining)
		if err != nil {
			return err
		}
		remaining = remaining[written:]
	}
	session.mu.Lock()
	session.inputSequences[clientID] = sequence
	session.mu.Unlock()
	return nil
}

func (session *Session) resize(cols, rows uint16) error {
	session.resizeMu.Lock()
	defer session.resizeMu.Unlock()
	return session.resizeLocked(cols, rows)
}

func (session *Session) resizeLocked(cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	return pty.Setsize(session.pty, &pty.Winsize{Cols: cols, Rows: rows})
}

func (session *Session) signalForegroundResize() error {
	var processGroup int32
	_, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		session.pty.Fd(),
		uintptr(syscall.TIOCGPGRP),
		uintptr(unsafe.Pointer(&processGroup)),
	)
	if errno != 0 {
		return errno
	}
	if processGroup <= 0 {
		return nil
	}
	return syscall.Kill(-int(processGroup), syscall.SIGWINCH)
}

type terminalGridSize struct {
	cols uint16
	rows uint16
}

// Attach output is parsed on the requested grid. A temporary row change can
// produce cursor-addressed bytes for a grid the renderer never had. Repaint
// an unchanged agent grid with an explicit SIGWINCH instead.
func attachResizeSteps(
	currentCols, currentRows, cols, rows uint16,
	pulseUnchanged bool,
) []terminalGridSize {
	target := terminalGridSize{cols: cols, rows: rows}
	if currentCols != cols || currentRows != rows || cols == 0 || rows == 0 {
		return []terminalGridSize{target}
	}
	if !pulseUnchanged {
		return nil
	}
	return []terminalGridSize{target}
}

// resizeForAttach gives an interactive program a small, bounded opportunity
// to append its new-grid redraw to replay. Shells that emit nothing take the
// short quiet path; continuously updating programs never delay attach beyond
// the hard deadline.
func (session *Session) resizeForAttach(
	cols, rows uint16,
	pulseUnchanged bool,
) (uint64, bool) {
	if cols == 0 || rows == 0 {
		return 0, false
	}
	session.resizeMu.Lock()
	defer session.resizeMu.Unlock()
	before, _, _, _ := session.snapshot()
	current, _ := pty.GetsizeFull(session.pty)
	currentCols, currentRows := uint16(0), uint16(0)
	if current != nil {
		currentCols, currentRows = current.Cols, current.Rows
	}
	repaintUnchanged := pulseUnchanged && session.requiresAttachRepaint()
	steps := attachResizeSteps(
		currentCols, currentRows, cols, rows,
		repaintUnchanged,
	)
	if len(steps) == 0 {
		return before, false
	}
	for _, step := range steps {
		if session.resizeLocked(step.cols, step.rows) != nil {
			return before, false
		}
	}
	if repaintUnchanged && currentCols == cols && currentRows == rows {
		if err := session.signalForegroundResize(); err != nil && !errors.Is(err, syscall.ESRCH) {
			return before, false
		}
	}
	_, repainted := session.waitForResizeRepaint(before)
	return before, repainted
}

func (session *Session) requiresAttachRepaint() bool {
	session.mu.Lock()
	structuredAgentActive := len(session.activeAgentRoots) > 0 || len(session.activeSubagents) > 0
	rootPID := 0
	if session.process != nil && session.process.Process != nil {
		rootPID = session.process.Process.Pid
	}
	session.mu.Unlock()
	if structuredAgentActive {
		return true
	}
	if rootPID <= 0 {
		return false
	}
	return descendantAgent(rootPID) != ""
}

// resizeForViewportCommit is the live presentation barrier. Unlike attach it
// does not perturb the requested grid: it applies the final winsize once,
// explicitly notifies the active foreground process group, and acknowledges
// the output sequence after that TUI's repaint has reached the session ring.
func (session *Session) resizeForViewportCommit(cols, rows uint16) (uint64, error) {
	session.resizeMu.Lock()
	defer session.resizeMu.Unlock()
	before, _, _, _ := session.snapshot()
	current, currentErr := pty.GetsizeFull(session.pty)
	knownCurrent := currentErr == nil && current != nil
	currentCols, currentRows := uint16(0), uint16(0)
	if knownCurrent {
		currentCols, currentRows = current.Cols, current.Rows
	}
	if err := session.resizeLocked(cols, rows); err != nil {
		return before, err
	}
	// Linux already delivers SIGWINCH for a changed TIOCSWINSZ. Send one
	// explicitly only when the requested grid was unchanged (or could not be
	// queried), otherwise readline and primary-screen TUIs receive the resize
	// twice and can append duplicate prompts or leave an intermediate cursor.
	if viewportResizeNeedsExplicitSignal(
		currentCols, currentRows, cols, rows, knownCurrent,
	) {
		if err := session.signalForegroundResize(); err != nil && !errors.Is(err, syscall.ESRCH) {
			return before, err
		}
	}
	sequence, _ := session.waitForResizeRepaint(before)
	return sequence, nil
}

func viewportResizeNeedsExplicitSignal(
	currentCols, currentRows, cols, rows uint16,
	knownCurrent bool,
) bool {
	return !knownCurrent || (currentCols == cols && currentRows == rows)
}

func (session *Session) waitForResizeRepaint(before uint64) (uint64, bool) {
	started := time.Now()
	deadline := started.Add(150 * time.Millisecond)
	quietSince := started
	lastSequence := before
	for {
		sequence, exited, changed := session.outputSequenceWaitState()
		if sequence != lastSequence {
			lastSequence = sequence
			quietSince = time.Now()
		}
		if exited {
			return sequence, sequence != before
		}
		now := time.Now()
		quietDeadline := started.Add(20 * time.Millisecond)
		if sequence != before {
			quietDeadline = quietSince.Add(15 * time.Millisecond)
		}
		wakeAt := quietDeadline
		if deadline.Before(wakeAt) {
			wakeAt = deadline
		}
		if !now.Before(wakeAt) {
			return sequence, sequence != before
		}
		timer := time.NewTimer(time.Until(wakeAt))
		select {
		case <-changed:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		case <-timer.C:
		}
	}
}

func (session *Session) outputSequenceWaitState() (uint64, bool, <-chan struct{}) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.outputChanged == nil {
		session.outputChanged = make(chan struct{})
	}
	return session.sequence, session.exited, session.outputChanged
}

func (session *Session) agentEvent(payload []byte) {
	// Preserve event/journal order while allowing terminal output, input lease
	// changes, and attachment snapshots to proceed during disk I/O.
	session.eventMu.Lock()
	defer session.eventMu.Unlock()
	hash := semanticAgentEventHash(payload)
	session.mu.Lock()
	if session.eventHashes == nil {
		session.eventHashes = make(map[[32]byte]struct{})
	}
	if _, duplicate := session.eventHashes[hash]; duplicate {
		session.mu.Unlock()
		return
	}
	sequence := session.eventSequence + 1
	journal := session.eventJournal
	session.mu.Unlock()

	payload = indexedAgentPayload(payload, sequence)
	var journalErr error
	if journal != nil {
		journalErr = journal.append(sequence, payload)
	}

	frame := protocol.Frame{Type: protocol.AgentEvent, Payload: append([]byte(nil), payload...)}
	session.mu.Lock()
	defer func() {
		supervisor := session.hostRotation
		session.mu.Unlock()
		if supervisor != nil {
			supervisor.event(payload, journal != nil && journalErr == nil)
		}
	}()
	session.eventHashes[hash] = struct{}{}
	session.eventHashOrder = append(session.eventHashOrder, hash)
	if len(session.eventHashOrder) > 4_096 {
		oldest := session.eventHashOrder[0]
		session.eventHashOrder = session.eventHashOrder[1:]
		delete(session.eventHashes, oldest)
	}
	session.eventSequence = sequence
	if journalErr != nil {
		session.eventJournalError = journalErr.Error()
		fmt.Fprintf(os.Stderr, "relay: agent journal append failed: %v\n", journalErr)
	}
	session.appendEventHistory(frame)
	session.latestAgentEvent = append(session.latestAgentEvent[:0], payload...)
	session.updateActiveSubagents(payload)
	for viewer := range session.clients {
		if frame.Type == protocol.AgentEvent && !viewer.includeAgentEvents {
			continue
		}
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
		return sequence > session.eventSequence
	}
	return sequence > session.eventSequence ||
		sequence+1 < indexedAgentSequence(session.eventHistory[0].Payload)
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
	session.eventMu.Lock()
	defer session.eventMu.Unlock()
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
		if !processRootStartedAfterEvent(session.activeAgentRoots[rootID], payload) {
			delete(session.activeAgentRoots, rootID)
		}
		for _, legacyRoot := range legacyEndedProcessRoots(session.activeAgentRoots, payload) {
			delete(session.activeAgentRoots, legacyRoot)
		}
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

// programStatusSnapshot is untrusted display metadata, independent of native
// provider identity, permissions, input ownership and transport status frames.
func (session *Session) programStatusSnapshot() []programstatus.Record {
	session.mu.Lock()
	defer session.mu.Unlock()
	return session.programStatus.Snapshot()
}

// programStatusFrameLocked provides complete replacement state, including an
// explicit empty array on clear. Revision is a session-local freshness cursor.
// Replay snapshots never imply a new attention event.
func (session *Session) programStatusFrameLocked(replay bool) protocol.Frame {
	records := session.programStatus.Snapshot()
	if records == nil {
		records = make([]programstatus.Record, 0)
	}
	frame, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "program_status", ProgramStatus: &records,
		ProgramStatusRevision: session.programStatusRevision, ProgramStatusReplay: replay,
	})
	return frame
}

func (session *Session) broadcastProgramStatusLocked() {
	frame := session.programStatusFrameLocked(false)
	for viewer := range session.clients {
		if !viewer.includeProgramStatus {
			continue
		}
		select {
		case viewer.frames <- frame:
		default:
			viewer.markLagged()
			delete(session.clients, viewer)
		}
	}
}

// Only fresh owned PTY output reaches this queue. Replays, report text and
// client input never generate device replies. Pending amplification is bounded.
func (session *Session) queueProgramStatusReplies(count int) {
	if session.programStatusReplies == nil || count <= 0 {
		return
	}
	if count > 32 {
		count = 32
	}
	select {
	case session.programStatusReplies <- count:
	default:
	}
}

// Device responses do not acquire a client lease or count as human input.
// They contain the fixed protocol literal only, serialized with existing PTY writes.
func (session *Session) writeProgramStatusReplies() {
	for {
		select {
		case <-session.done:
			return
		case count := <-session.programStatusReplies:
			session.inputMu.Lock()
			session.mu.Lock()
			exited := session.exited
			session.mu.Unlock()
			if !exited && session.pty != nil {
				_, _ = session.pty.Write(bytes.Repeat([]byte(programstatus.DetectionReply), count))
			}
			session.inputMu.Unlock()
		}
	}
}

// Negotiate on the authenticated connection after attach. Older supervisors
// forward this frame unchanged even when they strip newer Hello fields.
// Replay and subsequent fresh updates share the same lock and bounded queue.
func (session *Session) setProgramStatusObservation(viewer *client, enabled bool) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if _, attached := session.clients[viewer]; !attached || viewer.includeProgramStatus == enabled {
		return
	}
	viewer.includeProgramStatus = enabled
	if !enabled {
		return
	}
	select {
	case viewer.frames <- session.programStatusFrameLocked(true):
	default:
		viewer.markLagged()
		delete(session.clients, viewer)
	}
}
