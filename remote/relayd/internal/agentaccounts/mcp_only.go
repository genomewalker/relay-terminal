package agentaccounts

import (
	"encoding/json"
	"errors"
	"os"
	"time"
)

// SyncMCPOnlyReviewed copies only reviewed MCP registrations. It neither
// prepares accounts nor changes shared links, history, onboarding or trust.
// This saves configuration for future launches. It does not restart, signal,
// or update the MCP connections held by any running Claude process. A launcher
// racing the save reads one complete old or new file. The shared atomic-exchange
// writer preserves concurrent provider saves and refuses unsupported filesystems.
// Call under the host account lock. An uncertain write must be reconciled by
// reading the account; callers must not retry with a new operation identity.
func SyncMCPOnlyReviewed(home string, account Account, now time.Time, fingerprint string) (SyncResult, error) {
	result := SyncResult{Provider: account.Provider, Label: account.Label, Links: []LinkResult{}, MCP: MergeRefused}
	if fingerprint == "" {
		return result, errors.New("review the account's MCP servers before syncing")
	}
	if account.Dir == "" {
		return result, errors.New("the main account cannot be the sync target")
	}
	if account.Provider != "claude" {
		return result, errors.New("MCP-only sync currently supports Claude accounts only")
	}
	root := account.Root(home)
	main := defaultRoot(home, account.Provider)
	if err := distinctRoots(main, root); err != nil {
		return result, err
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return result, errors.New("the target account directory is unavailable")
	}
	plan, err := preflight(home, main, root, account)
	if err != nil {
		return result, err
	}
	if plan.claude == nil {
		return result, errors.New("Claude MCP plan unavailable")
	}
	// Preserve account-specific registrations. A same-name difference requires
	// a separate explicit resolution; a source preview alone did not review it.
	var incoming map[string]json.RawMessage
	if plan.claude.servers != nil && json.Unmarshal(plan.claude.servers, &incoming) != nil {
		return result, errors.New("invalid source MCP servers")
	}
	if incoming == nil {
		incoming = make(map[string]json.RawMessage)
	}
	if previous, ok := plan.claude.document["mcpServers"]; ok {
		var existing map[string]json.RawMessage
		if json.Unmarshal(previous, &existing) != nil || existing == nil {
			return result, errors.New("invalid target MCP servers")
		}
		for name, value := range existing {
			if candidate, found := incoming[name]; found && !equalJSON(candidate, value) {
				return result, errors.New("a target MCP server conflicts with the reviewed source")
			}
			if _, found := incoming[name]; !found {
				incoming[name] = value
			}
		}
	}
	plan.claude.servers, err = json.Marshal(incoming)
	if err != nil {
		return result, err
	}
	// The shared writer fast-paths an identical target without a fresh read.
	// Revalidate both files first so an unchanged result has a real observation.
	if previous, ok := plan.claude.document["mcpServers"]; ok && equalJSON(previous, plan.claude.servers) {
		current, readErr := readJSONKey(plan.claude.mainPath, "mcpServers")
		if readErr != nil || current == nil || !equalJSON(current, plan.claude.mainServers) ||
			!sameContent(plan.claude.accountPath, plan.claude.before, plan.claude.data) {
			return result, errors.New("the MCP configuration changed during review")
		}
	}
	if err := consumeMCPReview(account, plan.claude.mainServers, fingerprint); err != nil {
		return result, err
	}
	stamp := now.UTC().Format("20060102T150405Z")
	err = plan.claude.write(stamp, &result)
	if err != nil {
		result.MCP = "outcome_unknown"
		return result, err
	}
	if result.MCP == MergeUpdated || result.MCP == MergeUnchanged {
		observed, readErr := readJSONKey(plan.claude.accountPath, "mcpServers")
		if readErr != nil || observed == nil || !equalJSON(observed, plan.claude.servers) {
			result.MCP = "outcome_unknown"
			return result, errors.New("the target MCP configuration could not be verified")
		}
	}
	return result, nil
}
