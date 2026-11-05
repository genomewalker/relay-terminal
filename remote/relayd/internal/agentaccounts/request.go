package agentaccounts

import (
	"errors"
	"os"
	"time"
)

// Request is the host RPC body for operation "agent_accounts".
//   - list: accounts with directory, link and logged-in status
//   - configure: replace the label/directory mapping
//   - prepare: create one account directory before its provider login
//   - sync: link shared configuration and merge MCP servers into one account
//     (refused while an agent runs with that account)
//   - usage: plan-limit readings from each provider CLI (optionally one account)
//   - mcp_preview: main MCP servers and their env/header NAMES for one account
//   - launchers: the managed claude/codex launchers' state
//   - repair_launchers: install missing and fix stale managed launchers
//     (never a file Relay did not write)
//   - remove: sign one account out, move its folder to
//     ~/.local/share/relay/retired-accounts-<date>/ and forget the slot
//     (only with origin "user"; see RemoveOrigin)
//   - rename: change a slot's label (folder and login stay)
//   - set_expectation: the workspace and plan a slot is meant for
//   - set_defaults: the model and effort new agents of the account use
type Request struct {
	Action   string    `json:"action"`
	Provider string    `json:"provider,omitempty"`
	Label    string    `json:"label,omitempty"`
	Accounts []Account `json:"accounts,omitempty"`
	// Probe runs the providers' status commands (slower; list only).
	Probe bool `json:"probe,omitempty"`
	// PreviewFingerprint (sync, required): the MCP preview the user
	// reviewed. The sync is refused before any change without it, or if the
	// main servers it reads differ from it.
	PreviewFingerprint string `json:"preview_fingerprint,omitempty"`
	NewLabel           string `json:"new_label,omitempty"`
	ExpectWorkspace    string `json:"expect_workspace,omitempty"`
	ExpectPlan         string `json:"expect_plan,omitempty"`
	ExpectKey          string `json:"expect_key,omitempty"`
	Model              string `json:"model,omitempty"`
	Effort             string `json:"effort,omitempty"`
	// Origin (remove, required): who asked for the change. Only "user" is
	// accepted; see RemoveOrigin.
	Origin string `json:"origin,omitempty"`
}

// RemoveOrigin refuses a removal that does not come from the user. Only
// Relay's native Settings sends origin "user": Relay's tool routes (the
// workspace and host request APIs) never forward agent_accounts, so a tool
// caller cannot reach this request with any origin. A missing or unknown
// origin, and the mcp, assistant and maintenance origins, are refused before
// anything is signed out, moved or forgotten.
func RemoveOrigin(origin string) error {
	switch origin {
	case "user":
		return nil
	case "":
		return errors.New("removing an account needs the user's own confirmation in Relay's Settings; nothing was changed")
	case "mcp", "assistant", "maintenance":
		return errors.New("only the user can remove an account, from Relay's Settings; nothing was changed")
	}
	return errors.New("unknown request origin; nothing was changed")
}

type Response struct {
	Accounts   []Status    `json:"accounts"`
	Sync       *SyncResult `json:"sync,omitempty"`
	Usage      []Usage     `json:"usage,omitempty"`
	MCPPreview *MCPPreview `json:"mcp_preview,omitempty"`
	// Executables maps each provider to the CLI relayd resolves on this
	// host ("" when it is not installed). Login runs that path.
	Executables map[string]string `json:"executables"`
	Launchers   []LauncherStatus  `json:"launchers,omitempty"`
	Removed     *Removed          `json:"removed,omitempty"`
	// RemovalNotes says what happened to removals relayd did not complete.
	RemovalNotes []string `json:"removal_notes,omitempty"`
}

// usageRunner reads plan limits; tests replace it.
var usageRunner UsageRunner = ProviderUsage

func Handle(request Request, probe Prober) (Response, error) {
	if request.Action == "remove" {
		if err := RemoveOrigin(request.Origin); err != nil {
			return Response{}, err
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return Response{}, errors.New("host home unavailable")
	}
	// Account changes run one at a time on this host, after any removal
	// that relayd did not complete is finished or undone. A read waits for
	// no one and recovers only when no change is running.
	var notes []string
	changes := request.Action != "list" && request.Action != "usage" && request.Action != "mcp_preview" && request.Action != "mcp_preview_exact" &&
		request.Action != "launchers" && request.Action != "repair_launchers"
	isolatedMCP := request.Action == "mcp_preview_exact" || request.Action == "mcp_sync_only"
	if unlock, err := lockAccounts(home, changes); err == nil {
		defer unlock()
		if isolatedMCP {
			entries, err := os.ReadDir(removalsDir(home))
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return Response{}, errors.New("account removal state unavailable; MCP operation refused")
			}
			if len(entries) != 0 {
				return Response{}, errors.New("an account removal needs recovery before MCP operations")
			}
		} else {
			notes = RecoverRemovals(home)
		}
	} else if changes || isolatedMCP {
		return Response{}, errors.New("the account list could not be locked for this change; nothing was changed")
	}
	registry, err := Load(home)
	if err != nil {
		return Response{}, err
	}
	if !request.Probe {
		probe = nil
	}
	response := Response{RemovalNotes: notes}
	switch request.Action {
	case "list":
	case "launchers", "repair_launchers":
		host, err := ThisLauncherHost()
		if err != nil {
			return Response{}, err
		}
		if request.Action == "launchers" {
			response.Launchers = Launchers(host)
		} else {
			response.Launchers = RepairLaunchers(host)
		}
	case "configure":
		incoming := KeepExpectations(registry, Registry{Version: registryVersion, Accounts: request.Accounts})
		if registry, err = Save(home, incoming); err != nil {
			return Response{}, err
		}
	case "remove":
		saved, removed, err := Remove(home, registry, request.Provider, request.Label, time.Now())
		if err != nil {
			return Response{}, err
		}
		registry, response.Removed = saved, &removed
	case "rename":
		if registry, err = Rename(home, registry, request.Provider, request.Label, request.NewLabel); err != nil {
			return Response{}, err
		}
	case "set_expectation":
		if registry, err = SetExpectation(home, registry, request.Provider, request.Label,
			request.ExpectWorkspace, request.ExpectPlan, request.ExpectKey); err != nil {
			return Response{}, err
		}
	case "set_defaults":
		account, ok := registry.Find(request.Provider, request.Label)
		if !ok {
			return Response{}, errors.New("unknown account")
		}
		if err := WriteModelDefaults(account.Provider, account.Root(home), request.Model, request.Effort); err != nil {
			return Response{}, err
		}
	case "usage":
		var accounts []Account
		for _, account := range registry.Accounts {
			if (request.Provider == "" || account.Provider == request.Provider) && (request.Label == "" || account.Label == request.Label) {
				accounts = append(accounts, account)
			}
		}
		if len(accounts) == 0 {
			return Response{}, errors.New("unknown account")
		}
		response.Usage = ReadUsage(home, accounts, usageRunner, time.Now())
	case "prepare", "sync", "mcp_preview", "mcp_preview_exact", "mcp_sync_only":
		account, ok := registry.Find(request.Provider, request.Label)
		if !ok {
			return Response{}, errors.New("unknown account")
		}
		switch request.Action {
		case "prepare":
			if err := Prepare(home, account); err != nil {
				return Response{}, err
			}
		case "mcp_preview", "mcp_preview_exact":
			var preview MCPPreview
			var err error
			if request.Action == "mcp_preview_exact" {
				preview, err = PreviewMCPExact(home, account)
			} else {
				preview, err = PreviewMCP(home, account)
			}
			if err != nil {
				return Response{}, err
			}
			response.MCPPreview = &preview
		case "mcp_sync_only":
			result, err := SyncMCPOnlyReviewed(home, account, time.Now(), request.PreviewFingerprint)
			if err != nil {
				if result.MCP == MergeRefused {
					result.Error = err.Error()
				} else {
					result.Error = "The MCP sync outcome is unknown; inspect the account before retrying."
				}
			}
			response.Sync = &result
		default:
			if account.Dir != "" {
				if err := refuseWhileRunning(account.Provider, account.Root(home)); err != nil {
					var result SyncResult
					return Response{}, firstRunWhileRunning(home, account, err, &result)
				}
			}
			if request.PreviewFingerprint == "" {
				return Response{}, errors.New("review the account's MCP servers before syncing; nothing was changed")
			}
			result, err := SyncReviewed(home, account, time.Now(), request.PreviewFingerprint)
			if errors.Is(err, errPreviewChanged) {
				return Response{}, err
			}
			if err != nil {
				result.Error = err.Error()
			}
			response.Sync = &result
		}
	default:
		return Response{}, errors.New("unsupported agent account action")
	}
	response.Accounts = List(home, registry, probe)
	response.Executables = map[string]string{}
	for _, provider := range LauncherProviders {
		response.Executables[provider], _ = ProviderExecutable(provider)
	}
	return response, nil
}
