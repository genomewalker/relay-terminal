package main

import (
	"encoding/json"
	"flag"
	"io"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// agentInventory is a read-only, dispatch-oriented view of this host's agent
// accounts: which provider accounts exist, whether they are logged in, their
// plan and identity keys, their default model, and the plan-limit windows the
// provider CLI itself reports right now. Emails are not included: identity
// and workspace keys are enough to tell accounts apart. Nothing is written.
type agentInventory struct {
	Version     string                `json:"version"`
	Host        string                `json:"host"`
	ReadAt      string                `json:"read_at"`
	Executables map[string]string     `json:"executables"`
	Accounts    []agentInventoryEntry `json:"accounts"`
	Errors      []string              `json:"errors,omitempty"`
}

type agentInventoryEntry struct {
	Provider     string               `json:"provider"`
	Label        string               `json:"label"`
	Default      bool                 `json:"default"`
	LoggedIn     string               `json:"logged_in"`
	Method       string               `json:"method,omitempty"`
	Plan         string               `json:"plan,omitempty"`
	IdentityKey  string               `json:"identity_key,omitempty"`
	WorkspaceKey string               `json:"workspace_key,omitempty"`
	Probe        string               `json:"probe,omitempty"`
	ProbeReason  string               `json:"probe_reason,omitempty"`
	Model        string               `json:"default_model,omitempty"`
	Effort       string               `json:"default_effort,omitempty"`
	Usage        *agentInventoryUsage `json:"usage"`
}

type agentInventoryUsage struct {
	Status  string                      `json:"status"`
	Reason  string                      `json:"reason,omitempty"`
	Source  string                      `json:"source,omitempty"`
	ReadAt  string                      `json:"read_at,omitempty"`
	Windows []agentaccounts.UsageWindow `json:"windows,omitempty"`
}

type inventorySource struct {
	list  func() (agentaccounts.Response, error)
	usage func() (agentaccounts.Response, error)
	model func(provider, root string) (agentaccounts.ModelDefaults, error)
	home  func() (string, error)
}

func liveInventorySource() inventorySource {
	return inventorySource{
		list: func() (agentaccounts.Response, error) {
			return agentaccounts.Handle(agentaccounts.Request{Action: "list", Probe: true}, agentaccounts.ProviderProbe)
		},
		usage: func() (agentaccounts.Response, error) {
			return agentaccounts.Handle(agentaccounts.Request{Action: "usage"}, nil)
		},
		model: agentaccounts.ReadModelDefaults,
		home:  os.UserHomeDir,
	}
}

func buildAgentInventory(source inventorySource, host string, now time.Time) agentInventory {
	inventory := agentInventory{Version: relaydVersion, Host: host, ReadAt: now.UTC().Format(time.RFC3339), Accounts: []agentInventoryEntry{}}
	listed, err := source.list()
	if err != nil {
		inventory.Errors = append(inventory.Errors, "accounts: "+err.Error())
		return inventory
	}
	inventory.Executables = listed.Executables
	usage := map[string]agentaccounts.Usage{}
	if read, err := source.usage(); err != nil {
		inventory.Errors = append(inventory.Errors, "usage: "+err.Error())
	} else {
		for _, u := range read.Usage {
			usage[u.Provider+"\x00"+u.Label] = u
		}
	}
	home, _ := source.home()
	for _, account := range listed.Accounts {
		entry := agentInventoryEntry{Provider: account.Provider, Label: account.Label, Default: account.Default,
			LoggedIn: account.LoggedIn, Method: account.Method, Plan: account.Plan, IdentityKey: account.IdentityKey,
			WorkspaceKey: account.WorkspaceKey, Probe: account.Probe, ProbeReason: account.ProbeReason}
		root := account.Root
		if root == "" && home != "" {
			root = home
		}
		if defaults, err := source.model(account.Provider, root); err == nil {
			entry.Model, entry.Effort = defaults.Model, defaults.Effort
		}
		if u, ok := usage[account.Provider+"\x00"+account.Label]; ok {
			entry.Usage = &agentInventoryUsage{Status: u.Status, Reason: u.Reason, Source: u.Source, ReadAt: u.ReadAt, Windows: u.Windows}
			// Codex reports plan and identity with its usage.
			if entry.Plan == "" {
				entry.Plan = u.Plan
			}
			if entry.IdentityKey == "" {
				entry.IdentityKey = u.IdentityKey
			}
			if entry.WorkspaceKey == "" {
				entry.WorkspaceKey = u.WorkspaceKey
			}
		} else {
			entry.Usage = &agentInventoryUsage{Status: agentaccounts.UsageUnknown, Reason: "not read"}
		}
		inventory.Accounts = append(inventory.Accounts, entry)
	}
	return inventory
}

func runAgentInventory(arguments []string, out io.Writer) error {
	flags := flag.NewFlagSet("agent-inventory", flag.ContinueOnError)
	host := flags.String("host", "", "host label to record (default: hostname)")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	name := *host
	if name == "" {
		name, _ = os.Hostname()
	}
	encoder := json.NewEncoder(out)
	encoder.SetIndent("", "  ")
	return encoder.Encode(buildAgentInventory(liveInventorySource(), name, time.Now()))
}
