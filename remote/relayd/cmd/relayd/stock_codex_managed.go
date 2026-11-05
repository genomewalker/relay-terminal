package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/daemon"
)

func managedStockCodexArguments(arguments []string, pane string) bool {
	if pane == "" {
		return false
	}
	for i, arg := range arguments {
		if arg == "--remote" || strings.HasPrefix(arg, "--remote=") || arg == "--help" || arg == "-h" || arg == "--version" || arg == "-V" {
			return false
		}
		switch arg {
		case "-c", "--config", "--enable", "--disable", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "-i", "--image":
			if i+1 >= len(arguments) {
				return false
			}
		}
	}
	// Subcommands that do not open the interactive TUI retain their CLI behavior.
	skip := false
	for _, arg := range arguments {
		if skip {
			skip = false
			continue
		}
		switch arg {
		case "-c", "--config", "--enable", "--disable", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "-i", "--image":
			skip = true
			continue
		}
		if strings.HasPrefix(arg, "-") {
			continue
		}
		switch arg {
		case "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "app-server", "completion", "sandbox", "debug", "apply", "a", "cloud", "features", "help":
			return false
		}
		break
	}
	return true
}

func prepareManagedStockCodex(executable string, arguments []string, environment []string) ([]string, func(), error) {
	pane := os.Getenv("RELAY_SESSION")
	if !managedStockCodexArguments(arguments, pane) {
		return arguments, func() {}, nil
	}
	start, err := daemon.StockCodexLauncherStart()
	if err != nil {
		return nil, nil, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, nil, err
	}
	frontendArguments, permissions, err := agentlaunch.ManagedCodexLaunchPolicy(codexHome(environment), arguments)
	if err != nil {
		return nil, nil, fmt.Errorf("managed Codex launch permissions: %w", err)
	}
	var permissionFlags []string
	if permissions.SandboxMode != "" && permissions.ApprovalPolicy != "" {
		permissionFlags = []string{"--sandbox-mode", permissions.SandboxMode, "--approval-policy", permissions.ApprovalPolicy}
	}
	child := exec.Command(self, append([]string{"codex-managed-backend", "--pane", pane, "--parent", strconv.Itoa(os.Getpid()),
		"--parent-start", strconv.FormatUint(start, 10), "--executable", executable}, permissionFlags...)...)
	child.Env = agentEnvironmentWithout(agentExecEnvironment(environment), "RELAY_AGENT_LAUNCH_SNAPSHOT")
	child.Stderr = os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	output, err := child.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	if err := child.Start(); err != nil {
		return nil, nil, err
	}
	stop := func() { _ = child.Process.Kill(); _ = child.Wait() }
	type receipt struct {
		Version        int    `json:"version"`
		Pane           string `json:"pane"`
		FrontendSocket string `json:"frontend_socket"`
	}
	type result struct {
		value receipt
		err   error
	}
	done := make(chan result, 1)
	go func() {
		var value receipt
		err := json.NewDecoder(io.LimitReader(output, 65537)).Decode(&value)
		done <- result{value, err}
	}()
	select {
	case r := <-done:
		output.Close()
		if r.err != nil || r.value.Version != 1 || r.value.Pane != pane || !filepath.IsAbs(r.value.FrontendSocket) {
			stop()
			return nil, nil, errors.New("managed Codex messaging endpoint was not ready")
		}
		return append([]string{"--remote", "unix://" + r.value.FrontendSocket}, frontendArguments...), stop, nil
	case <-time.After(25 * time.Second):
		stop()
		return nil, nil, errors.New("managed Codex messaging endpoint timed out")
	}
}

func runManagedStockCodexBackend(arguments []string) {
	flags := flag.NewFlagSet("codex-managed-backend", flag.ExitOnError)
	pane := flags.String("pane", "", "retained pane")
	parent := flags.Int("parent", 0, "original launcher PID")
	start := flags.Uint64("parent-start", 0, "original launcher start")
	executable := flags.String("executable", "", "official Codex CLI")
	sandboxMode := flags.String("sandbox-mode", "", "saved sandbox mode of the resumed thread")
	approvalPolicy := flags.String("approval-policy", "", "saved approval policy of the resumed thread")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("unexpected managed Codex arguments")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	environment := stockCodexEnvironment(agentExecEnvironment(os.Environ()))
	if err := daemon.ServeManagedStockCodexBackend(ctx, *pane, *parent, *start, *executable, environment,
		agentlaunch.CodexPermissions{SandboxMode: *sandboxMode, ApprovalPolicy: *approvalPolicy}, os.Stdout); err != nil && ctx.Err() == nil {
		fatal("managed Codex launch unavailable: " + err.Error())
	}
}

func codexHome(environment []string) string {
	return agentlaunch.CodexHome(environment)
}
