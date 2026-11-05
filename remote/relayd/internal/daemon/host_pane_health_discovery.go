package daemon

// Native port of the host_agent_conversation.py functions that
// host_agent_maintenance.py reaches through its `reader` (the probe never
// reads conversation history). The functions are fields so tests can replace
// process and command observations, as the Python reader is a module dict.
//
// The communication runtime keeps its own copy of agent_conversation.py for
// snapshots; nothing here is shared with it yet.

import (
	"bufio"
	"context"
	"io"
	"math/big"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var (
	phConversationID   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	phConversationUUID = regexp.MustCompile(`^[0-9a-fA-F-]{32,36}$`)
	phClaudeVersionTag = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
)

const (
	phMaxLine   = 16 << 20
	phRunLimit  = 2 << 20
	phInventory = 16384
)

// phProcess is one inventory row: (parent, name).
type phProcess struct {
	parent int64
	name   string
}

// phProcesses is the inventory dict: pid -> (parent, name) in ps order.
type phProcesses struct {
	order []int64
	rows  map[int64]phProcess
}

func (p *phProcesses) set(pid int64, row phProcess) {
	if _, ok := p.rows[pid]; !ok {
		p.order = append(p.order, pid)
	}
	p.rows[pid] = row
}

// lookup is `pid in processes` with Python's numeric key equality.
func (p *phProcesses) lookup(pid any) (int64, bool) {
	phHashKey(pid)
	key, ok := phIntKey(pid)
	if !ok {
		return 0, false
	}
	_, found := p.rows[key]
	return key, found
}

// phIntKey maps a hashable value to the int dict key it equals, if any.
func phIntKey(v any) (int64, bool) {
	switch t := v.(type) {
	case int64:
		return t, true
	case int:
		return int64(t), true
	case bool:
		if t {
			return 1, true
		}
		return 0, true
	case float64:
		if t == float64(int64(t)) {
			return int64(t), true
		}
	}
	return 0, false
}

type phReader struct {
	ctx      context.Context
	isLinux  bool
	uid      int
	env      []string
	run      func(args []string, timeout float64) string
	identity func(pid any) string
	// inventory, provider and ancestors are agent_conversation's functions.
	inventory       func() *phProcesses
	provider        func(name string) string
	rootForPane     func(pane string) int64
	agent           func(root int64, binary, pane string) (int64, string)
	accountOverride func(pid int64, kind string) string
	binding         func(binary, pane string, pid int64, kind string) *pyObject
	transcript      func(pid int64, kind string) (string, string)
	metadata        func(path, kind string) any
	codexLifecycle  func(row any) *pyList
	privateFile     func(path string, limit int64) ([]byte, os.FileInfo)
	openPaths       func(pid int64) []string
	processVariable func(pid int64, name string) string
	epoch           func(pid int64) float64
	now             func() float64
	// arguments and cwd are agent_maintenance's process_arguments and process_cwd.
	readlink     func(path string) (string, error)
	nativeClaude func(pid int64, useInstalled bool) string
	arguments    func(pid int64) []string
	cwd          func(pid int64) string
}

func newPHReader(ctx context.Context) *phReader {
	r := &phReader{ctx: ctx, isLinux: phPlatformLinux, uid: os.Getuid(), env: phConversationEnvironment(), now: phTime}
	r.run = r.runCommand
	r.identity = r.processIdentity
	r.inventory = r.processInventory
	r.provider = r.processProvider
	r.rootForPane = r.paneRoot
	r.agent = r.paneAgent
	r.accountOverride = r.processAccountOverride
	r.binding = r.authenticatedBinding
	r.transcript = r.boundTranscript
	r.metadata = r.transcriptMetadata
	r.codexLifecycle = phCodexLifecycle
	r.privateFile = r.ownerPrivateFile
	r.openPaths = r.processOpenPaths
	r.processVariable = r.processEnvironmentVariable
	r.epoch = r.processEpoch
	r.readlink = os.Readlink
	r.nativeClaude = r.nativeClaudeExecutable
	r.arguments = phProcessArguments
	r.cwd = phProcessCwd
	return r
}

func phTime() float64 { return float64(time.Now().UnixNano()) / 1e9 }

// phConversationEnvironment is dict(os.environ, LC_ALL="C", LANG="C",
// TZ="UTC") in the former Python backend, whose os.environ was relayd's
// host-text environment.
func phConversationEnvironment() []string {
	base := hostRotationTextEnvironment()
	if base == nil {
		base = os.Environ()
	}
	result := []string{}
	for _, entry := range base {
		if !strings.HasPrefix(entry, "LC_ALL=") && !strings.HasPrefix(entry, "LANG=") && !strings.HasPrefix(entry, "TZ=") {
			result = append(result, entry)
		}
	}
	return append(result, "LC_ALL=C", "LANG=C", "TZ=UTC")
}

func phSeconds(seconds float64) time.Duration { return time.Duration(seconds * float64(time.Second)) }

// runCommand is run(args, timeout): bounded stdout, stdin and stderr closed,
// exit status 0 or 1 accepted.
func (r *phReader) runCommand(args []string, timeout float64) string {
	command := exec.Command(args[0], args[1:]...)
	command.Env = r.env
	output, err := command.StdoutPipe()
	if err != nil {
		phRaiseOS(err)
	}
	if err := command.Start(); err != nil {
		phRaiseOS(err)
	}
	deadline := time.Now().Add(phSeconds(timeout))
	type chunk struct {
		data []byte
		err  error
	}
	chunks := make(chan chunk)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			buffer := make([]byte, 65536)
			n, err := output.Read(buffer)
			select {
			case chunks <- chunk{buffer[:n], err}:
			case <-stop:
				return
			}
			if err != nil {
				return
			}
		}
	}()
	kill := func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}
	var cancelled <-chan struct{}
	if r.ctx != nil {
		cancelled = r.ctx.Done()
	}
	data := []byte{}
	for done := false; !done; {
		timer := time.NewTimer(time.Until(deadline))
		select {
		case part := <-chunks:
			timer.Stop()
			data = append(data, part.data...)
			if len(data) > phRunLimit {
				kill()
				phRaise(phUnbound, "Process inventory exceeded its limit.")
			}
			done = part.err != nil
		case <-timer.C:
			kill()
			phRaise(phTimeout, "Command timed out")
		case <-cancelled:
			timer.Stop()
			kill()
			phRaise(phTimeout, "Command cancelled")
		}
	}
	remaining := time.Until(deadline)
	if remaining < 10*time.Millisecond {
		remaining = 10 * time.Millisecond
	}
	r.waitCommand(command, remaining)
	if code := command.ProcessState.ExitCode(); code != 0 && code != 1 {
		phRaise(phUnbound, "Process discovery is unavailable.")
	}
	return phDecodeReplace(data)
}

// waitCommand waits after stdout has been drained. It only kills the child
// represented by command, and joins the one Wait call before returning.
func (r *phReader) waitCommand(command *exec.Cmd, remaining time.Duration) {
	var cancelled <-chan struct{}
	if r.ctx != nil {
		cancelled = r.ctx.Done()
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case <-waited:
	case <-timer.C:
		_ = command.Process.Kill()
		<-waited
		phRaise(phTimeout, "Command timed out")
	case <-cancelled:
		_ = command.Process.Kill()
		<-waited
		phRaise(phTimeout, "Command cancelled")
	}
	// Completion and cancellation can both be ready. Never admit successful
	// output when cancellation is already observable at this boundary.
	select {
	case <-cancelled:
		phRaise(phTimeout, "Command cancelled")
	default:
	}
}

// processIdentity is identity(pid).
func (r *phReader) processIdentity(pid any) string {
	if r.isLinux {
		path := "/proc/" + pyStr(pid)
		if phStatUID(phMustStat(path, true)) != r.uid {
			phRaise(phUnbound, "Process owner changed.")
		}
		data, err := os.ReadFile(path + "/stat")
		if err != nil {
			phRaiseOS(err)
		}
		line := phDecodeUTF8(data)
		closing := strings.LastIndex(line, ")")
		fields := phSplit(line[min(closing+2, len(line)):], -1)
		if len(fields) <= 19 {
			phRaise(phIndexError, "list index out of range")
		}
		return "linux:" + fields[19]
	}
	line := phSplit(phStrip(r.run([]string{"/bin/ps", "-p", pyStr(pid), "-o", "uid=,lstart="}, 4)), 1)
	if len(line) != 2 || phIntText(line[0]) != int64(r.uid) {
		phRaise(phUnbound, "Process owner changed.")
	}
	return "darwin:" + line[1]
}

// phIntText is int(text) for decimal text.
func phIntText(text string) int64 {
	value, err := strconv.ParseInt(strings.ReplaceAll(phStrip(text), "_", ""), 10, 64)
	if err != nil {
		phRaise(phValueError, "invalid literal for int() with base 10: "+pyStringRepr(text))
	}
	return value
}

// processEpoch is epoch(pid): Linux USER_HZ is fixed at 100 for userspace.
func (r *phReader) processEpoch(pid int64) float64 {
	if r.isLinux {
		data, err := os.ReadFile("/proc/stat")
		if err != nil {
			phRaiseOS(err)
		}
		boot := int64(-1)
		for _, line := range strings.SplitAfter(string(data), "\n") {
			if strings.HasPrefix(line, "btime ") {
				boot = phIntText(phSplit(line, -1)[1])
				break
			}
		}
		if boot < 0 {
			phRaise(phRuntimeError, "StopIteration")
		}
		start := phIntText(strings.SplitN(r.identity(pid), ":", 2)[1])
		return float64(boot) + float64(start)/100
	}
	observed, err := time.Parse("Mon Jan _2 15:04:05 2006", r.identity(pid)[7:])
	if err != nil {
		phRaise(phValueError, "time data does not match format")
	}
	return float64(observed.Unix())
}

// processInventory is inventory().
func (r *phReader) processInventory() *phProcesses {
	text := r.run([]string{"/bin/ps", "-u", pyStr(int64(r.uid)), "-o", "pid=,ppid=,uid=,comm="}, 4)
	result := &phProcesses{rows: map[int64]phProcess{}}
	for _, line := range phSplitLines(text) {
		fields := phSplit(line, 3)
		if len(fields) != 4 {
			continue
		}
		numbers := make([]int64, 3)
		valid := true
		for i := range numbers {
			if phCatch(func() { numbers[i] = phIntText(fields[i]) }, phValueError) != nil {
				valid = false
				break
			}
		}
		if !valid {
			continue
		}
		pid, parent, uid := numbers[0], numbers[1], numbers[2]
		if uid == int64(r.uid) && pid > 1 {
			name := fields[3]
			// A pinned native Claude exec is named after its version in Linux
			// comm; resolve that process's actual image.
			if r.isLinux && phClaudeVersionTag.MatchString(name) {
				if executable, err := os.Readlink("/proc/" + pyStr(pid) + "/exe"); err == nil && r.provider(executable) == "claude" {
					name = executable
				}
			}
			result.set(pid, phProcess{parent: parent, name: name})
		}
	}
	if len(result.order) > phInventory {
		phRaise(phUnbound, "Process inventory exceeded its limit.")
	}
	return result
}

// ownerPrivateFile is private_file(path, limit).
func (r *phReader) ownerPrivateFile(path string, limit int64) ([]byte, os.FileInfo) {
	file := phOpenNoFollow(path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	if phStatUID(info) != r.uid || info.Mode().Perm()&0o022 != 0 || !info.Mode().IsRegular() || info.Size() > limit {
		phRaise(phUnbound, "The source file is not an owner-controlled regular file.")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		phRaiseOS(err)
	}
	return data, info
}

func phOpenNoFollow(path string) *os.File {
	// O_NONBLOCK: a FIFO opens without a writer and is then rejected as
	// not regular by every caller, instead of blocking the probe.
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		phRaiseOS(err)
	}
	return file
}

// phWorkerManifests is the worker manifest lookup shared by root_for_pane,
// recovery_owner and worker_observation.
func phWorkerManifests(pane string) []string {
	state := phJoin(phEnv("XDG_STATE_HOME", phJoin(phHome(), ".local/state")), "relay/workers")
	recovered := phGlob(state, "recovered-*/"+pane+".json")
	if len(recovered) > 3 {
		recovered = recovered[:3]
	}
	if len(recovered) > 0 {
		return recovered
	}
	return []string{phJoin(state, pane+".json")}
}

// paneRoot is root_for_pane(pane).
func (r *phReader) paneRoot(pane string) int64 {
	paths := phWorkerManifests(pane)
	if len(paths) != 1 {
		phRaise(phUnbound, "Multiple recovered workers claim this pane.")
	}
	data, _ := r.privateFile(paths[0], 65536)
	record := phLoadsBytes(data)
	if !pyEqual(phGet(record, "session_id", nil), pane) || !pyEqual(phGet(record, "state", nil), "running") {
		phRaise(phUnbound, "No live durable worker owns this pane.")
	}
	worker, shell := phPyInt(phIndex(record, "worker_pid")), phPyInt(phIndex(record, "shell_pid"))
	if r.isLinux && r.identity(worker) != "linux:"+pyStr(phIndex(record, "worker_start_time")) {
		phRaise(phUnbound, "The worker process incarnation changed.")
	}
	processes := r.inventory()
	if _, ok := processes.lookup(shell); !ok || !phContainsValue(r.ancestorsOf(shell, processes), worker) {
		phRaise(phUnbound, "The pane shell is not owned by its worker.")
	}
	return shell
}

// phPyInt is int(value) for the values a JSON record can hold.
func phPyInt(v any) int64 {
	switch t := v.(type) {
	case int64:
		return t
	case int:
		return int64(t)
	case bool:
		if t {
			return 1
		}
		return 0
	case *big.Int:
		return -1 // never a live process: every lookup by it fails.
	case float64:
		if t != t {
			phRaise(phValueError, "cannot convert float NaN to integer")
		}
		if t > 9.2e18 || t < -9.2e18 {
			return -1
		}
		return int64(t)
	case string:
		return phIntText(t)
	}
	phRaise(phTypeError, "int() argument must be a string or a number")
	return 0
}

func phContainsValue(values []any, item any) bool {
	for _, value := range values {
		if pyEqual(value, item) {
			return true
		}
	}
	return false
}

// ancestorsOf is ancestors(pid, processes); pid keeps its original value at
// the head of the chain, as Python's list does.
func (r *phReader) ancestorsOf(pid any, processes *phProcesses) []any {
	var result []any
	current := pid
	for len(result) < 64 {
		if c, ok := pyCompareNumbers(current, int64(1)); !ok {
			phRaise(phTypeError, "'>' not supported")
		} else if c <= 0 {
			break
		}
		key, found := processes.lookup(current)
		if !found {
			break
		}
		if phContainsValue(result, current) {
			phRaise(phUnbound, "Invalid process ancestry.")
		}
		result = append(result, current)
		current = processes.rows[key].parent
	}
	return result
}

// processProvider is provider(name); "" stands for None.
func (r *phReader) processProvider(name string) string {
	base := strings.ToLower(phName(name))
	switch base {
	case "codex", "codex.exe":
		return "codex"
	case "claude", "claude.exe":
		return "claude"
	}
	if strings.HasPrefix(name, "/") {
		var versions, resolved string
		if phCatch(func() {
			versions = phResolve(phJoin(phHome(), ".local/share/claude/versions"), true)
			resolved = phResolve(name, true)
		}, phOSError, phRuntimeError) != nil {
			return ""
		}
		if phParent(resolved) == versions && phName(resolved) == phName(name) && phIsFile(resolved) {
			return "claude"
		}
	}
	return ""
}

// paneAgent is agent(root, binary, pane).
func (r *phReader) paneAgent(root int64, binary, pane string) (int64, string) {
	processes := r.inventory()
	if _, ok := processes.rows[root]; !ok {
		phRaise(phUnbound, "The pane foreground process is no longer running.")
	}
	var candidates []int64
	kinds := map[int64]string{}
	for _, pid := range processes.order {
		if phContainsValue(r.ancestorsOf(pid, processes), root) && r.provider(processes.rows[pid].name) != "" {
			candidates = append(candidates, pid)
			kinds[pid] = r.provider(processes.rows[pid].name)
		}
	}
	var top []int64
	for _, pid := range candidates {
		nested := false
		for _, parent := range r.ancestorsOf(pid, processes)[1:] {
			if _, ok := kinds[parent.(int64)]; ok {
				nested = true
				break
			}
		}
		if !nested {
			top = append(top, pid)
		}
	}
	if len(top) != 1 {
		// Official Node launchers can put the native frontend and its private
		// app server in sibling subtrees. Select neither by process recency:
		// the live stock proxy already proves the exact frontend incarnation.
		if binary != "" && pane != "" {
			var selected int64
			found := false
			phCatch(func() {
				initial := phLoads(r.run([]string{binary, "agent-binding", pane}, 5))
				producer := phGet(initial, "producer", newPyObject())
				pid := phGet(producer, "process_id", nil)
				if !phStrictInt(pid) {
					return
				}
				phHashKey(pid)
				key, ok := phIntKey(pid)
				if !ok || kinds[key] != "codex" {
					return
				}
				initial.(*pyObject).Delete("observed_at")
				verified := r.binding(binary, pane, key, "codex")
				if pyEqual(verified, initial) && phStockProxyIdentity(verified) != "" &&
					pyEqual(r.nativeProcessStart(binary, pane, key, "codex"), phGet(producer, "process_start", nil)) {
					selected, found = key, true
				}
			}, phUnbound, phOSError, phValueError, phTimeout)
			if found {
				return selected, "codex"
			}
		}
		phRaise(phUnbound, "An exact, unique foreground agent is required.")
	}
	return top[0], kinds[top[0]]
}

// transcriptMetadata is metadata(path, kind): the session id or nil.
func (r *phReader) transcriptMetadata(path, kind string) any {
	file := phOpenNoFollow(path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	if phStatUID(info) != r.uid || info.Mode().Perm()&0o022 != 0 || !info.Mode().IsRegular() {
		return nil
	}
	reader := bufio.NewReader(file)
	for i := 0; i < 16; i++ {
		line := phReadLine(reader, phMaxLine+1)
		if len(line) == 0 || len(line) > phMaxLine {
			return nil
		}
		var row any
		if phCatch(func() { row = phLoadsBytes(line) }, phValueError) != nil {
			return nil
		}
		if !phIsDict(row) {
			return nil
		}
		if kind == "codex" && pyEqual(phGet(row, "type", nil), "session_meta") {
			payload := phGet(row, "payload", newPyObject())
			if phIsDict(phGet(payload, "source", nil)) {
				return nil
			}
			sid := phGet(payload, "id", "")
			if text, ok := sid.(string); ok && phConversationUUID.MatchString(text) {
				return text
			}
			return nil
		}
		if kind == "claude" && !pyTruthy(phGet(row, "isSidechain", nil)) {
			if text, ok := phGet(row, "sessionId", "").(string); ok && phConversationUUID.MatchString(text) {
				return text
			}
		}
	}
	return nil
}

// phReadLine is file.readline(limit) on a binary stream.
func phReadLine(reader *bufio.Reader, limit int) []byte {
	var line []byte
	for len(line) < limit {
		b, err := reader.ReadByte()
		if err != nil {
			if err != io.EOF {
				phRaiseOS(err)
			}
			break
		}
		line = append(line, b)
		if b == '\n' {
			break
		}
	}
	return line
}

// processEnvironmentVariable is process_variable(pid, name).
func (r *phReader) processEnvironmentVariable(pid int64, name string) string {
	entries := phProcessEnvironment(r, pid)
	prefix := name + "="
	var values [][]byte
	for _, entry := range entries {
		if strings.HasPrefix(string(entry), prefix) {
			values = append(values, entry[len(prefix):])
		}
	}
	if len(values) > 1 {
		phRaise(phUnbound, "Ambiguous process environment.")
	}
	value := ""
	if len(values) == 1 {
		value = phDecodeUTF8(values[0])
	}
	if value != "" && (!strings.HasPrefix(value, "/") || phNormpath(value) != value) {
		phRaise(phUnbound, "Invalid account directory.")
	}
	return value
}

func phAccountVariable(kind string) string {
	switch kind {
	case "claude":
		return "CLAUDE_CONFIG_DIR"
	case "codex":
		return "CODEX_HOME"
	}
	phRaise(phKeyError, kind)
	return ""
}

func (r *phReader) processAccountOverride(pid int64, kind string) string {
	return r.processVariable(pid, phAccountVariable(kind))
}

// conversationAccountRoot is agent_conversation.account_root(pid, kind).
func (r *phReader) conversationAccountRoot(pid int64, kind string) string {
	var override string
	if phCatch(func() { override = r.accountOverride(pid, kind) }, phOSError, phValueError, phIndexError, phUnbound) != nil {
		override = ""
		if kind == "codex" {
			override = phEnv("CODEX_HOME", "")
		}
	}
	if override != "" {
		return phPath(override)
	}
	return phJoin(phHome(), "."+kind)
}

// boundTranscript is transcript(pid, kind).
func (r *phReader) boundTranscript(pid int64, kind string) (string, string) {
	root := r.conversationAccountRoot(pid, kind)
	directory := "projects"
	if kind == "codex" {
		directory = "sessions"
	}
	base := phJoin(root, directory)
	resolved := phResolve(base, false)
	var order []string
	candidates := map[string]string{}
	add := func(path, sid string) {
		if _, ok := candidates[path]; !ok {
			order = append(order, path)
		}
		candidates[path] = sid
	}
	for _, path := range r.openPaths(pid) {
		phCatch(func() {
			if !phRelativeTo(phResolve(path, false), resolved) {
				phRaise(phValueError, "not relative")
			}
			if phSuffix(path) != ".jsonl" {
				return
			}
			if sid, ok := r.metadata(path, kind).(string); ok && sid != "" {
				add(phResolve(path, false), sid)
			}
		}, phOSError, phValueError)
	}
	if kind == "claude" && len(order) == 0 {
		registry := phJoin(root, "sessions", pyStr(pid)+".json")
		phCatch(func() {
			data, info := r.privateFile(registry, 65536)
			record := phLoadsBytes(data)
			sid := phGet(record, "sessionId", phGet(record, "session_id", ""))
			text, ok := sid.(string)
			if !ok || !phConversationUUID.MatchString(text) || phMtime(info)+1 < r.epoch(pid) {
				phRaise(phUnbound, "Stale session registry.")
			}
			matches := phGlob(base, "*/"+text+".jsonl")
			if len(matches) > 3 {
				matches = matches[:3]
			}
			for _, path := range matches {
				if pyEqual(r.metadata(path, kind), text) {
					add(phResolve(path, false), text)
				}
			}
		}, phOSError, phValueError, phUnbound)
	}
	if len(order) != 1 {
		phRaise(phUnbound, "No unique transcript is bound to the running process. No directory fallback was used.")
	}
	return order[0], candidates[order[0]]
}

// phRelativeTo is PurePath.relative_to succeeding.
func phRelativeTo(path, base string) bool {
	path, base = phPath(path), phPath(base)
	if path == base {
		return true
	}
	if base == "/" {
		return strings.HasPrefix(path, "/")
	}
	return strings.HasPrefix(path, base+"/")
}

// authenticatedBinding is authenticated_binding(binary, pane, pid, kind):
// nil when no binding is readable; a mismatched producer raises Unbound.
func (r *phReader) authenticatedBinding(binary, pane string, pid int64, kind string) *pyObject {
	if binary == "" {
		return nil
	}
	var result *pyObject
	phCatch(func() {
		value := phLoads(r.run([]string{binary, "agent-binding", pane}, 5))
		producer := phGet(value, "producer", newPyObject())
		if !pyEqual(phGet(value, "version", nil), int64(1)) || !pyEqual(phGet(producer, "pane_id", nil), pane) ||
			!pyEqual(phGet(producer, "process_id", nil), pid) || !pyEqual(phGet(producer, "provider", nil), kind) {
			phRaise(phUnbound, "Authenticated producer does not match this conversation.")
		}
		start := phGet(producer, "process_start", nil)
		if !phIsInt(start) || pyLessEq(phIndex(producer, "process_start"), int64(0)) ||
			!pyFullMatch(phConversationID, phGet(value, "session_id", "")) {
			phRaise(phUnbound, "Invalid authenticated session binding.")
		}
		object := value.(*pyObject)
		object.Delete("observed_at")
		result = object
	}, phOSError, phValueError, phTimeout)
	return result
}

// phStockProxyIdentity is stock_proxy_identity(verified); "" stands for None.
func phStockProxyIdentity(verified any) string {
	if !pyTruthy(verified) || !pyEqual(phGet(verified, "source", nil), "stock_app_server_proxy") {
		return ""
	}
	proof := phGet(verified, "stock_proxy", newPyObject())
	endpoint := phGet(verified, "native_endpoint", newPyObject())
	// Evaluated in Python's `or` order: a later field is never read once an
	// earlier one has failed.
	invalid := func() bool {
		if !phIsDict(proof) || !phIsDict(endpoint) {
			return true
		}
		for _, key := range []string{"proxy_pid", "proxy_start", "control_device", "control_inode", "connection", "selection"} {
			value := phGet(proof, key, nil)
			if !phStrictInt(value) || pyLessEq(value, int64(0)) {
				return true
			}
		}
		if control, ok := phGet(proof, "control_socket", nil).(string); !ok || !strings.HasPrefix(control, "/") {
			return true
		}
		if socket, ok := phGet(endpoint, "socket", nil).(string); !ok || !strings.HasPrefix(socket, "/") {
			return true
		}
		if !phIsInt(phGet(endpoint, "daemon_pid", nil)) || pyLessEq(phGet(endpoint, "daemon_pid", nil), int64(1)) ||
			!phIsInt(phGet(endpoint, "daemon_start", nil)) || pyLessEq(phGet(endpoint, "daemon_start", nil), int64(0)) {
			return true
		}
		return !pyFullMatch(phRevision64, phGet(verified, "revision", ""))
	}
	if invalid() {
		phRaise(phUnbound, "The stock App Server proxy has no live identity proof.")
	}
	return "stock-proxy:" + phGet(verified, "revision", "").(string)
}

var phRevision64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// nativeProcessStart is native_process_start(binary, pane, pid, kind).
func (r *phReader) nativeProcessStart(binary, pane string, pid int64, kind string) any {
	if binary == "" || kind != "codex" {
		return nil
	}
	var start any
	phCatch(func() {
		value := phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), kind}, 5))
		candidate := phGet(value, "process_start", nil)
		if phStrictInt(candidate) && pyLess(int64(0), candidate) {
			start = candidate
		}
	}, phOSError, phValueError, phTimeout)
	return start
}

var (
	phCodexStates = map[string]string{"task_started": "active", "turn_started": "active", "user_message": "active",
		"task_complete": "quiet", "turn_complete": "quiet", "turn_aborted": "stop_observed"}
	phStrptimeFraction = regexp.MustCompile(`^(?i)(\d\d\d\d)-(1[0-2]|0[1-9]|[1-9])-(3[01]|[12]\d|0[1-9]|[1-9]| [1-9])` +
		`T(2[0-3]|[0-1]\d|\d):([0-5]\d|\d):(6[0-1]|[0-5]\d|\d)\.([0-9]{1,6})Z`)
	phStrptimeSeconds = regexp.MustCompile(`^(?i)(\d\d\d\d)-(1[0-2]|0[1-9]|[1-9])-(3[01]|[12]\d|0[1-9]|[1-9]| [1-9])` +
		`T(2[0-3]|[0-1]\d|\d):([0-5]\d|\d):(6[0-1]|[0-5]\d|\d)Z`)
)

// phCodexLifecycle is codex_lifecycle(row): [state, timestamp] or nil.
func phCodexLifecycle(row any) *pyList {
	if !pyEqual(phGet(row, "type", nil), "event_msg") {
		return nil
	}
	payload := phGet(row, "payload", nil)
	if !phIsDict(payload) {
		return nil
	}
	event := phGet(payload, "type", nil)
	phHashKey(event)
	name, _ := event.(string)
	state, known := phCodexStates[name]
	timestamp, ok := phGet(row, "timestamp", nil).(string)
	if !known || !ok {
		return nil
	}
	observed, valid := phParseTimestamp(timestamp)
	if !valid || observed > phTime()+60 {
		return nil
	}
	return pyListOf(state, timestamp)
}

// phParseTimestamp is datetime.strptime with "%Y-%m-%dT%H:%M:%S.%fZ", then
// "%Y-%m-%dT%H:%M:%SZ", as a UTC timestamp.
func phParseTimestamp(text string) (float64, bool) {
	match := phStrptimeFraction.FindStringSubmatch(text)
	if match == nil || len(match[0]) != len(text) {
		match = phStrptimeSeconds.FindStringSubmatch(text)
		if match == nil || len(match[0]) != len(text) {
			return 0, false
		}
		match = append(match, "")
	}
	number := func(i int) int { value, _ := strconv.Atoi(strings.TrimSpace(match[i])); return value }
	year, month, day := number(1), number(2), number(3)
	hour, minute, second := number(4), number(5), number(6)
	micro := 0
	if match[7] != "" {
		micro, _ = strconv.Atoi(match[7] + strings.Repeat("0", 6-len(match[7])))
	}
	if year < 1 || second > 59 {
		return 0, false
	}
	observed := time.Date(year, time.Month(month), day, hour, minute, second, micro*1000, time.UTC)
	if observed.Day() != day {
		return 0, false
	}
	return float64(observed.Unix()*1000000+int64(micro)) / 1e6, true
}

// processOpenPaths is open_paths(pid).
func (r *phReader) processOpenPaths(pid int64) []string {
	if r.isLinux {
		names, err := phListDir("/proc/" + pyStr(pid) + "/fd")
		if err != nil {
			phRaiseOS(err)
		}
		if len(names) > 8192 {
			names = names[:8192]
		}
		var result []string
		for _, name := range names {
			if target, err := os.Readlink("/proc/" + pyStr(pid) + "/fd/" + name); err == nil {
				result = append(result, phPath(target))
			}
		}
		return result
	}
	data := r.run([]string{"/usr/sbin/lsof", "-a", "-p", pyStr(pid), "-u", pyStr(int64(r.uid)), "-Fn"}, 4)
	var result []string
	for _, line := range phSplitLines(data) {
		if strings.HasPrefix(line, "n/") {
			result = append(result, phPath(line[1:]))
		}
	}
	return result
}
