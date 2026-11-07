package daemon

// Native maintenance inspection, account previews, worker and context reads.
// It never sends input or starts an agent. Kernel identity and foreground
// ownership fence every inspection; transcript identity never comes from UI
// text. Former interpreter sources remain in the external evidence archive.

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var (
	phSafeID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	// The exact launcher RelaydManagement.installScript emits.
	phRelayArchLauncherSHA256 = "ff7b3472261ea782268f227f8b0ed9677a567a296b444db7b8e947e77f7bee0f"
	phNativeMagic             = []string{"\x7fELF", "\xcf\xfa\xed\xfe", "\xfe\xed\xfa\xcf",
		"\xca\xfe\xba\xbe", "\xbe\xba\xfe\xca", "\xca\xfe\xba\xbf", "\xbf\xba\xfe\xca"}
	phAgentVersion = map[string]*regexp.Regexp{
		"claude": regexp.MustCompile(`^([0-9]+)\.([0-9]+)\.([0-9]+) \(Claude Code\)$`),
		"codex":  regexp.MustCompile(`^codex-cli ([0-9]+)\.([0-9]+)\.([0-9]+)(?:-[A-Za-z0-9.]+)?$`)}
	phStandaloneCodexReleaseName = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,4}$`)
	phReleaseName                = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)(?:-[A-Za-z0-9_.-]+)?$`)
	phNFSName                    = regexp.MustCompile(`^\.nfs[0-9a-fA-F]+$`)
	phCodexConfigValue           = regexp.MustCompile(`^(?:model_reasoning_effort|personality|model_provider)=[A-Za-z0-9_."-]{1,128}$`)
	phCodexModel                 = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)
	phAssignment                 = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	phMCPInterpreters            = regexp.MustCompile(`^(?:python(?:[0-9.]*)?|node|bash|sh|dash|zsh|perl|ruby|uv|uvx|deno|bun)\n?$`)
	phTaskNotification           = regexp.MustCompile(`(?s)<task-notification>(.*?)</task-notification>`)
	phBackgroundShells           = []string{"bash", "zsh", "sh", "dash", "fish", "nu", "pwsh"}
	phBackgroundAgents           = []string{"claude", "claude.exe", "node", "codex", "codex.exe"}
	phMCPNever                   = []string{"claude", "claude.exe", "codex", "codex.exe"}
	phCodexWorkEvents            = []string{"exec_command_begin", "exec_command_output_delta", "exec_command_end", "exec_approval_request",
		"apply_patch_approval_request", "patch_apply_begin", "patch_apply_end",
		"mcp_tool_call_begin", "mcp_tool_call_end", "web_search_begin", "web_search_end",
		"view_image_tool_call", "request_user_input", "elicitation_request",
		"item_started", "item_completed", "agent_message", "agent_message_delta",
		"agent_reasoning", "agent_reasoning_delta", "background_event"}
)

const (
	phMaxTail                = 4 << 20
	phCodexQuietSeconds      = 5
	phMCPConfigLimit         = 4 << 20
	phSubagentLimit          = 4096
	phSubagentMainLimit      = 512 << 20
	phHarnessSessionLimit    = 4096
	phWorkerImageLimit       = 32 << 20
	phProbeUnavailableReason = "Native identity could not be verified on this host."
)

func phContains(options []string, value string) bool {
	for _, option := range options {
		if option == value {
			return true
		}
	}
	return false
}

// privateJSON is private_json(reader, path).
func (r *phReader) privateJSON(path string) any {
	data, _ := r.privateFile(path, 65536)
	return phLoadsBytes(data)
}

// kernelStart is kernel_start(reader, pid).
func (r *phReader) kernelStart(pid any) int64 {
	if r.isLinux {
		parts := strings.SplitN(r.identity(pid), ":", 2)
		if len(parts) != 2 {
			phRaise(phIndexError, "list index out of range")
		}
		return phIntText(parts[1])
	}
	return phKernelStartNative(r, pid)
}

// recoveryOwner is recovery_owner(reader, pane, pid, provider, process_start, session).
func (r *phReader) recoveryOwner(pane string, pid int64, provider string, processStart any, session string) *pyObject {
	paths := phWorkerManifests(pane)
	if len(paths) != 1 {
		phRaise(phValueError, "Multiple workers claim this pane.")
	}
	record := r.privateJSON(paths[0])
	worker, shell := phGet(record, "worker_pid", nil), phGet(record, "shell_pid", nil)
	if !pyEqual(phGet(record, "session_id", nil), pane) || !pyEqual(phGet(record, "state", nil), "running") ||
		!pyEqual(r.kernelStart(worker), phGet(record, "worker_start_time", nil)) ||
		!pyEqual(r.kernelStart(pid), processStart) {
		phRaise(phValueError, "The recovery process incarnation changed.")
	}
	processes := r.inventory()
	if !phContainsValue(r.ancestorsOf(shell, processes), worker) || !phContainsValue(r.ancestorsOf(pid, processes), shell) {
		phRaise(phValueError, "The recovery process left its pane.")
	}
	boot, ok := phGet(record, "node_boot_id", nil).(string)
	if !ok || boot == "" {
		phRaise(phValueError, "The worker boot identity is unavailable.")
	}
	proof := pyObj("version", int64(1), "pane_id", pane, "node_boot_id", boot, "worker_pid", worker,
		"worker_start", phIndex(record, "worker_start_time"), "shell_pid", shell,
		"shell_start", r.kernelStart(shell), "provider", provider,
		"process_id", pid, "process_start", processStart, "session_id", session)
	digest := sha256.Sum256(pyEncode(proof, pyEncodeOptions{sortKeys: true, ensureASCII: true, itemSep: ", ", keySep: ": "}))
	proof.Set("transcript_identity", "input:"+hex.EncodeToString(digest[:])[:48])
	proof.Set("input_only", true)
	return proof
}

func phWorkerStateDirectory() string {
	return phEnv("XDG_STATE_HOME", phJoin(phHome(), ".local/state"))
}

// proxySession is proxy_session(reader, pane, pid, process_start): recovery
// metadata from a kernel-authenticated live frontend, never a binding.
func (r *phReader) proxySession(pane string, pid int64, processStart any) string {
	path := phJoin(phWorkerStateDirectory(), "relay/workers/codex-proxies", pane, "descriptor.json")
	descriptor := r.privateJSON(path)
	if !pyEqual(phGet(descriptor, "version", nil), int64(1)) || !pyEqual(phGet(descriptor, "pane", nil), pane) {
		phRaise(phValueError, "The native proxy descriptor changed.")
	}
	if !pyEqual(r.kernelStart(phGet(descriptor, "proxy_pid", nil)), phGet(descriptor, "proxy_start", nil)) {
		phRaise(phValueError, "The native proxy process changed.")
	}
	controlSocket, ok := phIndex(descriptor, "control_socket").(string)
	if !ok {
		phRaise(phTypeError, "expected str")
	}
	address := phPath(controlSocket)
	before := phMustStat(address, false)
	beforeDev, beforeIno := phStatDevIno(before)
	if before.Mode()&os.ModeSocket == 0 || phStatUID(before) != r.uid || before.Mode().Perm()&0o077 != 0 ||
		!pyEqual(beforeDev, phGet(descriptor, "control_device", nil)) || !pyEqual(beforeIno, phGet(descriptor, "control_inode", nil)) {
		phRaise(phValueError, "The native proxy socket changed.")
	}
	raw := phProxyState(r.ctx, address, phIndex(descriptor, "proxy_pid"), r.uid)
	if len(raw) > 16384 {
		phRaise(phValueError, "The proxy state exceeds its limit.")
	}
	value := phLoadsBytes(raw)
	after := phMustStat(address, false)
	afterDev, afterIno := phStatDevIno(after)
	if beforeDev != afterDev || beforeIno != afterIno || !pyEqual(r.privateJSON(path), descriptor) ||
		!pyTruthy(phGet(value, "active", nil)) || !pyEqual(phGet(value, "frontend_pid", nil), pid) ||
		!pyEqual(phGet(value, "frontend_start", nil), processStart) {
		phRaise(phValueError, "The live proxy frontend changed.")
	}
	session, ok := phGet(value, "last_frontend_thread", "").(string)
	if !ok || !phSafeID.MatchString(session) {
		phRaise(phValueError, "No exact frontend session is available for recovery.")
	}
	return session
}

// phProxyState asks the kernel-verified proxy for its state. Connecting is
// bounded by three seconds as Python's settimeout(3) is, but the exchange has
// one three-second deadline for the operation rather than one per fragment,
// and cancelling ctx closes the connection: a slow peer cannot hold the probe
// past its operation.
func phProxyState(ctx context.Context, address string, proxyPID any, uid int) []byte {
	if ctx == nil {
		ctx = context.Background()
	}
	dialer := net.Dialer{Timeout: 3 * time.Second}
	connection, err := dialer.DialContext(ctx, "unix", address)
	if err != nil {
		phRaiseOS(err)
	}
	defer connection.Close()
	stop := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stop()
	peerUID, peerPID, err := PeerCredentials(connection)
	if err != nil {
		phRaiseOS(err)
	}
	if !pyEqual(int64(peerPID), proxyPID) || peerUID != uid {
		phRaise(phValueError, "The native proxy peer changed.")
	}
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := connection.Write([]byte("{\"method\":\"state\"}\n")); err != nil {
		phRaiseOS(err)
	}
	var raw []byte
	buffer := make([]byte, 4096)
	for len(raw) <= 16384 && !bytes.Contains(raw, []byte("\n")) {
		if ctx.Err() != nil {
			phRaise(phTimeout, "Proxy state cancelled")
		}
		n, err := connection.Read(buffer)
		raw = append(raw, buffer[:n]...)
		if err == io.EOF {
			break
		}
		if err != nil {
			phRaiseOS(err)
		}
	}
	return raw
}

// exactCodexTranscript is exact_codex_transcript(reader, session, root).
func (r *phReader) exactCodexTranscript(session, root string) string {
	if root == "" {
		root = phEnv("CODEX_HOME", phJoin(phHome(), ".codex"))
	}
	base := phJoin(phPath(root), "sessions")
	var matches []string
	visited := 0
	var walk func(directory string)
	walk = func(directory string) {
		names, err := phListDir(directory)
		if err != nil {
			return
		}
		sort.Strings(names)
		var children, files []string
		for _, name := range names {
			if phIsDirQuiet(phPosixJoin(directory, name)) {
				if !strings.HasPrefix(name, ".") {
					children = append(children, name)
				}
			} else {
				files = append(files, name)
			}
		}
		visited += len(files) + len(children)
		if visited > 50000 {
			phRaise(phValueError, "The exact transcript lookup exceeded its limit.")
		}
		for _, name := range files {
			if strings.HasSuffix(name, "-"+session+".jsonl") {
				path := phJoin(directory, name)
				if pyEqual(r.metadata(path, "codex"), session) {
					matches = append(matches, path)
				}
			}
		}
		for _, name := range children {
			child := phPosixJoin(directory, name)
			if info, err := os.Lstat(child); err == nil && info.Mode()&os.ModeSymlink == 0 {
				walk(child)
			}
		}
	}
	walk(base)
	if len(matches) != 1 {
		phRaise(phValueError, "An exact saved conversation is required for restart.")
	}
	return matches[0]
}

// exactClaudeTranscript is exact_claude_transcript(reader, session, root).
func (r *phReader) exactClaudeTranscript(session, root string) string {
	if !phSafeID.MatchString(session) {
		phRaise(phValueError, "Invalid Claude session identity.")
	}
	if root == "" {
		root = phEnv("CLAUDE_CONFIG_DIR", phJoin(phHome(), ".claude"))
	}
	paths := phGlob(phJoin(phPath(root), "projects"), "*/"+session+".jsonl")
	sort.Strings(paths)
	var matches []string
	for index, path := range paths {
		if index >= 4 {
			phRaise(phValueError, "The exact Claude transcript lookup exceeded its limit.")
		}
		if pyEqual(r.metadata(path, "claude"), session) {
			matches = append(matches, path)
		}
	}
	if len(matches) != 1 {
		phRaise(phValueError, "An exact saved Claude conversation is required for restart.")
	}
	return matches[0]
}

// phCodexInFlight is codex_in_flight(row): turn work or a work result.
func phCodexInFlight(row any) bool {
	payload := phGet(row, "payload", nil)
	if !phIsDict(payload) {
		return false
	}
	if pyEqual(phGet(row, "type", nil), "response_item") {
		return true
	}
	if !pyEqual(phGet(row, "type", nil), "event_msg") {
		return false
	}
	event := phGet(payload, "type", nil)
	phHashKey(event)
	name, ok := event.(string)
	return ok && phContains(phCodexWorkEvents, name)
}

// tailEvidence is tail_evidence(reader, path, provider).
func (r *phReader) tailEvidence(path, provider string) (string, any, string) {
	file := phOpenNoFollow(path)
	before, err := file.Stat()
	if err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if phStatUID(before) != r.uid || before.Mode().Perm()&0o022 != 0 || !before.Mode().IsRegular() {
		file.Close()
		phRaise(phValueError, "The transcript is not owner controlled.")
	}
	offset := before.Size() - phMaxTail
	if offset < 0 {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	stream := bufio.NewReaderSize(file, 1<<20)
	if offset > 0 {
		if _, err := stream.ReadBytes('\n'); err != nil && err != io.EOF {
			file.Close()
			phRaiseOS(err)
		}
	}
	raw, err := io.ReadAll(io.LimitReader(stream, phMaxTail))
	if err != nil {
		file.Close()
		phRaiseOS(err)
	}
	after, err := file.Stat()
	file.Close()
	if err != nil {
		phRaiseOS(err)
	}
	beforeDev, beforeIno := phStatDevIno(before)
	afterDev, afterIno := phStatDevIno(after)
	if beforeDev != afterDev || beforeIno != afterIno || before.Size() != after.Size() || phMtimeNs(before) != phMtimeNs(after) {
		phRaise(phValueError, "The conversation is still changing.")
	}
	lifecycle := "unknown"
	var context any
	for _, line := range phSplitLinesBytes(raw) {
		var row any
		if phCatch(func() { row = phLoadsBytes(line) }, phValueError) != nil {
			continue
		}
		if pyTruthy(phGet(row, "isSidechain", nil)) || pyTruthy(phGet(row, "isCompactSummary", nil)) ||
			pyTruthy(phGet(row, "isVisibleInTranscriptOnly", nil)) {
			continue
		}
		kind := phGet(row, "type", nil)
		switch {
		case provider == "codex":
			if observed := r.codexLifecycle(row); observed != nil {
				lifecycle = observed.items[0].(string)
			} else if phCodexInFlight(row) {
				// Work or a result after the completion invalidates it until
				// a new completion.
				lifecycle = "active"
			}
			if pyEqual(kind, "turn_context") && phIsDict(phGet(row, "payload", nil)) {
				context = phIndex(row, "payload")
			}
		case pyEqual(kind, "user"):
			message := phGet(row, "message", newPyObject())
			var content any = pyListOf()
			if phIsDict(message) {
				content = phGet(message, "content", pyListOf())
			}
			// Tool results do not start a new user turn, but require its completion.
			if pyTruthy(content) {
				lifecycle = "active"
			}
		case pyEqual(kind, "assistant"):
			message := phGet(row, "message", newPyObject())
			var reason any
			if phIsDict(message) {
				reason = phGet(message, "stop_reason", nil)
			}
			if phInOptions(reason, "end_turn", "stop_sequence") {
				lifecycle = "quiet"
			} else if pyEqual(reason, "tool_use") {
				lifecycle = "active"
			}
		case pyEqual(kind, "system") && pyEqual(phGet(row, "subtype", nil), "turn_duration"):
			lifecycle = "quiet"
		}
	}
	if provider == "codex" && lifecycle == "quiet" && r.now()-phMtime(after) < phCodexQuietSeconds {
		// A completion is trusted only once the transcript has stopped growing.
		lifecycle = "settling"
	}
	revision := sha256.Sum256([]byte(fmt.Sprintf("%d:%d:%d:%d", beforeDev, beforeIno, before.Size(), phMtimeNs(before))))
	return lifecycle, context, hex.EncodeToString(revision[:])
}

// phCodexResumeCommand is codex_resume_command(arguments, session, context,
// launcher, managed_remote, remote_task): only known launch options are
// replayed, never an initial user prompt.
func phCodexResumeCommand(arguments []string, session string, context any, launcher []string, managedRemote string, isLinux, remoteTask bool) string {
	return phCodexResumeWithNamespaces(arguments, session, context, launcher, managedRemote, isLinux, remoteTask, func() string {
		data, err := os.ReadFile("/proc/sys/user/max_user_namespaces")
		if err != nil {
			return ""
		}
		return phStrip(phDecodeUTF8(data))
	})
}

// The policy evaluator receives the host namespace observation explicitly so
// discovery failures remain unknown and the same policy code can be checked.
func phCodexResumeWithNamespaces(arguments []string, session string, context any, launcher []string, managedRemote string, isLinux, remoteTask bool, namespaces func() string) string {
	if !phSafeID.MatchString(session) || !phIsDict(context) {
		phRaise(phValueError, "Saved Codex launch policy is unavailable.")
	}
	values := []string{"--profile", "-p", "--model", "-m", "--sandbox", "-s", "--ask-for-approval", "-a", "--cd", "-C"}
	flags := []string{"--search", "--no-alt-screen", "--all"}
	result := append([]string(nil), launcher...)
	for pos := 1; pos < len(arguments); {
		item := arguments[pos]
		pos++
		switch {
		case item == "resume":
			if pos < len(arguments) && phSafeID.MatchString(arguments[pos]) {
				pos++
			}
		case item == "--last" || item == "--all":
		case item == "--dangerously-bypass-approvals-and-sandbox" || item == "--full-auto":
			// Replaced below by the effective last-turn policy.
		case item == "--remote":
			if pos >= len(arguments) || managedRemote == "" || arguments[pos] != managedRemote {
				phRaise(phValueError, "A custom remote Codex endpoint needs a manual restart.")
			}
			pos++ // The managed launcher supplies a fresh native proxy.
		case phContains(values, item):
			if pos >= len(arguments) {
				phRaise(phValueError, "Incomplete Codex launch options.")
			}
			if !phContains([]string{"--model", "-m", "--sandbox", "-s", "--ask-for-approval", "-a", "--cd", "-C"}, item) {
				result = append(result, item, arguments[pos])
			}
			pos++
		case phContains(flags, item):
			result = append(result, item)
		case item == "-c" || item == "--config":
			if pos >= len(arguments) || !phCodexConfigValue.MatchString(arguments[pos]) {
				phRaise(phValueError, "This custom Codex launch needs a manual restart.")
			}
			result = append(result, item, arguments[pos])
			pos++
		default:
			phRaise(phValueError, "This custom Codex launch needs a manual restart.")
		}
	}
	approval := phGet(context, "approval_policy", nil)
	sandbox := phGet(context, "sandbox_policy", nil)
	if phIsDict(sandbox) {
		sandbox = phGet(sandbox, "type", nil)
	}
	if !phInOptions(approval, "never", "on-request", "on-failure", "untrusted") ||
		!phInOptions(sandbox, "read-only", "workspace-write", "danger-full-access") {
		phRaise(phValueError, "The effective Codex permission policy is unavailable.")
	}
	if remoteTask && isLinux && !pyEqual(sandbox, "danger-full-access") {
		if namespaces() == "0" {
			phRaise(phValueError, "The saved Codex sandbox is unavailable on this host; automatic restart is held.")
		}
	}
	// A local resume pins the effective policy. A managed remote resume
	// restores its saved backend policy; its frontend rejects overrides.
	if !remoteTask {
		result = append(result, "--ask-for-approval", approval.(string), "--sandbox", sandbox.(string))
	}
	directory, ok := phGet(context, "cwd", nil).(string)
	if !ok || !strings.HasPrefix(directory, "/") || len(directory) > 4096 {
		phRaise(phValueError, "The exact current Codex directory is unavailable.")
	}
	result = append(result, "--cd", directory)
	if policy, ok := phGet(context, "sandbox_policy", nil).(*pyObject); ok {
		allowed := []string{"type"}
		if pyEqual(sandbox, "workspace-write") {
			allowed = []string{"type", "writable_roots", "network_access", "exclude_tmpdir_env_var", "exclude_slash_tmp"}
		}
		for _, key := range policy.Keys() {
			if !phContains(allowed, key) {
				phRaise(phValueError, "This custom sandbox policy needs a manual restart.")
			}
		}
		if remoteTask && pyEqual(sandbox, "workspace-write") {
			for _, key := range policy.Keys() {
				if key != "type" {
					phRaise(phValueError, "This extended Codex sandbox policy needs a manual restart.")
				}
			}
		}
		if pyEqual(sandbox, "workspace-write") {
			roots := phGet(policy, "writable_roots", pyListOf())
			list, ok := roots.(*pyList)
			if !ok || len(list.items) > 16 {
				phRaise(phValueError, "This custom writable-root policy needs a manual restart.")
			}
			for _, root := range list.items {
				path, ok := root.(string)
				if !ok || !strings.HasPrefix(path, "/") {
					phRaise(phValueError, "This custom writable-root policy needs a manual restart.")
				}
				if !remoteTask {
					result = append(result, "--add-dir", path)
				}
			}
			for _, key := range []string{"network_access", "exclude_tmpdir_env_var", "exclude_slash_tmp"} {
				if value, exists := policy.Lookup(key); exists {
					flag, ok := value.(bool)
					if !ok {
						phRaise(phValueError, "Invalid sandbox option.")
					}
					if !remoteTask {
						result = append(result, "-c", "sandbox_workspace_write."+key+"="+strconv.FormatBool(flag))
					}
				}
			}
		}
	}
	if model, ok := phGet(context, "model", nil).(string); ok && phCodexModel.MatchString(model) {
		result = append(result, "--model", model)
	}
	effort := phGet(context, "effort", nil)
	if !pyTruthy(effort) {
		effort = phGet(context, "reasoning_effort", nil)
	}
	if phInOptions(effort, "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra") {
		result = append(result, "-c", `model_reasoning_effort="`+effort.(string)+`"`)
	}
	result = append(result, "resume", session)
	for _, item := range result {
		if phHasControl(item) {
			phRaise(phValueError, "Invalid launch argument.")
		}
	}
	command := phQuoteCommand(result)
	if len(command) > 8192 {
		phRaise(phValueError, "The launch command exceeds its limit.")
	}
	return command
}

func phQuoteCommand(words []string) string {
	quoted := make([]string, len(words))
	for i, word := range words {
		quoted[i] = phShlexQuote(word)
	}
	return strings.Join(quoted, " ")
}

// nativeClaudeExecutable is native_claude_executable(reader, pid, use_installed).
func (r *phReader) nativeClaudeExecutable(pid int64, useInstalled bool) string {
	var candidate string
	switch {
	case useInstalled:
		candidate = phJoin(phHome(), ".local/bin/claude")
	case r.isLinux:
		target, err := r.readlink("/proc/" + pyStr(pid) + "/exe")
		if err != nil {
			phRaiseOS(err)
		}
		candidate = phPath(target)
	default:
		images := r.run([]string{"/usr/sbin/lsof", "-a", "-p", pyStr(pid), "-d", "txt", "-F", "n"}, 3)
		var paths []string
		for _, line := range phSplitLines(images) {
			if strings.HasPrefix(line, "n/") {
				paths = append(paths, line[1:])
			}
		}
		if len(paths) == 0 {
			phRaise(phValueError, "The current native Claude image is unavailable.")
		}
		candidate = phPath(paths[0])
	}
	candidate = phResolve(candidate, true)
	info := phMustStat(candidate, true)
	if !info.Mode().IsRegular() || phStatUID(info) != r.uid || info.Mode().Perm()&0o022 != 0 || info.Mode().Perm()&0o111 == 0 {
		phRaise(phValueError, "The native Claude image is not owner controlled.")
	}
	if !phContains(phNativeMagic, phReadPrefix(candidate, 4)) {
		phRaise(phValueError, "The Claude launcher is not a verified native executable.")
	}
	return candidate
}

// phReadPrefix is open(path, "rb").read(n).
func phReadPrefix(path string, n int64) string {
	file := phOpenRead(path)
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, n))
	if err != nil {
		phRaiseOS(err)
	}
	return string(data)
}

// phClaudeResumeCommand is claude_resume_command(arguments, session, launcher, native_executable).
func phClaudeResumeCommand(arguments []string, session string, launcher []string, nativeExecutable string) string {
	return phClaudeResumeCommandWithPrompt(arguments, session, launcher, nativeExecutable, nil)
}

func phClaudeResumeCommandWithPrompt(arguments []string, session string, launcher []string, nativeExecutable string, incorporated *phClaudeInitialPromptProof) string {
	if !phSafeID.MatchString(session) {
		phRaise(phValueError, "The exact Claude session is unavailable.")
	}
	values := []string{"--model", "--effort", "--permission-mode", "--settings", "--setting-sources",
		"--agent", "--agents", "--system-prompt", "--system-prompt-file",
		"--append-system-prompt", "--append-system-prompt-file", "--fallback-model",
		"--teammate-mode", "--autocompact", "--add-dir", "--mcp-config", "--plugin-dir",
		"--tools", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
		"--betas"}
	flags := []string{"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
		"--strict-mcp-config", "--chrome", "--no-chrome", "--verbose"}
	if incorporated != nil && (incorporated.session != session || incorporated.argumentsSHA != phClaudeArgumentsSHA(arguments)) {
		phRaise(phValueError, "The incorporated Claude prompt proof changed.")
	}
	result := append([]string(nil), launcher...)
	positional := false
	for pos := 1; pos < len(arguments); {
		item := arguments[pos]
		pos++
		key, inline, equal := strings.Cut(item, "=")
		if (key == "--continue" || key == "-c" || key == "--fork-session") && !equal {
			continue
		}
		if key == "--resume" || key == "-r" || key == "--session-id" {
			if equal {
				if !phSafeID.MatchString(inline) {
					phRaise(phValueError, "The prior Claude session selector is unavailable.")
				}
			} else {
				if pos >= len(arguments) || !phSafeID.MatchString(arguments[pos]) {
					phRaise(phValueError, "The prior Claude session selector is unavailable.")
				}
				pos++
			}
			continue
		}
		switch {
		case phContains(values, key):
			if equal {
				if inline == "" {
					phRaise(phValueError, "Incomplete Claude launch options.")
				}
				result = append(result, item)
			} else {
				if pos >= len(arguments) || strings.HasPrefix(arguments[pos], "--") {
					phRaise(phValueError, "Incomplete Claude launch options.")
				}
				result = append(result, item, arguments[pos])
				pos++
			}
		case phContains(flags, item):
			result = append(result, item)
		case incorporated != nil && !positional && pos == len(arguments) && item == incorporated.text && !strings.HasPrefix(item, "-"):
			// The pinned, completed conversation already contains this one
			// initial prompt. Resume the session without submitting it again.
			positional = true
		default:
			phRaise(phValueError, "This custom Claude launch needs a manual restart.")
		}
	}
	result = append(result, "--resume", session)
	for _, item := range result {
		if phHasControl(item) {
			phRaise(phValueError, "Invalid Claude launch argument.")
		}
	}
	command := phQuoteCommand(result)
	if nativeExecutable != "" {
		if !strings.HasPrefix(nativeExecutable, "/") || phHasControl(nativeExecutable) {
			phRaise(phValueError, "Invalid native Claude executable.")
		}
		command = "RELAY_CLAUDE_BIN=" + phShlexQuote(nativeExecutable) + " " + command
	}
	if len(command) > 8192 {
		phRaise(phValueError, "The Claude launch command exceeds its limit.")
	}
	return command
}

// phAccountCommand is account_command(command, provider, override): resume in
// the agent's own account through Relay's absolute launcher.
func phAccountCommand(command, provider, override string) string {
	variable := "CODEX_HOME"
	if provider == "claude" {
		variable = "CLAUDE_CONFIG_DIR"
	}
	words := phShlexSplit(command)
	for len(words) > 0 && phAssignment.MatchString(words[0]) {
		words = words[1:]
	}
	if len(words) == 0 || !strings.HasPrefix(words[0], "/") {
		phRaise(phValueError, "The agent launch command is not pinned to Relay's launcher.")
	}
	if override == "" {
		return "env -u " + variable + " " + command
	}
	if !strings.HasPrefix(override, "/") || phNormpath(override) != override {
		phRaise(phValueError, "The agent account directory is invalid.")
	}
	return variable + "=" + phShlexQuote(override) + " " + command
}

// phMaintenanceAccountRoot is account_root(provider, override): the resolved
// real account directory, "" being the provider default.
func phMaintenanceAccountRoot(provider, override string) string {
	if override == "" {
		override = phJoin(phHome(), "."+provider)
	}
	return phRealpath(override)
}

// phSameAccount is same_account(provider, first, second).
func phSameAccount(provider, first, second string) bool {
	if provider == "claude" && (first != "") != (second != "") {
		return false
	}
	return phMaintenanceAccountRoot(provider, first) == phMaintenanceAccountRoot(provider, second)
}

// phAccountLabelDir is account_label_dir(override, provider).
func phAccountLabelDir(override, provider string) string {
	if override != "" && provider != "" && phSameAccount(provider, override, "") {
		return ""
	}
	home := phExpanduser("~")
	if override != "" && strings.HasPrefix(home, "/") && strings.HasPrefix(override, strings.TrimRight(home, "/")+"/") {
		return "~/" + override[len(strings.TrimRight(home, "/"))+1:]
	}
	return override
}

// phVersion is a release version tuple.
type phVersion []*big.Int

func phCompareVersions(a, b phVersion) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if c := a[i].Cmp(b[i]); c != 0 {
			return c
		}
	}
	return len(a) - len(b)
}

func (v phVersion) String() string {
	parts := make([]string, len(v))
	for i, part := range v {
		parts[i] = part.String()
	}
	return strings.Join(parts, ".")
}

func phVersionOf(groups []string) phVersion {
	result := make(phVersion, len(groups))
	for i, group := range groups {
		result[i], _ = new(big.Int).SetString(group, 10)
	}
	return result
}

// phPathVersion is path_version(value, provider): a release directory owned
// by the provider, never an unrelated runtime such as Node's.
func phPathVersion(value, provider string) phVersion {
	if _, version := phStandaloneCodexRelease(value, provider); version != nil {
		return version
	}
	for _, part := range append([]string{phPath(value)}, phParents(value)...) {
		match := phReleaseName.FindStringSubmatch(phName(part))
		if match != nil && phContains([]string{provider, "versions"}, phName(phParent(part))) {
			return phVersionOf(match[1:4])
		}
	}
	return nil
}

// installedUpdate is installed_update(reader, pid, provider): native
// executable identities, never a release network request.
func (r *phReader) installedUpdate(pid int64, provider string) bool {
	launcher := phJoin(phHome(), ".local/bin", provider)
	if !phExists(launcher) {
		located := phWhich(provider)
		if located == "" {
			return false
		}
		launcher = phPath(located)
	}
	running := "/proc/" + pyStr(pid) + "/exe"
	var path, images string
	if r.isLinux {
		target, err := r.readlink(running)
		if err != nil {
			phRaiseOS(err)
		}
		path = target
		if strings.HasSuffix(path, " (deleted)") {
			return true
		}
	} else {
		images = r.run([]string{"/usr/sbin/lsof", "-a", "-p", pyStr(pid), "-d", "txt", "-F", "ni"}, 4)
		var paths []string
		for _, line := range phSplitLines(images) {
			if strings.HasPrefix(line, "n/") {
				paths = append(paths, line[1:])
			}
		}
		if len(paths) == 0 {
			return false
		}
		path = paths[0]
	}
	previous := phPath(path)
	current := phResolve(launcher, false)
	oldVersion, newVersion := phPathVersion(previous, provider), phPathVersion(current, provider)
	if oldVersion != nil && newVersion != nil {
		return phCompareVersions(newVersion, oldVersion) > 0
	}
	if provider == "claude" && r.isLinux && newVersion != nil && phNFSName.MatchString(phName(previous)) {
		// NFS retains the old running image under a hidden name when Claude
		// atomically installs a release. Query only the verified native
		// images in Claude's store.
		result := false
		phCatch(func() {
			versions := phResolve(phJoin(phHome(), ".local/share/claude/versions"), true)
			old := phPath(r.nativeClaude(pid, false))
			installed := phPath(r.nativeClaude(pid, true))
			if phParent(old) != versions || phParent(installed) != versions {
				return
			}
			identity := func() string {
				var parts []string
				for _, image := range []string{old, installed} {
					info := phMustStat(image, true)
					dev, ino := phStatDevIno(info)
					parts = append(parts, fmt.Sprintf("%d:%d:%d", dev, ino, phMtimeNs(info)))
				}
				return strings.Join(parts, ",")
			}
			identities := identity()
			var read []phVersion
			for _, image := range []string{old, installed} {
				text := phStrip(r.run([]string{image, "--version"}, 3))
				match := phAgentVersion["claude"].FindStringSubmatch(text)
				if match == nil {
					return
				}
				read = append(read, phVersionOf(match[1:4]))
			}
			if identities != identity() {
				return
			}
			result = phCompareVersions(read[1], newVersion) == 0 && phCompareVersions(read[1], read[0]) > 0
		}, phOSError, phValueError, phKeyError)
		return result
	}
	if r.isLinux && phIsFile(current) {
		// Relay's shell launcher is a script; compare the actual native target.
		native := phJoin(phHome(), ".local/share/relay/bin/native-codex/codex")
		target := current
		if provider == "codex" && phIsFile(native) {
			target = native
		}
		_, runningIno := phStatDevIno(phMustStat(running, true))
		_, targetIno := phStatDevIno(phMustStat(target, true))
		return runningIno != targetIno && phResolve(previous, false) == phResolve(target, false)
	}
	if !r.isLinux && phPlatformDarwin {
		var inode *big.Int
		for _, line := range phSplitLines(images) {
			if strings.HasPrefix(line, "i") && phIsDigits(line[1:]) {
				inode, _ = new(big.Int).SetString(line[1:], 10)
			} else if line == "n"+previous && inode != nil && phIsFile(previous) {
				// An atomically replaced executable retains its old text
				// inode in lsof even when the pathname now points to the new file.
				_, ino := phStatDevIno(phMustStat(previous, true))
				return new(big.Int).SetUint64(ino).Cmp(inode) != 0
			}
		}
	}
	return false
}

// phIsDigits is str.isdigit for ASCII text.
func phIsDigits(text string) bool {
	if text == "" {
		return false
	}
	for _, r := range text {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// phVerifiedNative is verified_native(path): a regular native image the user
// or root controls; scripts are never executed.
func phVerifiedNative(path string, uid int) bool {
	info := phMustStat(path, true)
	owner := phStatUID(info)
	if !info.Mode().IsRegular() || owner != uid && owner != 0 || info.Mode().Perm()&0o022 != 0 || info.Mode().Perm()&0o111 == 0 {
		return false
	}
	return phContains(phNativeMagic, phReadPrefix(path, 4))
}

// imageVersion is image_version(reader, path, provider).
func (r *phReader) imageVersion(path, provider string) phVersion {
	var result phVersion
	phCatchAll(func() {
		if !phVerifiedNative(path, r.uid) {
			return
		}
		pattern, ok := phAgentVersion[provider]
		if !ok {
			phRaise(phKeyError, provider)
		}
		if match := pattern.FindStringSubmatch(phStrip(r.run([]string{path, "--version"}, 3))); match != nil {
			result = phVersionOf(match[1:4])
		}
	})
	return result
}

type phImage struct {
	path       string
	dev        int64
	ino        uint64
	executable string
}

// runningImage is running_image(reader, pid): the loaded image, its identity
// and a path that executes exactly that image, if any.
func (r *phReader) runningImage(pid int64) phImage {
	if r.isLinux {
		exe := "/proc/" + pyStr(pid) + "/exe"
		path, err := os.Readlink(exe)
		if err != nil {
			phRaiseOS(err)
		}
		dev, ino := phStatDevIno(phMustStat(exe, true))
		// Linux keeps a replaced or deleted image executable through /proc.
		return phImage{path: strings.TrimSuffix(path, " (deleted)"), dev: dev, ino: ino, executable: exe}
	}
	images := r.run([]string{"/usr/sbin/lsof", "-a", "-p", pyStr(pid), "-d", "txt", "-F", "nDi"}, 3)
	var device, inode *big.Int
	for _, line := range phSplitLines(images) {
		switch {
		case strings.HasPrefix(line, "D0x"):
			value, ok := new(big.Int).SetString(line[3:], 16)
			if !ok {
				phRaise(phValueError, "invalid literal for int() with base 16")
			}
			device = value
		case strings.HasPrefix(line, "i") && phIsDigits(line[1:]):
			inode, _ = new(big.Int).SetString(line[1:], 10)
		case strings.HasPrefix(line, "n/") && device != nil && inode != nil:
			path := line[1:]
			image := phImage{path: path, dev: device.Int64(), ino: inode.Uint64()}
			if info, err := os.Stat(path); err == nil {
				dev, ino := phStatDevIno(info)
				if big.NewInt(dev).Cmp(device) == 0 && new(big.Int).SetUint64(ino).Cmp(inode) == 0 {
					image.executable = path
				}
			}
			return image
		}
	}
	phRaise(phValueError, "The running agent image is unavailable.")
	return phImage{}
}

// phStandaloneCodexRelease recognizes the exact home-owned standalone store.
// A similar directory elsewhere is not evidence of a shared installation.
func phStandaloneCodexRelease(path, provider string) (string, phVersion) {
	if provider != "codex" || !strings.HasPrefix(path, "/") {
		return "", nil
	}
	path = phPath(path)
	releases := phJoin(phHome(), ".codex/packages/standalone/releases")
	release := phParent(phParent(path))
	if phName(path) != "codex" || phName(phParent(path)) != "bin" || phParent(release) != releases {
		return "", nil
	}
	match := phStandaloneCodexReleaseName.FindStringSubmatch(phName(release))
	if match == nil {
		return "", nil
	}
	return releases, phVersionOf(match[1:4])
}

// phInstallRoot is install_root(path, provider): the install that owns an
// image, or "" for an unrecognised layout.
func phInstallRoot(path, provider string) string {
	if root, _ := phStandaloneCodexRelease(path, provider); root != "" {
		return root
	}
	for _, part := range append([]string{phPath(path)}, phParents(path)...) {
		name, parent := phName(part), phName(phParent(part))
		switch {
		case phReleaseName.MatchString(name) && (parent == provider || parent == "versions"):
			return phParent(part)
		case name == "versions" && parent == provider:
			return part // An NFS-renamed image keeps its store directory.
		case name == "codex" && parent == "@openai":
			return part
		case name == "native-codex" || strings.HasPrefix(name, "native-codex-"):
			// Staged native-codex releases are activated through one symlink.
			return phJoin(phParent(part), "native-codex")
		}
	}
	return ""
}

// installedAgent is installed_agent(provider): the executable a restart pins
// and the native image it is proven to run.
func (r *phReader) installedAgent(provider string) (string, string) {
	launcher := phJoin(phHome(), ".local/bin", provider)
	if !phExists(launcher) {
		located := phWhich(provider)
		if located == "" {
			return "", ""
		}
		launcher = phPath(located)
	}
	if !strings.HasPrefix(launcher, "/") {
		return "", ""
	}
	target := phResolve(launcher, true)
	if phVerifiedNative(target, r.uid) {
		return target, target
	}
	if provider != "codex" {
		return "", ""
	}
	// The npm launcher is a Node script; its platform package holds the native image.
	package_ := ""
	for _, parent := range phParents(target) {
		if phName(parent) == "codex" && phName(phParent(parent)) == "@openai" {
			package_ = parent
			break
		}
	}
	if package_ != "" && target == phJoin(package_, "bin/codex.js") {
		images := map[string]bool{}
		for _, pattern := range []string{"node_modules/@openai/codex-*/vendor/*/bin/codex", "node_modules/@openai/codex-*/vendor/*/codex/codex",
			"vendor/*/bin/codex", "vendor/*/codex/codex"} {
			matches := phGlob(package_, pattern)
			sort.Strings(matches)
			if len(matches) > 8 {
				matches = matches[:8]
			}
			for _, path := range matches {
				if phVerifiedNative(path, r.uid) {
					images[phResolve(path, false)] = true
				}
			}
		}
		if len(images) == 1 {
			for image := range images {
				return target, image
			}
		}
	}
	// Archived Relay native bundles are never selected by relayd's launcher.
	return "", ""
}

// phAgentVersions is agent_versions' result; nil fields are None.
type phAgentVersions struct {
	running, installed, launcher any
	imageCurrent, sameInstall    any
}

// agentVersions is agent_versions(reader, pid, provider). Unknown values are
// None; this evidence never blocks binding repair.
func (r *phReader) agentVersions(pid int64, provider string) phAgentVersions {
	var result phAgentVersions
	var image phImage
	var launcher, installed string
	if phCatchAll(func() {
		image = r.runningImage(pid)
		launcher, installed = r.installedAgent(provider)
	}) {
		return result
	}
	return r.agentVersionsFromImage(provider, image, launcher, installed)
}

// Evaluate the discovered image identities without repeating discovery. The
// snapshots are observations, not update or restart authorization.
func (r *phReader) agentVersionsFromImage(provider string, image phImage, launcher, installed string) phAgentVersions {
	var result phAgentVersions
	if launcher != "" {
		result.launcher = launcher
	}
	running := phPathVersion(image.path, provider)
	var target phVersion
	if installed != "" {
		target = phPathVersion(installed, provider)
		if info, err := os.Stat(installed); err == nil {
			dev, ino := phStatDevIno(info)
			result.imageCurrent = dev == image.dev && ino == image.ino
		}
		roots := []string{phInstallRoot(image.path, provider), phInstallRoot(installed, provider)}
		if roots[0] != "" && roots[1] != "" {
			result.sameInstall = roots[0] == roots[1]
		}
		if target == nil {
			target = r.imageVersion(installed, provider)
		}
	}
	if running == nil {
		if result.imageCurrent == true {
			running = target
		} else if image.executable != "" {
			running = r.imageVersion(image.executable, provider)
		}
	}
	if running != nil {
		result.running = running.String()
	}
	if target != nil {
		result.installed = target.String()
	}
	return result
}

// phNewerInstalled is newer_installed(versions).
func phNewerInstalled(versions phAgentVersions) bool {
	running, _ := versions.running.(string)
	installed, _ := versions.installed.(string)
	if running == "" || installed == "" {
		return false
	}
	return phCompareVersions(phVersionOf(strings.Split(installed, ".")), phVersionOf(strings.Split(running, "."))) > 0
}

// phPinnedCodexCommand is pinned_codex_command(command, launcher).
func phPinnedCodexCommand(command string, launcher any) string {
	text, ok := launcher.(string)
	if !ok || !strings.HasPrefix(text, "/") || phHasControl(text) {
		phRaise(phValueError, "The installed Codex launcher is unavailable.")
	}
	command = "RELAY_CODEX_BIN=" + phShlexQuote(text) + " " + command
	if len(command) > 8192 {
		phRaise(phValueError, "The launch command exceeds its limit.")
	}
	return command
}

// phMCPEntry is one stdio server: (command, args).
type phMCPEntry struct {
	command string
	args    []string
}

// phMCPEntries is mcp_entries(value, plugin_root): only command and args are
// read; env, headers and URLs are never touched.
func phMCPEntries(value any, pluginRoot *string) []phMCPEntry {
	var servers any
	if phIsDict(value) {
		servers = phGet(value, "mcpServers", nil)
	}
	if servers == nil {
		return nil
	}
	object, ok := servers.(*pyObject)
	if !ok {
		phRaise(phValueError, "mcpServers is not an object.")
	}
	var entries []phMCPEntry
	for _, key := range object.Keys() {
		server := object.Get(key)
		command, ok := phGetIfDict(server, "command").(string)
		if !phIsDict(server) || !ok {
			continue // http, sse and malformed servers start no child process
		}
		args, ok := phGet(server, "args", pyListOf()).(*pyList)
		if !ok {
			phRaise(phValueError, "MCP server arguments are not strings.")
		}
		words := []string{command}
		for _, arg := range args.items {
			text, ok := arg.(string)
			if !ok {
				phRaise(phValueError, "MCP server arguments are not strings.")
			}
			words = append(words, text)
		}
		if pluginRoot != nil {
			for i, word := range words {
				words[i] = strings.ReplaceAll(word, "${CLAUDE_PLUGIN_ROOT}", *pluginRoot)
			}
		}
		entries = append(entries, phMCPEntry{command: phExpanduser(words[0]), args: words[1:]})
	}
	return entries
}

func phGetIfDict(value any, key string) any {
	if object, ok := value.(*pyObject); ok {
		return object.Get(key)
	}
	return nil
}

// phMCPJSON is mcp_json(path).
func phMCPJSON(path string) any {
	file := phOpenRead(path)
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, phMCPConfigLimit+1))
	if err != nil {
		phRaiseOS(err)
	}
	if len(data) > phMCPConfigLimit {
		phRaise(phValueError, "The MCP configuration exceeds its limit.")
	}
	return phLoadsBytes(data)
}

// configuredMCPCommands is configured_mcp_commands(pid, account, arguments):
// every stdio MCP server command the Claude session may have started, or nil
// when any existing source cannot be read or parsed.
func (r *phReader) configuredMCPCommands(pid int64, account string, arguments []string) []phMCPEntry {
	var entries []phMCPEntry
	if phCatch(func() {
		root := phHome()
		if account != "" {
			root = phPath(account)
		}
		configPath := phJoin(root, ".claude.json")
		cwd := r.cwd(pid)
		entries = []phMCPEntry{}
		if phExists(configPath) {
			config := phMCPJSON(configPath)
			entries = append(entries, phMCPEntries(config, nil)...)
			var projects any
			if phIsDict(config) {
				projects = phGet(config, "projects", nil)
			}
			if phIsDict(projects) && phIsDict(phGet(projects, cwd, nil)) {
				entries = append(entries, phMCPEntries(phGet(projects, cwd, nil), nil)...)
			}
		}
		directory := phPath(cwd)
		for _, folder := range append([]string{directory}, phParents(directory)...) {
			if candidate := phJoin(folder, ".mcp.json"); phExists(candidate) {
				entries = append(entries, phMCPEntries(phMCPJSON(candidate), nil)...)
			}
		}
		for index, word := range arguments {
			if word != "--mcp-config" {
				continue
			}
			for _, value := range arguments[index+1:] {
				if strings.HasPrefix(value, "-") {
					break
				}
				if strings.HasPrefix(strings.TrimLeftFunc(value, phIsSpace), "{") {
					entries = append(entries, phMCPEntries(phLoads(value), nil)...)
				} else {
					entries = append(entries, phMCPEntries(phMCPJSON(value), nil)...)
				}
			}
		}
		pluginsRoot := phJoin(phHome(), ".claude")
		if account != "" {
			pluginsRoot = phPath(account)
		}
		plugins := phJoin(pluginsRoot, "plugins", "installed_plugins.json")
		if phExists(plugins) {
			installed, ok := phGet(phMCPJSON(plugins), "plugins", newPyObject()).(*pyObject)
			if !ok {
				phRaise(phValueError, "installed_plugins.json is not recognised.")
			}
			for _, key := range installed.Keys() {
				spec := installed.Get(key)
				items := []any{spec}
				if list, ok := spec.(*pyList); ok {
					items = list.items
				}
				for _, item := range items {
					location, ok := phGetIfDict(item, "installPath").(string)
					if !ok {
						continue
					}
					for _, manifest := range []string{phJoin(location, ".mcp.json"), phJoin(location, ".claude-plugin", "plugin.json")} {
						if phExists(manifest) {
							entries = append(entries, phMCPEntries(phMCPJSON(manifest), &location)...)
						}
					}
				}
			}
		}
	}, phOSError, phValueError, phAttributeError) != nil {
		return nil
	}
	return entries
}

// phScriptInterpreter is script_interpreter(script): the interpreter a
// script's own shebang names, or "" without a readable shebang.
func phScriptInterpreter(script string) string {
	var line []byte
	if phCatch(func() {
		file := phOpenRead(script)
		defer file.Close()
		line = phReadLine(bufio.NewReader(file), 256)
	}, phOSError) != nil {
		return ""
	}
	if !bytes.HasPrefix(line, []byte("#!")) {
		return ""
	}
	words := phSplit(phDecodeReplace(line[2:]), -1)
	if len(words) == 0 {
		return ""
	}
	if phName(words[0]) == "env" {
		var rest []string
		for _, word := range words[1:] {
			if !strings.HasPrefix(word, "-") {
				rest = append(rest, word)
			}
		}
		if len(rest) == 0 {
			return ""
		}
		return phName(rest[0])
	}
	return phName(words[0])
}

func phEqualWords(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// phMCPServerProcess is mcp_server_process(argv, entries).
func phMCPServerProcess(argv []string, entries []phMCPEntry) bool {
	if len(argv) == 0 || phContains(phMCPNever, strings.ToLower(phName(argv[0]))) {
		return false
	}
	runner := phName(argv[0])
	for _, entry := range entries {
		full := append([]string{entry.command}, entry.args...)
		if phEqualWords(argv, full) {
			return true
		}
		if !strings.Contains(entry.command, "/") && runner == entry.command && phEqualWords(argv[1:], entry.args) {
			return true
		}
		if strings.Contains(entry.command, "/") && len(argv) >= 2 && phEqualWords(argv[1:], full) &&
			phMCPInterpreters.MatchString(runner) && phScriptInterpreter(entry.command) == runner {
			return true
		}
	}
	return false
}

// backgroundShellWork is background_shell_work(reader, pid, servers): true
// for any shell below the agent, or an agent process outside a configured
// MCP server's subtree; nil when the evidence cannot be read.
func (r *phReader) backgroundShellWork(pid int64, servers func() ([]phMCPEntry, bool)) any {
	if r.inventory == nil {
		return nil
	}
	processes := r.inventory()
	var agents []int64
	for _, child := range processes.order {
		if child == pid {
			continue
		}
		chain, visited, current := []int64{child}, map[int64]bool{child: true}, processes.rows[child].parent
		for current != pid {
			if _, ok := processes.rows[current]; !ok || visited[current] {
				break
			}
			visited[current] = true
			chain = append(chain, current)
			current = processes.rows[current].parent
		}
		if current != pid {
			continue
		}
		name := processes.rows[child].name
		base := phName(name)
		if phContains(phBackgroundShells, base) {
			return true
		}
		if phContains(phBackgroundAgents, strings.ToLower(base)) || phContains([]string{"claude", "codex"}, r.provider(name)) {
			agents = append(agents, chain[len(chain)-1])
		}
	}
	if len(agents) == 0 {
		return false
	}
	if servers == nil {
		return nil
	}
	entries, ok := servers()
	if !ok {
		return nil
	}
	// Python iterates set(agents); ascending pid order is deterministic.
	unique := map[int64]bool{}
	var tops []int64
	for _, top := range agents {
		if !unique[top] {
			unique[top] = true
			tops = append(tops, top)
		}
	}
	sort.Slice(tops, func(i, j int) bool { return tops[i] < tops[j] })
	for _, top := range tops {
		var argv []string
		if phCatch(func() { argv = r.arguments(top) }, phOSError, phValueError) != nil {
			return nil
		}
		if !phMCPServerProcess(argv, entries) {
			return true
		}
	}
	return false
}

// phNotificationTag is notification_tag(name, text); "" stands for None.
func phNotificationTag(name, text string) any {
	pattern := regexp.MustCompile("<" + regexp.QuoteMeta(name) + ">([^<]{1,128})</" + regexp.QuoteMeta(name) + ">")
	match := pattern.FindStringSubmatch(text)
	if match == nil {
		return nil
	}
	return phStrip(match[1])
}

// phNotificationTexts is notification_texts(record): a harness lifecycle
// notification's own text only.
func phNotificationTexts(record any) []string {
	origin := phGet(record, "origin", nil)
	if !pyTruthy(origin) {
		origin = newPyObject()
	}
	if !pyEqual(phGet(record, "type", nil), "user") || !pyEqual(phGet(origin, "kind", nil), "task-notification") {
		return nil
	}
	message := phGet(record, "message", nil)
	if !pyTruthy(message) {
		message = newPyObject()
	}
	switch content := phGet(message, "content", nil).(type) {
	case string:
		return []string{content}
	case *pyList:
		var texts []string
		for _, block := range content.items {
			if phIsDict(block) && pyEqual(phGet(block, "type", nil), "text") {
				if text, ok := phGet(block, "text", nil).(string); ok {
					texts = append(texts, text)
				}
			}
		}
		return texts
	}
	return nil
}

// phHashSet is a Python set of JSON scalars.
type phHashSet struct{ items []any }

func (s *phHashSet) add(v any) {
	phHashKey(v)
	if !s.has(v) {
		s.items = append(s.items, v)
	}
}

func (s *phHashSet) has(v any) bool {
	phHashKey(v)
	return phContainsValue(s.items, v)
}

// phHashDict is a Python dict with JSON scalar keys.
type phHashDict struct {
	keys, values []any
}

func (d *phHashDict) index(key any) int {
	phHashKey(key)
	for i, k := range d.keys {
		if pyEqual(k, key) {
			return i
		}
	}
	return -1
}

func (d *phHashDict) set(key, value any) {
	if i := d.index(key); i >= 0 {
		d.values[i] = value
		return
	}
	d.keys, d.values = append(d.keys, key), append(d.values, value)
}

func (d *phHashDict) pop(key any) any {
	i := d.index(key)
	value := d.values[i]
	d.keys = append(d.keys[:i:i], d.keys[i+1:]...)
	d.values = append(d.values[:i:i], d.values[i+1:]...)
	return value
}

// phSubagentLifecycle is subagent_lifecycle(path, ids): the ordered
// start/end events of each subagent id in the main transcript.
func phSubagentLifecycle(path string, ids []string) map[string][]string {
	events := map[string][]string{}
	for _, id := range ids {
		events[id] = []string{}
	}
	eventKey := func(agent any) (string, bool) {
		phHashKey(agent)
		text, ok := agent.(string)
		if !ok {
			return "", false
		}
		_, found := events[text]
		return text, found
	}
	launches := &phHashSet{}
	stops := &phHashDict{}
	if phMustStat(path, true).Size() > phSubagentMainLimit {
		phRaise(phValueError, "The session transcript exceeds the subagent check limit.")
	}
	file := phOpenRead(path)
	defer file.Close()
	stream := bufio.NewReaderSize(file, 1<<20)
	for {
		raw, err := stream.ReadBytes('\n')
		if len(raw) == 0 && err != nil {
			if err != io.EOF {
				phRaiseOS(err)
			}
			break
		}
		if !bytes.Contains(raw, []byte("agentId")) && !bytes.Contains(raw, []byte("task-notification")) &&
			!bytes.Contains(raw, []byte("TaskStop")) && !bytes.Contains(raw, []byte(`"Agent"`)) &&
			!bytes.Contains(raw, []byte(`"Task"`)) && !(len(stops.keys) > 0 && bytes.Contains(raw, []byte("tool_result"))) {
			continue
		}
		var record any
		if phCatch(func() { record = phLoadsBytes(raw) }, phValueError) != nil {
			continue
		}
		if !phIsDict(record) || !phInOptions(phGet(record, "type", nil), "user", "assistant") {
			continue
		}
		message := phGet(record, "message", nil)
		if !pyTruthy(message) {
			message = newPyObject()
		}
		content := phGet(message, "content", nil)
		blocks := []any{}
		if list, ok := content.(*pyList); ok {
			blocks = list.items
		}
		if pyEqual(phIndex(record, "type"), "assistant") {
			for _, block := range blocks {
				if !phIsDict(block) || !pyEqual(phGet(block, "type", nil), "tool_use") {
					continue
				}
				name := phGet(block, "name", nil)
				if phInOptions(name, "Agent", "Task") {
					launches.add(phGet(block, "id", nil))
				} else if pyEqual(name, "TaskStop") {
					input := phGet(block, "input", nil)
					if !pyTruthy(input) {
						input = newPyObject()
					}
					target := phGet(input, "task_id", nil)
					if _, found := eventKey(target); found {
						stops.set(phGet(block, "id", nil), target)
					}
				}
			}
			continue
		}
		var results []any
		for _, block := range blocks {
			if phIsDict(block) && pyEqual(phGet(block, "type", nil), "tool_result") {
				results = append(results, block)
			}
		}
		structured := phGet(record, "toolUseResult", nil)
		// A record's structured result belongs to its one tool result.
		if len(results) == 1 && phIsDict(structured) {
			call := phGet(results[0], "tool_use_id", nil)
			if agent, found := eventKey(phGet(structured, "agentId", nil)); found {
				status := phGet(structured, "status", nil)
				if phInOptions(status, "async_launched", "teammate_spawned") {
					events[agent] = append(events[agent], "start")
				} else if launches.has(call) {
					if pyEqual(status, "completed") {
						events[agent] = append(events[agent], "end")
					} else {
						events[agent] = append(events[agent], "unknown")
					}
				}
			}
			if i := stops.index(call); i >= 0 && phGet(results[0], "is_error", nil) != true &&
				pyEqual(phGet(structured, "task_id", nil), stops.values[i]) {
				target := stops.pop(call).(string)
				events[target] = append(events[target], "end")
			}
		}
		for _, text := range phNotificationTexts(record) {
			for _, note := range phTaskNotification.FindAllStringSubmatch(text, -1) {
				if agent, found := eventKey(phNotificationTag("task-id", note[1])); found {
					if phInOptions(phNotificationTag("status", note[1]), "completed", "failed", "stopped", "killed") {
						events[agent] = append(events[agent], "end")
					} else {
						events[agent] = append(events[agent], "unknown")
					}
				}
			}
		}
		if err != nil {
			break
		}
	}
	return events
}

// phSubagentSettle is how long a started subagent's own transcript must stay
// unchanged after an assistant end_turn before it no longer counts as working.
const phSubagentSettle = 10 * time.Minute

// phSubagentSettled reports whether a subagent whose lifecycle never recorded
// an end has evidently stopped: its transcript is a regular file, quiet for
// phSubagentSettle, and its last record is an assistant message that ended
// its turn. A team teammate is recorded as teammate_spawned and never gets a
// completion notification, so without this it would hold the pane forever.
// Any doubt (unreadable, mid tool call, unparseable tail) keeps it working.
func phSubagentSettled(path string) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || time.Since(info.ModTime()) < phSubagentSettle {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	const tail = 256 << 10
	offset := info.Size() - tail
	if offset < 0 {
		offset = 0
	}
	buffer := make([]byte, info.Size()-offset)
	if _, err := file.ReadAt(buffer, offset); err != nil && err != io.EOF {
		return false
	}
	lines := bytes.Split(bytes.TrimRight(buffer, "\n"), []byte("\n"))
	last := bytes.TrimSpace(lines[len(lines)-1])
	if len(last) == 0 || (offset > 0 && len(lines) == 1) {
		return false
	}
	var record struct {
		Type    string `json:"type"`
		Message struct {
			StopReason string `json:"stop_reason"`
		} `json:"message"`
	}
	return json.Unmarshal(last, &record) == nil && record.Type == "assistant" && record.Message.StopReason == "end_turn"
}

// phSubagentWork is subagent_work(path, session): whether any in-process
// subagent of the session may still be working; nil when unknown.
func phSubagentWork(path string, session any) any {
	var result any
	if phCatch(func() {
		text, ok := session.(string)
		if path == "" || !ok || phName(path) != text+".jsonl" {
			result = nil
			return
		}
		if !phMustStat(path, false).Mode().IsRegular() {
			result = nil
			return
		}
		directory := phJoin(phParent(path), text)
		if !phLexists(directory) {
			result = false
			return
		}
		if !phMustStat(directory, false).IsDir() {
			result = nil
			return
		}
		subagents := phJoin(directory, "subagents")
		if !phLexists(subagents) {
			result = false
			return
		}
		if !phMustStat(subagents, false).IsDir() {
			result = nil
			return
		}
		names, err := phListDir(subagents)
		if err != nil {
			phRaiseOS(err)
		}
		var ids []string
		for _, name := range names {
			if !strings.HasPrefix(name, "agent-") || !strings.HasSuffix(name, ".jsonl") {
				continue
			}
			if len(ids) >= phSubagentLimit || !phMustStat(phJoin(subagents, name), false).Mode().IsRegular() {
				result = nil
				return
			}
			ids = append(ids, strings.TrimSuffix(name[len("agent-"):], ".jsonl"))
		}
		if len(ids) == 0 {
			result = false
			return
		}
		events := phSubagentLifecycle(path, ids)
		working, unknown := false, false
		for _, agent := range ids {
			history := events[agent]
			switch {
			case len(history) == 0 || phContains(history, "unknown"):
				unknown = true
			case history[len(history)-1] == "start" && !phSubagentSettled(phJoin(subagents, "agent-"+agent+".jsonl")):
				working = true
			}
		}
		switch {
		case working:
			result = true
		case unknown:
			result = nil
		default:
			result = false
		}
	}, phOSError, phValueError) != nil {
		return nil
	}
	return result
}

// phHarnessSessionDirs is harness_session_dirs(account).
func phHarnessSessionDirs(account string) []string {
	var roots []string
	if account != "" {
		roots = append(roots, phPath(account))
	}
	roots = append(roots, phJoin(phHome(), ".claude"))
	seen := map[string]bool{}
	var result []string
	for _, root := range roots {
		directory := phJoin(root, "sessions")
		var real string
		if phCatch(func() { real = phResolve(directory, true) }, phOSError, phRuntimeError) != nil {
			continue
		}
		if !seen[real] && phIsDir(directory) {
			seen[real] = true
			result = append(result, directory)
		}
	}
	return result
}

// phHarnessRecord is harness_record(path).
func phHarnessRecord(path string) *pyObject {
	record, ok := phMCPJSON(path).(*pyObject)
	if !ok {
		phRaise(phValueError, "The Claude session record is not an object.")
	}
	return record
}

// harnessMatches is harness_matches(reader, record, pid): the record names
// this exact live process by pid and kernel start.
func (r *phReader) harnessMatches(record *pyObject, pid int64) bool {
	if !pyEqual(record.Get("pid"), pid) {
		return false
	}
	if _, isBool := record.Get("procStart").(bool); isBool {
		return false
	}
	matched := false
	phCatchAll(func() { matched = r.identity(pid) == "linux:"+pyStr(record.Get("procStart")) })
	return matched
}

// harnessStatus is harness_status(reader, pid, account): Claude's own status
// for the bound process, or nil.
func (r *phReader) harnessStatus(pid int64, account string) any {
	var result any
	phCatch(func() {
		for _, directory := range phHarnessSessionDirs(account) {
			path := phJoin(directory, pyStr(pid)+".json")
			if phExists(path) {
				record := phHarnessRecord(path)
				if status, ok := record.Get("status").(string); ok && r.harnessMatches(record, pid) {
					result = status
					return
				}
			}
		}
	}, phOSError, phValueError)
	return result
}

// backgroundAgentJobs is background_agent_jobs(reader, pid, account): live
// Claude background jobs outside the bound process, or nil when unknown.
func (r *phReader) backgroundAgentJobs(pid int64, account string) any {
	var result any
	if phCatchAll(func() {
		directories := phHarnessSessionDirs(account)
		if len(directories) == 0 {
			return
		}
		processes := r.inventory()
		count, seen := int64(0), 0
		for _, directory := range directories {
			paths := phGlob(directory, "*.json")
			sort.Strings(paths)
			for _, path := range paths {
				seen++
				if seen > phHarnessSessionLimit {
					return
				}
				record := phHarnessRecord(path)
				job := record.Get("pid")
				if !pyEqual(record.Get("kind"), "bg") || !phStrictInt(job) {
					continue
				}
				if pyEqual(job, pid) || phContainsValue(r.ancestorsOf(job, processes), pid) {
					continue
				}
				if key, found := processes.lookup(job); found && r.harnessMatches(record, key) {
					count++
				}
			}
		}
		result = count
	}) {
		return nil
	}
	return result
}

// currentClaudeImage is current_claude_image(reader, pid).
func (r *phReader) currentClaudeImage(pid int64) any {
	var result any
	phCatch(func() {
		running := phMustStat(r.nativeClaude(pid, false), true)
		installed := phMustStat(r.nativeClaude(pid, true), true)
		runningDev, runningIno := phStatDevIno(running)
		installedDev, installedIno := phStatDevIno(installed)
		result = runningDev == installedDev && runningIno == installedIno
	}, phOSError, phValueError)
	return result
}

func (r *phReader) promptOwner(binary, pane string) any {
	raw := r.run([]string{binary, "prompt-owner-binding", pane}, 5)
	if phStrip(raw) == "" {
		return nil
	}
	return phLoads(raw)
}

// inspect is inspect(reader, pane, binary) without an expected or target
// account: the probe never moves an agent between accounts.
func (r *phReader) inspect(pane, binary string) *pyObject {
	return r.inspectAccounts(pane, binary, nil, nil)
}

// inspectAccounts also serves the desktop's read-only maintenance preview.
// It only constructs commands after validating the exact shared transcript;
// constructing the preview never starts, exits or moves an agent.
func (r *phReader) inspectAccounts(pane, binary string, expect, target *string) *pyObject {
	if !phSafeID.MatchString(pane) {
		phRaise(phValueError, "Invalid pane identity.")
	}
	root := r.rootForPane(pane)
	owner := r.promptOwner(binary, pane)
	if pyTruthy(owner) && pyEqual(phGet(owner, "provider", nil), "shell") {
		start := r.identity(root)
		processStart := phGet(owner, "process_start", nil)
		if !pyEqual(phGet(owner, "pane_id", nil), pane) || !pyEqual(phGet(owner, "process_id", nil), root) ||
			!pyEqual(phGet(owner, "shell_pid", nil), root) || !phStrictInt(processStart) ||
			pyLessEq(processStart, int64(0)) || !pyEqual(phGet(owner, "shell_start", nil), processStart) {
			phRaise(phValueError, "The native shell owner is invalid.")
		}
		after := phLoads(r.run([]string{binary, "prompt-owner-binding", pane}, 5))
		if !pyEqual(after, owner) || r.rootForPane(pane) != root || r.identity(root) != start {
			phRaise(phValueError, "The native shell owner changed during inspection.")
		}
		return pyObj("version", int64(1), "pane_id", pane, "provider", "shell", "process_id", root,
			"process_start", processStart, "owner", owner, "installed_update", false)
	}
	pid, provider := r.agent(root, binary, pane)
	start := r.identity(pid)
	// The account is part of the agent's identity: transcripts are found in
	// it and a restart resumes in it. An unreadable account holds the restart.
	account := r.accountOverride(pid, provider)
	kernel := phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), provider}, 5))
	processStart := phGet(kernel, "process_start", nil)
	if !phStrictInt(processStart) || pyLessEq(processStart, int64(0)) {
		phRaise(phValueError, "Native process identity is unavailable.")
	}
	if pyTruthy(owner) && (!pyEqual(phGet(owner, "provider", nil), provider) || !pyEqual(phGet(owner, "process_id", nil), pid) ||
		!pyEqual(phGet(owner, "process_start", nil), processStart)) {
		phRaise(phValueError, "The foreground prompt owner changed.")
	}
	verified := r.binding(binary, pane, pid, provider)
	bound := verified != nil && verified.Len() > 0
	var session any
	path := ""
	switch {
	case bound:
		session = phIndex(verified, "session_id")
		if transcript := verified.Get("transcript_path"); pyTruthy(transcript) {
			text, ok := transcript.(string)
			if !ok {
				phRaise(phTypeError, "expected str")
			}
			path = phPath(text)
		}
	case provider == "codex":
		session = r.proxySession(pane, pid, processStart)
	default:
		path, session = r.transcript(pid, provider)
	}
	sessionText := session.(string)
	if !pyTruthy(owner) {
		owner = r.recoveryOwner(pane, pid, provider, processStart, sessionText)
	}
	if path == "" {
		if provider == "codex" {
			path = r.exactCodexTranscript(sessionText, account)
		} else {
			path = r.exactClaudeTranscript(sessionText, account)
		}
	}
	if !pyEqual(r.metadata(path, provider), session) {
		phRaise(phValueError, "The saved conversation changed.")
	}
	quiet, context, revision := r.tailEvidence(path, provider)
	var backgroundWork, subagents, harness, hostJobs, imageCurrent any
	if provider == "claude" {
		backgroundWork = r.backgroundShellWork(pid, func() ([]phMCPEntry, bool) {
			entries := r.configuredMCPCommands(pid, account, r.arguments(pid))
			return entries, entries != nil
		})
		subagents = phSubagentWork(path, session)
		harness = r.harnessStatus(pid, account)
		hostJobs = r.backgroundAgentJobs(pid, account)
	}
	versions := r.agentVersions(pid, provider)
	if provider == "claude" {
		imageCurrent = r.currentClaudeImage(pid)
	} else {
		imageCurrent = versions.imageCurrent
	}
	// An NFS-renamed or package-replaced image can leave no path evidence.
	outdated := r.installedUpdate(pid, provider) || phNewerInstalled(versions)
	// A restart never moves a pane onto a different install; that is reported only.
	update := outdated && versions.sameInstall == true
	var command, commandError any
	base := ""
	if provider == "codex" {
		if exception := phCatch(func() {
			descriptorPath := phJoin(phWorkerStateDirectory(), "relay/workers/codex-proxies", pane, "descriptor.json")
			remote := ""
			if phExists(descriptorPath) {
				descriptor := r.privateJSON(descriptorPath)
				address, ok := phGet(descriptor, "frontend_socket", nil).(string)
				if !pyEqual(phGet(descriptor, "pane", nil), pane) || !ok || !strings.HasPrefix(address, "/") {
					phRaise(phValueError, "The managed frontend route is unavailable.")
				}
				remote = "unix://" + address
			}
			resume := phCodexResumeCommand(r.arguments(pid), sessionText, context,
				[]string{binary, "agent", "codex"}, remote, r.isLinux, true)
			if update {
				resume = phPinnedCodexCommand(resume, versions.launcher)
			}
			base = resume
			command = phAccountCommand(resume, provider, account)
		}, phOSError, phValueError); exception != nil {
			command, commandError = nil, exception.msg
		}
	} else {
		if exception := phCatch(func() {
			native := r.nativeClaude(pid, update)
			arguments := r.arguments(pid)
			launcher := []string{binary, "agent", "claude"}
			prior := phCatch(func() {
				base = phClaudeResumeCommand(arguments, sessionText, launcher, native)
			}, phValueError)
			if prior != nil {
				if prior.msg != "This custom Claude launch needs a manual restart." {
					phRaise(prior.kind, prior.msg)
				}
				idle := bound && quiet == "quiet" && pyEqual(backgroundWork, false) && pyEqual(subagents, false) &&
					(harness == nil || pyEqual(harness, "idle")) && pyEqual(hostJobs, int64(0))
				proof := phProveClaudeInitialPrompt(path, sessionText, arguments, revision, r.uid, idle)
				base = phClaudeResumeCommandWithPrompt(arguments, sessionText, launcher, native, proof)
			}
			command = phAccountCommand(base, provider, account)
		}, phOSError, phValueError); exception != nil {
			command, commandError = nil, exception.msg
		}
	}
	var moved, moveError, accountMatches any
	if target != nil {
		if exception := phCatch(func() {
			moved = r.accountMoveCommand(provider, sessionText, path, base, account, *target, binary)
		}, phOSError, phValueError); exception != nil {
			moveError = exception.msg
		}
	}
	ownerAfter := r.promptOwner(binary, pane)
	if ownerAfter == nil {
		ownerAfter = r.recoveryOwner(pane, pid, provider, processStart, sessionText)
	}
	if !bound && provider == "codex" && r.proxySession(pane, pid, processStart) != sessionText {
		phRaise(phValueError, "The frontend changed its selected session.")
	}
	if r.identity(pid) != start || r.accountOverride(pid, provider) != account ||
		!pyEqual(phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), provider}, 5)), kernel) ||
		!pyEqual(ownerAfter, owner) {
		phRaise(phValueError, "The native process changed during inspection.")
	}
	if expect != nil {
		accountMatches = phSameAccount(provider, phAccountDirectory(*expect, provider), account)
	}
	return pyObj("version", int64(1), "pane_id", pane, "provider", provider, "process_id", pid,
		"process_start", processStart, "session_id", session, "bound", bound,
		"lifecycle", quiet, "revision", revision, "owner", owner,
		"installed_update", update, "installed_image_current", imageCurrent,
		"running_version", versions.running, "installed_version", versions.installed,
		"outdated_other_install", outdated && versions.sameInstall != true,
		"background_work", backgroundWork, "subagent_work", subagents,
		"harness_status", harness, "background_agent_jobs", hostJobs, "resume_command", command, "resume_error", commandError,
		"config_dir", phAccountLabelDir(account, provider),
		"account_matches", accountMatches, "move_command", moved, "move_error", moveError)
}

// installedRelayImage is installed_relay_image(binary): the reviewed
// shared-home launcher resolved without evaluating shell text.
func (r *phReader) installedRelayImage(binary string) string {
	path := phResolve(binary, true)
	info := phMustStat(path, true)
	if phStatUID(info) != r.uid || info.Mode().Perm()&0o022 != 0 {
		phRaise(phValueError, "The installed helper is not owner controlled.")
	}
	script := phReadPrefix(path, 4+8193)
	if strings.HasPrefix(script, "\x7fELF") {
		return path
	}
	digest := sha256.Sum256([]byte(script))
	if len(script) > 8192 || hex.EncodeToString(digest[:]) != phRelayArchLauncherSHA256 {
		phRaise(phValueError, "The helper launcher has no reviewed native-image mapping.")
	}
	arch := map[string]string{"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[phMachine()]
	if arch == "" {
		phRaise(phValueError, "The native helper architecture is unavailable.")
	}
	target := phResolve(phJoin(phHome(), ".local/share/relay/bin", "relayd-linux-"+arch), true)
	info = phMustStat(target, true)
	if phStatUID(info) != r.uid || info.Mode().Perm()&0o022 != 0 {
		phRaise(phValueError, "The native helper payload is not owner controlled.")
	}
	if phReadPrefix(target, 4) != "\x7fELF" {
		phRaise(phValueError, "The native helper payload is not an ELF image.")
	}
	return target
}

// phFileDigest hashes a bounded image.
func phFileDigest(path string) string {
	file := phOpenRead(path)
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, phWorkerImageLimit+1))
	if err != nil {
		phRaiseOS(err)
	}
	if len(data) > phWorkerImageLimit {
		phRaise(phValueError, "The worker image exceeds the inspection limit.")
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// workerObservation is worker_observation(reader, pane, binary): the worker
// is read separately from the provider process and never upgraded.
func (r *phReader) workerObservation(pane, binary string) *pyObject {
	var result *pyObject
	if phCatchAll(func() {
		rows := phLoads(r.run([]string{binary, "upgrade-workers", "--dry-run", "--session", pane}, 5))
		list, ok := rows.(*pyList)
		if !ok {
			phRaise(phTypeError, "rows")
		}
		if len(list.items) != 1 || !pyEqual(phGet(list.items[0], "session_id", nil), pane) {
			phRaise(phValueError, "The worker response did not match this pane.")
		}
		row := list.items[0]
		outcome := phGet(row, "result", nil)
		phHashKey(outcome)
		mode := "unavailable"
		switch outcome {
		case "legacy":
			mode = "restart_required"
		case "would_upgrade", "current":
			mode = "in_place"
		}
		update := "unverified"
		switch {
		case mode == "restart_required":
			update = "update_required"
		case mode == "in_place" && outcome == "current":
			update = "current"
		}
		result = pyObj("worker_pid", phGet(row, "worker_pid", nil), "upgrade_mode", mode, "update_state", update)
		if mode == "unavailable" {
			switch message := phGet(row, "message", "The worker is unavailable.").(type) {
			case string:
				result.Set("unavailable", pyTruncateRunes(message, 160))
			case *pyList:
				result.Set("unavailable", &pyList{items: message.items[:min(160, len(message.items))]})
			default:
				phRaise(phTypeError, "object is not subscriptable")
			}
			return
		}
		paths := phWorkerManifests(pane)
		if len(paths) != 1 {
			phRaise(phValueError, "The worker manifest is ambiguous.")
		}
		manifest := r.privateJSON(paths[0])
		pid, start := phGet(manifest, "worker_pid", nil), phGet(manifest, "worker_start_time", nil)
		if !pyEqual(pid, phGet(row, "worker_pid", nil)) || !pyEqual(r.kernelStart(pid), start) {
			phRaise(phValueError, "The worker incarnation changed.")
		}
		result.Set("worker_start", start)
		if r.isLinux {
			running := phPath("/proc/" + pyStr(pid) + "/exe")
			beforeDev, beforeIno := phStatDevIno(phMustStat(running, true))
			current, installed := phFileDigest(running), phFileDigest(r.installedRelayImage(binary))
			afterDev, afterIno := phStatDevIno(phMustStat(running, true))
			if beforeDev != afterDev || beforeIno != afterIno || !pyEqual(r.kernelStart(pid), start) {
				phRaise(phValueError, "The worker image changed during inspection.")
			}
			state := "update_required"
			if current == installed {
				state = "current"
			}
			result.Set("running_sha256", current)
			result.Set("installed_sha256", installed)
			result.Set("update_state", state)
		} else if mode == "in_place" && update != "current" {
			result.Set("unavailable", "The loaded worker image has not been compared on this host.")
		}
	}) {
		return pyObj("upgrade_mode", "unavailable", "update_state", "unverified",
			"unavailable", "The exact running worker could not be verified.")
	}
	return result
}

// phUUID4 is str(uuid.uuid4()).
func phUUID4() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		phRaiseOS(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// contextObservation is context_observation(reader, pane, binary).
func (r *phReader) contextObservation(pane, binary string) *pyObject {
	var result *pyObject
	if phCatchAll(func() {
		command := exec.Command(binary, "rotation-supervisor-rpc", pane, phUUID4())
		command.Env = phBackendEnvironment()
		command.Stdin = strings.NewReader(`{"v": 1, "operation": "status"}`)
		var stdout rotationBoundedOutput
		command.Stdout = &stdout
		command.Stderr = io.Discard
		if err := command.Start(); err != nil {
			phRaiseOS(err)
		}
		waited := make(chan error, 1)
		go func() { waited <- command.Wait() }()
		var cancelled <-chan struct{}
		if r.ctx != nil {
			cancelled = r.ctx.Done()
		}
		select {
		case err := <-waited:
			if err != nil {
				phRaise(phOSError, "Command returned non-zero exit status")
			}
		case <-time.After(5 * time.Second):
			_ = command.Process.Kill()
			<-waited
			phRaise(phTimeout, "Command timed out")
		case <-cancelled:
			_ = command.Process.Kill()
			<-waited
			phRaise(phTimeout, "Command cancelled")
		}
		value := phLoadsBytes(stdout.Bytes())
		enabled, ok := phGet(value, "enabled", nil).(bool)
		if !pyEqual(phGet(value, "v", nil), int64(1)) || !ok {
			result = pyObj("supported", false, "enabled", false, "state", "unsupported_worker")
			return
		}
		result = pyObj("supported", true, "enabled", enabled, "state", phGet(value, "state", "unavailable"))
		for _, key := range []string{"generation", "lifecycle", "refresh_capability"} {
			if item, ok := value.(*pyObject).Lookup(key); ok {
				result.Set(key, item)
			}
		}
	}) {
		return pyObj("supported", false, "enabled", false, "state", "unavailable",
			"unavailable", "Native context status could not be verified.")
	}
	return result
}

// phBackendEnvironment is the former Python backend's os.environ.
func phBackendEnvironment() []string {
	if environment := hostRotationTextEnvironment(); environment != nil {
		return environment
	}
	return os.Environ()
}

// probe is the backend's probe(pane): any inspection failure is reported as
// one fixed unverified proof, then the worker and context observations.
func (r *phReader) probe(pane, binary string) *pyObject {
	var proof *pyObject
	if phCatchAll(func() { proof = r.inspect(pane, binary) }) {
		proof = pyObj("version", int64(1), "unavailable", phProbeUnavailableReason)
	}
	proof.Set("worker", r.workerObservation(pane, binary))
	proof.Set("context", r.contextObservation(pane, binary))
	return proof
}
