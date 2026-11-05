package subscriptionquota

import (
	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"os"
)

// Include configured account identities, not only the helper's default account.
// Only identity digests and configured display metadata leave the reader;
// credentials are never returned, refreshed or used to authenticate here.
// There is no provider launch or inference. Cached meters keep verified scopes.
func (r *Reader) identities() []map[string]any {
	defaults := []map[string]any{}
	for _, provider := range []string{"codex", "claude"} {
		defaults = append(defaults, map[string]any{"provider": provider, "account_scope": r.accountScope(provider), "identity_only": true})
	}
	registry, err := agentaccounts.Load(r.home)
	if err != nil {
		return defaults
	}
	extra := []map[string]any{}
	for _, account := range registry.Accounts {
		if account.Dir != "" {
			if info, err := os.Stat(account.Root(r.home)); err != nil || !info.IsDir() {
				continue
			}
		}
		scoped := *r
		scoped.env = func(key string) (string, bool) {
			variable := "CLAUDE_CONFIG_DIR"
			if account.Provider == "codex" {
				variable = "CODEX_HOME"
			}
			if key == variable {
				return account.Override(r.home), account.Dir != ""
			}
			return r.env(key)
		}
		scope := scoped.accountScope(account.Provider)
		row := map[string]any{"provider": account.Provider, "account_scope": scope,
			"identity_only": true, "account_label": account.Label, "configured_plan": account.ExpectPlan}
		matched := false
		variable := "CLAUDE_CONFIG_DIR"
		if account.Provider == "codex" {
			variable = "CODEX_HOME"
		}
		override, overridden := r.env(variable)
		sameUnknownDefault := scope == nil && account.Dir == "" && (!overridden || override == "")
		for _, current := range defaults {
			if (scope != nil || sameUnknownDefault) && current["provider"] == account.Provider && current["account_scope"] == scope {
				current["account_label"] = account.Label
				current["configured_plan"] = account.ExpectPlan
				matched = true
				break
			}
		}
		if !matched {
			extra = append(extra, row)
		}
	}
	// Retain default identity rows and their ordering for older clients.
	return append(extra, defaults...)
}
