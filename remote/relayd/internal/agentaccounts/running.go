package agentaccounts

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// agentProcessName decides which processes count as agents when Sync checks
// that nothing is running in an account. Tests replace it.
var agentProcessName = func(name string) bool {
	name = strings.ToLower(name)
	return strings.Contains(name, "claude") || strings.Contains(name, "codex") || name == "node"
}

type runningProcess struct {
	pid  int
	name string
}

// runningAgents lists this user's agent processes whose config variable
// selects the account root (compared as resolved real paths). Processes whose
// environment cannot be read are skipped: only this user's own processes are
// considered, and those are readable.
func runningAgents(provider, root string) ([]runningProcess, error) {
	variable, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return nil, err
	}
	processes, err := userProcesses()
	if err != nil {
		return nil, err
	}
	want := realPath(root)
	self := os.Getpid()
	var found []runningProcess
	for _, process := range processes {
		if process.pid == self || !agentProcessName(process.name) {
			continue
		}
		vars, err := agentlaunch.ProcessEnvironment(process.pid, variable)
		if err != nil || vars[variable] == "" || !filepath.IsAbs(vars[variable]) {
			continue
		}
		if realPath(vars[variable]) == want {
			found = append(found, process)
		}
	}
	sort.Slice(found, func(i, j int) bool { return found[i].pid < found[j].pid })
	return found, nil
}

// refuseWhileRunning stops a sync while an agent uses the account: Claude and
// Codex rewrite their configuration from memory and would undo or race it.
func refuseWhileRunning(provider, root string) error {
	running, err := runningAgents(provider, root)
	if err != nil {
		return errors.New("could not verify that no agent is using this account; nothing was changed")
	}
	if len(running) == 0 {
		return nil
	}
	pids := make([]string, 0, len(running))
	for _, process := range running {
		pids = append(pids, strconv.Itoa(process.pid))
	}
	return errors.New("Stop the " + provider + " agents using this account first (pids " + strings.Join(pids, ", ") +
		"); syncing while they run can lose their configuration writes.")
}

func realPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return filepath.Clean(path)
}
