package agentaccounts

import "errors"

// errAccountsBusy means another accounts change holds the lock right now.
var errAccountsBusy = errors.New("an accounts change is in progress")

// lockRefusal describes a failed non-blocking lock for the user: a change in
// progress only when the lock is actually held, otherwise the real error.
func lockRefusal(err error) string {
	if errors.Is(err, errAccountsBusy) {
		return "an accounts change is in progress"
	}
	return err.Error()
}
