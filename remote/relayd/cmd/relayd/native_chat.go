package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/nativechat"
)

// Explicit opt-in, in a newly created pane. Existing TUI launches are unchanged.
func runNativeChat(arguments []string) {
	if len(arguments) != 2 && len(arguments) != 4 {
		fatal("usage: relayd native-chat <codex|claude> <instance-id> [source-pane source-instance]")
	}
	provider, instance := arguments[0], arguments[1]
	identity := nativechat.Identity{Pane: os.Getenv("RELAY_SESSION"), Instance: instance, Provider: provider}
	if !identity.Valid() {
		fatal("native conversation requires an exact pane, provider and instance")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	cwd, err := os.Getwd()
	if err != nil {
		fatal(err.Error())
	}
	admitAccount(home, provider, false)
	prepareAccount(home, provider)
	stateRoot := filepath.Join(home, ".local", "share", "relay")
	accountRoot := codexHome(os.Environ())
	if provider == "claude" {
		accountRoot = claudeConfigRoot(home)
	}
	options := nativechat.ProviderOptions{Provider: provider, CWD: cwd, AccountRoot: accountRoot}
	if len(arguments) == 4 {
		source := nativechat.Identity{Pane: arguments[2], Instance: arguments[3], Provider: provider}
		plan, planErr := nativechat.ReadResumePlan(stateRoot, source, accountRoot, daemon.NativeChatKernel())
		if planErr != nil {
			fatal(planErr.Error())
		}
		if err = os.Chdir(plan.CWD); err != nil {
			fatal(err.Error())
		}
		options.CWD = plan.CWD
		options.Resume = plan.Session
		options.Model = plan.Model
	}
	var executable string
	var args []string
	environment := agentExecEnvironment(os.Environ())
	if provider == "codex" {
		executable, err = resolveStockCodexExecutable()
		if err != nil {
			fatal(err.Error())
		}
		root := codexHome(os.Environ())
		defaults := accountModelDefaults(provider, root)
		if options.Model == "" {
			options.Model = defaults.Model
		}
		args = []string{"app-server", "--listen", "stdio://"}
		policy, configured, policyErr := agentlaunch.CodexLaunchDefaults(root)
		if policyErr != nil {
			fatal(policyErr.Error())
		}
		if configured {
			args = append(args, policy.AppServerArguments()...)
		}
		if defaults.Model != "" {
			args = append(args, "-c", "model="+strconv.Quote(defaults.Model))
		}
		if defaults.Effort != "" {
			args = append(args, "-c", "model_reasoning_effort="+strconv.Quote(defaults.Effort))
		}
		environment = stockCodexEnvironment(environment)
	} else {
		executable, err = findRealAgentExecutable("claude")
		if err != nil {
			fatal(err.Error())
		}
		root := claudeConfigRoot(home)
		defaults := accountModelDefaults(provider, root)
		if options.Model == "" {
			options.Model = defaults.Model
		}
		options.Session = instance
		if options.Resume != "" {
			options.Session = options.Resume
		}
		args = []string{"--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio", "--session-id", instance}
		if options.Resume != "" {
			args = args[:len(args)-2]
			args = append(args, "--resume", options.Resume)
		}
		if options.Model != "" {
			args = append(args, "--model", options.Model)
		}
		if defaults.Effort != "" {
			args = append(args, "--effort", defaults.Effort)
		}
		mode, configured, policyErr := agentlaunch.ClaudeLaunchDefaults(root)
		if policyErr != nil {
			fatal(policyErr.Error())
		}
		if configured {
			if mode == "bypassPermissions" {
				args = append(args, "--dangerously-skip-permissions")
			} else {
				args = append(args, "--permission-mode", mode)
			}
		}
	}
	fmt.Fprintln(os.Stderr, "Relay native conversation: "+provider+"; use this pane's conversation view.")
	if err = daemon.ServeNativeChat(context.Background(), nativechat.RunConfig{
		Identity: identity, Provider: options, Executable: executable, Arguments: args,
		Environment: environment, Root: stateRoot,
	}); err != nil {
		fatal(err.Error())
	}
}
