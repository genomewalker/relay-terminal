package daemon

import (
	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// codexLoginCheck compares the Codex folder an override selects ("" = the
// default folder) with the ChatGPT account its label is pinned to. A registry
// that cannot be read pins nothing.
func codexLoginCheck(home, override string) agentaccounts.LoginCheck {
	registry, err := agentaccounts.Load(home)
	if err != nil {
		registry = agentaccounts.Registry{}
	}
	return agentaccounts.CheckCodexLogin(home, registry, override)
}

// codexLoginRefusal is the refusal text for a pinned Codex folder logged in
// to another account, or "".
func codexLoginRefusal(home, override string) string {
	if err := codexLoginCheck(home, override).Refusal(); err != nil {
		return err.Error()
	}
	return ""
}

// codexLoginObservation is the running pane's login for the pane list: the
// folder's label, its pin, the account its auth.json names now (8-character
// prefix and plan; never a token, full id or email) and whether the process
// started before auth.json last changed (startedEpoch < 0: unknown). A
// running Codex keeps the login it loaded until it is restarted.
func codexLoginObservation(home, override string, startedEpoch float64) *pyObject {
	check := codexLoginCheck(home, override)
	var before any
	if startedEpoch > 0 && !check.Login.Modified.IsZero() {
		before = startedEpoch < float64(check.Login.Modified.Unix())
	}
	optional := func(value string) any {
		if value == "" {
			return nil
		}
		return value
	}
	return pyObj("status", check.Status, "label", optional(check.Label), "expected", optional(check.Expected),
		"state", check.Login.State, "account", optional(check.Login.Account), "plan", optional(check.Login.Plan),
		"started_before_login_change", before)
}
