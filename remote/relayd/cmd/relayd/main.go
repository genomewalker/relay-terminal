package main

import (
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
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/protocol"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: relayd <daemon|attach|event|agent|artifact>")
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "worker":
		runWorker(os.Args[2:])
	case "attach":
		runAttach(os.Args[2:])
	case "event":
		runEvent(os.Args[2:])
	case "agent":
		runAgent(os.Args[2:])
	case "artifact":
		runArtifact(os.Args[2:])
	case "--version", "version":
		fmt.Println("relayd 0.2.0")
	default:
		fatal("unknown command: " + os.Args[1])
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
	executable, err := exec.LookPath("claude")
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
	if err := os.WriteFile(profilePath, []byte(codexHookProfile), 0o600); err != nil {
		fatal(err.Error())
	}
	executable, err := exec.LookPath("codex")
	if err != nil {
		fatal("codex is not available on PATH")
	}
	codexArguments := []string{"codex", "--profile", "relay-terminal"}
	codexArguments = append(codexArguments, arguments...)
	if err := syscall.Exec(executable, codexArguments, os.Environ()); err != nil {
		fatal(err.Error())
	}
}

const codexHookCommand = `if [ -n "$RELAY_SESSION" ]; then ~/.local/bin/relayd event --session "$RELAY_SESSION" --agent codex; fi`

const codexHookProfile = `# Managed by Relay Terminal. Remove this file to uninstall the profile.
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
