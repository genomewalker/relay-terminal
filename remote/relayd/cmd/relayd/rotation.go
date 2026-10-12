package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/daemon"
)

func runRotationLaunch(arguments []string) {
	flags := flag.NewFlagSet("rotation-launch", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained launch snapshot")
	digest := flags.String("sha", "", "exact snapshot SHA-256")
	intent := flags.String("intent", "", "stable rotation intent")
	source := flags.String("source-session", "", "exact live Claude source session")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *path == "" || *digest == "" || *intent == "" || *source == "" {
		fatal("invalid rotation launch request")
	}
	var plan struct {
		Arguments []string `json:"arguments"`
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 65_537))
	if err != nil || len(input) > 65_536 || json.Unmarshal(input, &plan) != nil || len(plan.Arguments) == 0 {
		fatal("invalid private rotation launch plan")
	}
	session, pane, err := daemon.NewServer().LaunchClaudeRotationPane(*path, *digest, *intent, *source, plan.Arguments)
	if err != nil {
		fatal("rotation launch refused: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"session_id": session, "pane_id": pane})
}

// rotation-exec is invoked inside the new dedicated worker. It rechecks the
// source incarnation and the private snapshot before replacing itself with
// the exact agent binary. No setting, prompt, or environment value is logged.
func runRotationExec(arguments []string) {
	flags := flag.NewFlagSet("rotation-exec", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained launch snapshot")
	digest := flags.String("sha", "", "exact snapshot SHA-256")
	intent := flags.String("intent", "", "stable rotation intent")
	session := flags.String("session", "", "new Claude session")
	source := flags.String("source-session", "", "exact live Claude source session")
	pane := flags.String("pane", "", "dedicated Relay pane")
	claim := flags.String("claim", "", "private retained rotation claim")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *session != daemon.ClaudeRotationID(*intent) ||
		*pane != daemon.ClaudeRotationID(*intent+":pane") || os.Getenv("RELAY_SESSION") != *pane {
		fatal("rotation worker identity mismatch")
	}
	snapshot, err := agentlaunch.ReadVerified(*path, *digest)
	if err != nil {
		fatal("rotation snapshot refused")
	}
	if err := agentlaunch.VerifyProcess(snapshot); err != nil {
		fatal("rotation source incarnation changed")
	}
	effective, err := agentlaunch.DiscoverClaudeEffectiveSettings(snapshot, *source)
	if err != nil {
		fatal("Claude effective source settings changed")
	}
	if cwd, err := os.Getwd(); err != nil || cwd != snapshot.CWD {
		fatal("rotation working directory changed")
	}
	args, err := daemon.ReadClaudeRotationClaim(*claim, *intent, *pane, *session, *source, *digest, effective.FreshArguments)
	if err != nil {
		fatal("private rotation launch plan unavailable")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal("private home unavailable")
	}
	newSnapshot, err := agentlaunch.Save(filepath.Join(home, ".local", "share", "relay", "agent-launches"),
		"claude", snapshot.Executable, snapshot.CWD, *pane, agentlaunch.ProcessStart(), args, args)
	if err != nil {
		fatal("fresh launch snapshot unavailable")
	}
	if err := os.Setenv("RELAY_AGENT_LAUNCH_SNAPSHOT", newSnapshot); err != nil {
		fatal("launch environment unavailable")
	}
	if !filepath.IsAbs(snapshot.Executable) {
		fatal("agent executable is not absolute")
	}
	if err := syscall.Exec(snapshot.Executable, append([]string{snapshot.Executable}, args...), os.Environ()); err != nil {
		fatal("agent execution failed: " + errors.New("executable unavailable").Error())
	}
}

// The text arrives on stdin, never in argv, shell history, worker manifests,
// logs, or a supervisor reconnection queue.
func runRotationSend(arguments []string) {
	if len(arguments) != 0 {
		fatal("rotation-send takes a single JSON input on stdin")
	}
	var request struct {
		PaneID       string `json:"pane_id"`
		OperationID  string `json:"operation_id"`
		PID          int    `json:"pid"`
		ProcessStart uint64 `json:"process_start"`
		Text         string `json:"text"`
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 10_001))
	if err != nil || len(input) > 10_000 {
		fatal("guarded input request exceeds size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		fatal("invalid guarded input request")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		fatal("guarded input request has trailing data")
	}
	if err := daemon.NewServer().GuardedRotationInput(request.PaneID, request.OperationID,
		request.PID, request.ProcessStart, request.Text); err != nil {
		fatal(err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"accepted": true, "operation_id": request.OperationID})
}

func runRotationStatus(arguments []string) {
	flags := flag.NewFlagSet("rotation-status", flag.ExitOnError)
	pane := flags.String("pane", "", "exact controlled rotation pane")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *pane == "" {
		fatal("invalid rotation status request")
	}
	status, err := daemon.NewServer().RotationStatus(*pane)
	if err != nil {
		fatal("rotation status unavailable: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(status)
}

func runCodexRuntime(arguments []string) {
	flags := flag.NewFlagSet("codex-runtime", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained Codex launch snapshot")
	digest := flags.String("sha", "", "exact snapshot SHA-256")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *path == "" || *digest == "" {
		fatal("invalid Codex runtime request")
	}
	snapshot, err := agentlaunch.ReadVerifiedClient(*path, *digest, "codex")
	if err != nil {
		fatal("Codex launch snapshot refused")
	}
	socket, err := agentlaunch.DiscoverCodexSocket(snapshot)
	if err != nil {
		fatal("Codex control socket unavailable: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(socket)
}

func runCodexStartParameters(arguments []string) {
	flags := flag.NewFlagSet("codex-start-parameters", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained Codex launch snapshot")
	digest := flags.String("sha", "", "exact snapshot SHA-256")
	thread := flags.String("thread", "", "exact source app-server thread")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *path == "" || *digest == "" || *thread == "" {
		fatal("invalid Codex start-parameters request")
	}
	snapshot, err := agentlaunch.ReadVerifiedClient(*path, *digest, "codex")
	if err != nil {
		fatal("Codex launch snapshot refused")
	}
	settings, err := agentlaunch.DiscoverCodexStartSettings(snapshot, *thread)
	if err != nil {
		fatal("Codex effective settings unavailable: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(settings)
}

func runClaudeStartParameters(arguments []string) {
	flags := flag.NewFlagSet("claude-start-parameters", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained Claude launch snapshot")
	digest := flags.String("sha", "", "exact snapshot SHA-256")
	session := flags.String("session", "", "exact source Claude session")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *path == "" || *digest == "" || *session == "" {
		fatal("invalid Claude start-parameters request")
	}
	snapshot, err := agentlaunch.ReadVerifiedClient(*path, *digest, "claude")
	if err != nil {
		fatal("Claude launch snapshot refused")
	}
	settings, err := agentlaunch.DiscoverClaudeEffectiveSettings(snapshot, *session)
	if err != nil {
		fatal("Claude effective settings unavailable: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(settings)
}
