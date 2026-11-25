package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

func TestAgentInventoryMergesUsageAndDefaultsWithoutEmail(t *testing.T) {
	source := inventorySource{
		list: func() (agentaccounts.Response, error) {
			return agentaccounts.Response{Executables: map[string]string{"claude": "/x/claude"}, Accounts: []agentaccounts.Status{
				{Provider: "claude", Label: "business", Root: "/h/.claude-team", Default: true, LoggedIn: "yes", Email: "someone@example.org", Plan: "max", IdentityKey: "ik1", Probe: "ok"},
				{Provider: "codex", Label: "personal", Root: "/h/.codex", LoggedIn: "yes"},
				{Provider: "claude", Label: "spare", Root: "/h/.claude-spare", LoggedIn: "no"},
			}}, nil
		},
		usage: func() (agentaccounts.Response, error) {
			return agentaccounts.Response{Usage: []agentaccounts.Usage{
				{Provider: "claude", Label: "business", Status: "ok", Source: "claude get_usage", ReadAt: "t1",
					Windows: []agentaccounts.UsageWindow{{Name: "five_hour", UsedPercent: 12, ResetsAt: "r1"}}},
				{Provider: "codex", Label: "personal", Status: "ok", Identity: agentaccounts.Identity{Email: "other@example.org", Plan: "pro", IdentityKey: "ik2", WorkspaceKey: "wk2"}},
			}}, nil
		},
		model: func(provider, root string) (agentaccounts.ModelDefaults, error) {
			if root == "/h/.claude-team" {
				return agentaccounts.ModelDefaults{Model: "opus", Effort: "high"}, nil
			}
			return agentaccounts.ModelDefaults{}, errors.New("none")
		},
		home: func() (string, error) { return "/h", nil },
	}
	inventory := buildAgentInventory(source, "dandy-07", time.Unix(0, 0))
	raw, _ := json.Marshal(inventory)
	if strings.Contains(string(raw), "@example.org") {
		t.Fatalf("inventory carries an email: %s", raw)
	}
	if len(inventory.Accounts) != 3 || inventory.Host != "dandy-07" || inventory.Executables["claude"] != "/x/claude" {
		t.Fatalf("inventory %s", raw)
	}
	business, codex, spare := inventory.Accounts[0], inventory.Accounts[1], inventory.Accounts[2]
	if business.Model != "opus" || business.Effort != "high" || business.Usage.Status != "ok" || len(business.Usage.Windows) != 1 || business.Plan != "max" {
		t.Fatalf("business %+v", business)
	}
	if codex.Plan != "pro" || codex.IdentityKey != "ik2" || codex.WorkspaceKey != "wk2" {
		t.Fatalf("codex identity not taken from usage: %+v", codex)
	}
	if spare.Usage.Status != "unknown" || spare.Usage.Reason != "not read" {
		t.Fatalf("unread usage must be unknown: %+v", spare.Usage)
	}
}

func TestAgentInventoryReportsFailuresInsteadOfGuessing(t *testing.T) {
	failing := inventorySource{
		list: func() (agentaccounts.Response, error) {
			return agentaccounts.Response{}, errors.New("registry unreadable")
		},
		usage: func() (agentaccounts.Response, error) {
			t.Fatal("usage read after list failed")
			return agentaccounts.Response{}, nil
		},
		model: agentaccounts.ReadModelDefaults,
		home:  func() (string, error) { return "/h", nil },
	}
	inventory := buildAgentInventory(failing, "mac", time.Unix(0, 0))
	if len(inventory.Accounts) != 0 || len(inventory.Errors) != 1 || !strings.Contains(inventory.Errors[0], "registry unreadable") {
		t.Fatalf("%+v", inventory)
	}
	usageDown := inventorySource{
		list: func() (agentaccounts.Response, error) {
			return agentaccounts.Response{Accounts: []agentaccounts.Status{{Provider: "claude", Label: "a", LoggedIn: "yes"}}}, nil
		},
		usage: func() (agentaccounts.Response, error) { return agentaccounts.Response{}, errors.New("cli missing") },
		model: func(string, string) (agentaccounts.ModelDefaults, error) {
			return agentaccounts.ModelDefaults{}, errors.New("none")
		},
		home: func() (string, error) { return "/h", nil },
	}
	inventory = buildAgentInventory(usageDown, "mac", time.Unix(0, 0))
	if len(inventory.Errors) != 1 || inventory.Accounts[0].Usage.Status != "unknown" {
		t.Fatalf("%+v", inventory)
	}
}
