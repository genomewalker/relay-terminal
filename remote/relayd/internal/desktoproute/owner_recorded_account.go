package desktoproute

import (
	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// localOwnerRuntime resolves the owner processes of this machine.
func localOwnerRuntime(home string) *remoteRuntime {
	return &remoteRuntime{home: home, inspect: inspectProcess, environment: agentlaunch.ProcessEnvironment}
}

// recordLocalOwnerAccount records a local owner's account from the exact live
// process when the route is created. An unresolved owner leaves the route
// unrecorded; its listener backfills the account once the owner verifies.
func recordLocalOwnerAccount(local *remoteRuntime, c Config) Config {
	if c.Host != "laptop" {
		return c
	}
	if root, err := local.accountRoot(c.RemotePID, c.RemoteStart); err == nil {
		c.RemoteAccount = root
	}
	return c
}
