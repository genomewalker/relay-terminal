package main

import (
	"encoding/json"
	"os"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// runCodexLogin: `relayd codex-login status` lists every configured Codex
// account with the ChatGPT account its auth.json is logged in to (8-character
// id prefix, plan, email domain) and its pin; `pin LABEL` pins the label to
// the account logged in there now; `unpin LABEL` removes the pin. Tokens,
// full ids and emails are never printed.
func runCodexLogin(arguments []string) {
	request := agentaccounts.Request{Provider: "codex"}
	switch {
	case len(arguments) == 1 && arguments[0] == "status":
		request.Action = "list"
	case len(arguments) == 2 && (arguments[0] == "pin" || arguments[0] == "unpin"):
		request.Action, request.Label = arguments[0]+"_login", arguments[1]
	default:
		fatal("usage: relayd codex-login status | pin LABEL | unpin LABEL")
	}
	var statuses []agentaccounts.Status
	if request.Action == "list" {
		// Read-only: no account lock, no removal recovery.
		home, err := os.UserHomeDir()
		if err != nil {
			fatal("home unavailable")
		}
		registry, err := agentaccounts.Load(home)
		if err != nil {
			fatal(err.Error())
		}
		statuses = agentaccounts.List(home, registry, nil)
	} else {
		response, err := agentaccounts.Handle(request, nil)
		if err != nil {
			fatal(err.Error())
		}
		statuses = response.Accounts
	}
	type row struct {
		Label  string                    `json:"label"`
		Dir    string                    `json:"dir"`
		Pinned string                    `json:"pinned,omitempty"`
		Status string                    `json:"status"`
		Login  *agentaccounts.CodexLogin `json:"login,omitempty"`
	}
	rows := []row{}
	for _, status := range statuses {
		if status.Provider == "codex" {
			rows = append(rows, row{Label: status.Label, Dir: status.Dir, Pinned: status.ExpectAccount,
				Status: status.LoginStatus, Login: status.Login})
		}
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(rows)
}
