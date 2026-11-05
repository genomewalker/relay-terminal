package main

import (
	"encoding/json"
	"os"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// runAgentLaunchers prints the managed claude/codex launchers' state as
// JSON; with --repair it first installs missing and fixes stale ones. The
// remote installer and the app both use this one code path. It exits 1 when
// a launcher is still not usable, after printing every state.
func runAgentLaunchers(arguments []string) {
	repair := len(arguments) == 1 && arguments[0] == "--repair"
	if len(arguments) > 1 || (len(arguments) == 1 && !repair) {
		fatal("usage: relayd agent-launchers [--repair]")
	}
	host, err := agentaccounts.ThisLauncherHost()
	if err != nil {
		fatal(err.Error())
	}
	statuses := agentaccounts.Launchers(host)
	if repair {
		statuses = agentaccounts.RepairLaunchers(host)
	}
	encoded, _ := json.Marshal(map[string]any{"launchers": statuses})
	os.Stdout.Write(append(encoded, '\n'))
	for _, status := range statuses {
		switch status.State {
		case agentaccounts.LauncherCurrent, agentaccounts.LauncherInstalled, agentaccounts.LauncherRepaired, agentaccounts.LauncherCustom:
		default:
			os.Exit(1)
		}
	}
}
