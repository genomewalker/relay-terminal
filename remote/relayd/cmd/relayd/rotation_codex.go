package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/daemon"
)

func runCodexRotationLaunch(arguments []string) {
	flags := flag.NewFlagSet("rotation-codex-launch", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained launch snapshot")
	digest := flags.String("sha", "", "snapshot SHA-256")
	intent := flags.String("intent", "", "stable rotation intent")
	thread := flags.String("thread", "", "new app-server root thread")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *path == "" || *digest == "" || *intent == "" || *thread == "" {
		fatal("invalid Codex rotation launch request")
	}
	var plan struct {
		Arguments []string `json:"arguments"`
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 65_537))
	if err != nil || len(input) > 65_536 {
		fatal("invalid private Codex rotation plan")
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&plan) != nil || len(plan.Arguments) == 0 {
		fatal("invalid private Codex rotation plan")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		fatal("Codex rotation plan has trailing data")
	}
	pane, err := daemon.NewServer().LaunchCodexRotationPane(*path, *digest, *intent, *thread, plan.Arguments)
	if err != nil {
		fatal("Codex rotation launch refused: " + err.Error())
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"session_id": *thread, "pane_id": pane})
}

func runCodexRotationExec(arguments []string) {
	flags := flag.NewFlagSet("rotation-codex-exec", flag.ExitOnError)
	path := flags.String("snapshot", "", "private retained launch snapshot")
	digest := flags.String("sha", "", "snapshot SHA-256")
	intent := flags.String("intent", "", "stable rotation intent")
	thread := flags.String("thread", "", "new app-server root thread")
	pane := flags.String("pane", "", "dedicated Relay pane")
	claim := flags.String("claim", "", "private retained launch claim")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *pane != daemon.ClaudeRotationID(*intent+":pane") || os.Getenv("RELAY_SESSION") != *pane {
		fatal("Codex rotation worker identity mismatch")
	}
	snapshot, err := agentlaunch.ReadVerifiedClient(*path, *digest, "codex")
	if err != nil {
		fatal("Codex rotation snapshot refused")
	}
	if cwd, err := os.Getwd(); err != nil || cwd != snapshot.CWD {
		fatal("Codex rotation working directory changed")
	}
	args, err := daemon.ReadCodexRotationClaim(*claim, *intent, *pane, *thread, *digest, snapshot)
	if err != nil {
		fatal("Codex rotation claim refused")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal("private home unavailable")
	}
	newSnapshot, err := agentlaunch.Save(filepath.Join(home, ".local", "share", "relay", "agent-launches"),
		"codex", snapshot.Executable, snapshot.CWD, *pane, agentlaunch.ProcessStart(), args, args)
	if err != nil {
		fatal("fresh Codex launch snapshot unavailable")
	}
	if err := os.Setenv("RELAY_AGENT_LAUNCH_SNAPSHOT", newSnapshot); err != nil {
		fatal("launch environment unavailable")
	}
	if err := os.Setenv("TERM", "xterm-256color"); err != nil {
		fatal("terminal environment unavailable")
	}
	if err := syscall.Exec(snapshot.Executable, append([]string{snapshot.Executable}, args...), os.Environ()); err != nil {
		fatal("Codex execution failed")
	}
}
