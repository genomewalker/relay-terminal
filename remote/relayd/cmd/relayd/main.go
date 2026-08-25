package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/protocol"
)

func main() {
	invocation := filepath.Base(os.Args[0])
	if invocation == "rcode" {
		runRCode(os.Args[1:])
		return
	}
	if invocation == "claude" || invocation == "codex" {
		runAgent(append([]string{invocation}, os.Args[1:]...))
		return
	}
	if len(os.Args) < 2 {
		fatal("usage: relayd <daemon|attach|observe|event|agent|artifact|files>")
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "worker":
		runWorker(os.Args[2:])
	case "attach":
		runAttach(os.Args[2:])
	case "observe":
		runObserve(os.Args[2:])
	case "event":
		runEvent(os.Args[2:])
	case "agent":
		runAgent(os.Args[2:])
	case "artifact":
		runArtifact(os.Args[2:])
	case "files":
		runFiles(os.Args[2:])
	case "--version", "version":
		fmt.Println("relayd 0.3.2")
	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func runRCode(arguments []string) {
	flags := flag.NewFlagSet("rcode", flag.ExitOnError)
	diff := flags.Bool("diff", false, "open a diff; one path compares with Git HEAD, two paths compare with each other")
	_ = flags.Parse(arguments)
	paths := flags.Args()
	if len(paths) == 0 || len(paths) > 2 || !*diff && len(paths) != 1 {
		fatal("usage: rcode [--diff] <file> [other-file]")
	}
	resolved := make([]string, 0, len(paths))
	for _, path := range paths {
		absolute, err := filepath.Abs(path)
		if err != nil {
			fatal(err.Error())
		}
		canonical, err := filepath.EvalSymlinks(absolute)
		if err != nil {
			fatal(err.Error())
		}
		info, err := os.Stat(canonical)
		if err != nil || !info.Mode().IsRegular() {
			fatal("not a regular file: " + path)
		}
		resolved = append(resolved, canonical)
	}
	session := os.Getenv("RELAY_SESSION")
	if session == "" {
		fatal("rcode must run inside a Relay-managed terminal pane")
	}
	event, err := json.Marshal(struct {
		Type  string   `json:"type"`
		Paths []string `json:"paths"`
		Diff  bool     `json:"diff"`
	}{Type: "open_file", Paths: resolved, Diff: *diff})
	if err != nil {
		fatal(err.Error())
	}
	envelope, err := json.Marshal(struct {
		Agent string          `json:"agent"`
		Event json.RawMessage `json:"event"`
	}{Agent: "relay", Event: event})
	if err != nil {
		fatal(err.Error())
	}
	connection, err := connectOrStart(defaultSocket())
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: session, EventOnly: true,
	})
	if err := writer.Write(hello); err != nil {
		fatal(err.Error())
	}
	if err := writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: envelope}); err != nil {
		fatal(err.Error())
	}
}

func runFiles(arguments []string) {
	if len(arguments) == 0 {
		fatal("usage: relayd files <workspace|list|read|write|git-diff>")
	}
	flags := flag.NewFlagSet("files "+arguments[0], flag.ExitOnError)
	pathBase64 := flags.String("path-b64", "", "base64-encoded absolute path")
	parentSession := flags.String("parent-session", "", "terminal session whose working directory should be used")
	expectedModificationNS := flags.Int64("expected-modification-ns", 0, "mtime used for conflict detection")
	_ = flags.Parse(arguments[1:])
	path := ""
	if *pathBase64 != "" {
		var err error
		path, err = daemon.DecodePath(*pathBase64)
		if err != nil {
			fatal(err.Error())
		}
	}
	var value any
	var err error
	switch arguments[0] {
	case "workspace":
		value, err = daemon.ResolveWorkspace(*parentSession, path)
	case "list":
		value, err = daemon.ListDirectory(path)
	case "read":
		value, err = daemon.ReadEditorFile(path)
	case "write":
		value, err = daemon.WriteEditorFile(path, *expectedModificationNS, os.Stdin)
	case "git-diff":
		value, err = daemon.ReadGitDiff(path)
	default:
		fatal("usage: relayd files <workspace|list|read|write|git-diff>")
	}
	if err != nil {
		fatal(err.Error())
	}
	if err := daemon.EncodeJSON(os.Stdout, value); err != nil {
		fatal(err.Error())
	}
}

const maxArtifactBytes = 25 << 20

func runArtifact(arguments []string) {
	flags := flag.NewFlagSet("artifact", flag.ExitOnError)
	pathBase64 := flags.String("path-b64", "", "base64-encoded absolute image path")
	_ = flags.Parse(arguments)
	if *pathBase64 == "" {
		fatal("--path-b64 is required")
	}
	decoded, err := base64.StdEncoding.DecodeString(*pathBase64)
	if err != nil {
		fatal("invalid --path-b64")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	path, err := resolveArtifactPath(string(decoded), home, os.Getuid())
	if err != nil {
		fatal(err.Error())
	}
	file, err := os.Open(path)
	if err != nil {
		fatal(err.Error())
	}
	defer file.Close()
	if _, err := io.Copy(os.Stdout, io.LimitReader(file, maxArtifactBytes+1)); err != nil {
		fatal(err.Error())
	}
}

func resolveArtifactPath(requested, home string, uid int) (string, error) {
	if !filepath.IsAbs(requested) {
		return "", fmt.Errorf("artifact path must be absolute")
	}
	extension := filepath.Ext(requested)
	switch extension {
	case ".png", ".PNG", ".jpg", ".JPG", ".jpeg", ".JPEG", ".gif", ".GIF", ".webp", ".WEBP":
	default:
		return "", fmt.Errorf("unsupported artifact type")
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(requested))
	if err != nil {
		return "", err
	}
	allowedRoots := []string{filepath.Clean(home), filepath.Join("/tmp", "claude-"+strconv.Itoa(uid))}
	allowed := false
	for _, root := range allowedRoots {
		if canonicalRoot, rootErr := filepath.EvalSymlinks(root); rootErr == nil {
			root = canonicalRoot
		}
		relative, relErr := filepath.Rel(root, resolved)
		if relErr == nil && relative != ".." && !filepath.IsAbs(relative) && !startsWithParent(relative) {
			allowed = true
			break
		}
	}
	if !allowed {
		return "", fmt.Errorf("artifact path is outside allowed directories")
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("artifact is not a regular file")
	}
	if info.Size() > maxArtifactBytes {
		return "", fmt.Errorf("artifact exceeds 25 MiB")
	}
	return resolved, nil
}

func startsWithParent(path string) bool {
	return path == ".." || len(path) > 3 && path[:3] == ".."+string(filepath.Separator)
}

func runAgent(arguments []string) {
	if len(arguments) == 0 {
		fatal("usage: relayd agent <claude|codex> [agent arguments...]")
	}
	switch arguments[0] {
	case "claude":
		runClaude(arguments[1:])
	case "codex":
		runCodex(arguments[1:])
	default:
		fatal("usage: relayd agent <claude|codex> [agent arguments...]")
	}
}

func runClaude(arguments []string) {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	settingsDir := filepath.Join(home, ".relay")
	if err := os.MkdirAll(settingsDir, 0o700); err != nil {
		fatal(err.Error())
	}
	settingsPath := filepath.Join(settingsDir, "claude-hooks.json")
	if err := os.WriteFile(settingsPath, []byte(claudeHookSettings), 0o600); err != nil {
		fatal(err.Error())
	}
	executable, err := findRealAgentExecutable("claude")
	if err != nil {
		fatal("claude is not available on PATH")
	}
	claudeArguments := []string{"claude", "--settings", settingsPath}
	claudeArguments = append(claudeArguments, arguments...)
	if err := syscall.Exec(executable, claudeArguments, os.Environ()); err != nil {
		fatal(err.Error())
	}
}

func runCodex(arguments []string) {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	configDir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		fatal(err.Error())
	}
	profilePath := filepath.Join(configDir, "relay-terminal.config.toml")
	if err := os.WriteFile(profilePath, []byte(codexHookProfile(profilePath)), 0o600); err != nil {
		fatal(err.Error())
	}
	executable, err := findRealAgentExecutable("codex")
	if err != nil {
		fatal("codex is not available on PATH")
	}
	codexArguments := []string{"codex", "--profile", "relay-terminal"}
	codexArguments = append(codexArguments, arguments...)
	if err := syscall.Exec(executable, codexArguments, os.Environ()); err != nil {
		fatal(err.Error())
	}
}

func findRealAgentExecutable(name string) (string, error) {
	selfPath, selfErr := os.Executable()
	var selfInfo os.FileInfo
	if selfErr == nil {
		selfInfo, _ = os.Stat(selfPath)
	}
	for _, directory := range filepath.SplitList(os.Getenv("PATH")) {
		if directory == "" {
			directory = "."
		}
		candidate := filepath.Join(directory, name)
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		if selfInfo != nil && os.SameFile(selfInfo, info) {
			continue
		}
		if !filepath.IsAbs(candidate) {
			candidate, err = filepath.Abs(candidate)
			if err != nil {
				continue
			}
		}
		return candidate, nil
	}
	return "", fmt.Errorf("%s is not available on PATH", name)
}

const codexHookCommand = `if [ -n "$RELAY_SESSION" ]; then ~/.local/bin/relayd event --session "$RELAY_SESSION" --agent codex; fi`

type codexHookSpec struct {
	event   string
	matcher *string
}

var codexWildcardMatcher = "*"

var codexHookSpecs = []codexHookSpec{
	{event: "session_start", matcher: &codexWildcardMatcher},
	{event: "user_prompt_submit"},
	{event: "pre_tool_use", matcher: &codexWildcardMatcher},
	{event: "permission_request", matcher: &codexWildcardMatcher},
	{event: "post_tool_use", matcher: &codexWildcardMatcher},
	{event: "subagent_start", matcher: &codexWildcardMatcher},
	{event: "subagent_stop", matcher: &codexWildcardMatcher},
	{event: "stop"},
	{event: "session_end", matcher: &codexWildcardMatcher},
}

func codexHookProfile(profilePath string) string {
	var state strings.Builder
	state.WriteString("# Managed by Relay Terminal. Remove this file to uninstall the profile.\n")
	for _, spec := range codexHookSpecs {
		key := profilePath + ":" + spec.event + ":0:0"
		state.WriteString("[hooks.state.")
		state.WriteString(strconv.Quote(key))
		state.WriteString("]\ntrusted_hash = ")
		state.WriteString(strconv.Quote(codexHookHash(spec.event, spec.matcher)))
		state.WriteString("\n\n")
	}
	state.WriteString(codexHookEvents)
	return state.String()
}

func codexHookHash(event string, matcher *string) string {
	identity := map[string]any{
		"event_name": event,
		"hooks": []any{map[string]any{
			"type": "command", "command": codexHookCommand, "async": true, "timeout": 3,
		}},
	}
	if matcher != nil {
		identity["matcher"] = *matcher
	}
	serialized, _ := json.Marshal(identity)
	digest := sha256.Sum256(serialized)
	return fmt.Sprintf("sha256:%x", digest)
}

const codexHookEvents = `
[[hooks.SessionStart]]
matcher = "*"
[[hooks.SessionStart.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PreToolUse]]
matcher = "*"
[[hooks.PreToolUse.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PostToolUse]]
matcher = "*"
[[hooks.PostToolUse.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SubagentStart]]
matcher = "*"
[[hooks.SubagentStart.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SubagentStop]]
matcher = "*"
[[hooks.SubagentStop.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SessionEnd]]
matcher = "*"
[[hooks.SessionEnd.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3
`

const claudeHookSettings = `{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "~/.local/bin/relayd event --session $RELAY_SESSION --agent claude"}]}]
  }
}`

func runEvent(arguments []string) {
	flags := flag.NewFlagSet("event", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "Relay session ID")
	agent := flags.String("agent", "unknown", "agent kind")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		fatal(err.Error())
	}
	if len(raw) == 0 || !json.Valid(raw) {
		raw = []byte(`{}`)
	}
	envelope, err := json.Marshal(struct {
		Agent string          `json:"agent"`
		Event json.RawMessage `json:"event"`
	}{Agent: *agent, Event: raw})
	if err != nil {
		fatal(err.Error())
	}
	connection, err := net.Dial("unix", *socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, EventOnly: true,
	})
	if err := writer.Write(hello); err != nil {
		fatal(err.Error())
	}
	if err := writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: envelope}); err != nil {
		fatal(err.Error())
	}
}

func runDaemon(arguments []string) {
	flags := flag.NewFlagSet("daemon", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	_ = flags.Parse(arguments)
	if err := daemon.NewServer().Serve(*socket); err != nil {
		fatal(err.Error())
	}
}

func runWorker(arguments []string) {
	flags := flag.NewFlagSet("worker", flag.ExitOnError)
	socket := flags.String("socket", "", "private worker Unix socket path")
	manifest := flags.String("manifest", "", "worker manifest path")
	session := flags.String("session", "", "durable session ID")
	cols := flags.Uint("cols", 120, "terminal columns")
	rows := flags.Uint("rows", 36, "terminal rows")
	_ = flags.Parse(arguments)
	token := os.Getenv("RELAY_WORKER_TOKEN")
	commandBase64 := os.Getenv("RELAY_WORKER_COMMAND_B64")
	workingDirectoryBase64 := os.Getenv("RELAY_WORKER_CWD_B64")
	if *socket == "" || *manifest == "" || *session == "" || token == "" {
		fatal("worker requires --socket, --manifest, --session, and RELAY_WORKER_TOKEN")
	}
	decode := func(value, label string) string {
		if value == "" {
			return ""
		}
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			fatal("invalid " + label)
		}
		return string(decoded)
	}
	config := daemon.WorkerConfig{
		SocketPath: *socket, ManifestPath: *manifest,
		SessionID: *session, Token: token,
		Command:          decode(commandBase64, "RELAY_WORKER_COMMAND_B64"),
		WorkingDirectory: decode(workingDirectoryBase64, "RELAY_WORKER_CWD_B64"),
		Cols:             uint16(*cols), Rows: uint16(*rows),
	}
	if err := daemon.ServeWorker(config); err != nil {
		fatal(err.Error())
	}
}

func runAttach(arguments []string) {
	flags := flag.NewFlagSet("attach", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "durable session ID")
	parentSession := flags.String("parent-session", "", "session whose working directory should be inherited")
	commandBase64 := flags.String("command-b64", "", "base64-encoded startup command")
	cols := flags.Uint("cols", 120, "terminal columns")
	rows := flags.Uint("rows", 36, "terminal rows")
	lastSequence := flags.Uint64("last-seq", 0, "last received output sequence")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	command := ""
	if *commandBase64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(*commandBase64)
		if err != nil {
			fatal("invalid --command-b64")
		}
		command = string(decoded)
	}
	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, ParentSessionID: *parentSession, Command: command,
		Cols: uint16(*cols), Rows: uint16(*rows), LastSeq: *lastSequence,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		fatal(err.Error())
	}
	done := make(chan error, 1)
	go func() {
		_, copyErr := io.Copy(connection, os.Stdin)
		done <- copyErr
	}()
	go func() {
		_, copyErr := io.Copy(os.Stdout, connection)
		done <- copyErr
	}()
	if copyErr := <-done; copyErr != nil {
		fatal(copyErr.Error())
	}
}

func runObserve(arguments []string) {
	flags := flag.NewFlagSet("observe", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "durable session ID")
	lastSequence := flags.Uint64("last-seq", 0, "fallback replay position for older workers")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, LastSeq: *lastSequence, ObserveEvents: true,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		fatal(err.Error())
	}
	if _, err := io.Copy(os.Stdout, connection); err != nil {
		fatal(err.Error())
	}
}

func connectOrStart(socket string) (net.Conn, error) {
	if probeDaemon(socket) {
		return net.Dial("unix", socket)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return nil, err
	}
	logPath := filepath.Join(filepath.Dir(socket), "relayd.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	defer logFile.Close()
	child := exec.Command(os.Args[0], "daemon", "--socket", socket)
	child.Stdin = nil
	child.Stdout = logFile
	child.Stderr = logFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return nil, err
	}
	_ = child.Process.Release()
	for attempt := 0; attempt < 80; attempt++ {
		time.Sleep(25 * time.Millisecond)
		if connection, dialErr := net.Dial("unix", socket); dialErr == nil {
			return connection, nil
		}
	}
	return nil, fmt.Errorf("relayd did not start (pid %s)", strconv.Itoa(child.Process.Pid))
}

func probeDaemon(socket string) bool {
	connection, err := net.DialTimeout("unix", socket, 250*time.Millisecond)
	if err != nil {
		return false
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(500 * time.Millisecond))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: "_probe", Probe: true,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return false
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return false
	}
	var status protocol.StatusPayload
	return protocol.DecodeJSON(frame, &status) == nil && status.State == "ready"
}

func defaultSocket() string {
	if runtime := os.Getenv("XDG_RUNTIME_DIR"); runtime != "" {
		return filepath.Join(runtime, "relayd.sock")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/relayd-" + strconv.Itoa(os.Getuid()) + ".sock"
	}
	return filepath.Join(home, ".relay", "relayd.sock")
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "relayd:", message)
	os.Exit(1)
}
