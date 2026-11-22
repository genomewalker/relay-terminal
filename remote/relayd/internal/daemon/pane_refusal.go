package daemon

import (
	"encoding/json"
	"errors"
	"strings"
)

// Reason codes for a refused pane operation (close, restart, update, account
// move, same-pane resume). The values are shared with Relay's
// RelayPaneOperationRefusal.Code raw values; a code Relay does not know is
// shown as unclassified with its blocker text.
const (
	PaneRefusalIdentityUnavailable = "identity_unavailable"
	PaneRefusalPaneChanged         = "pane_changed"
	PaneRefusalResumeUnavailable   = "resume_unavailable"
	PaneRefusalManualRestart       = "manual_restart_required"
	PaneRefusalLoginMismatch       = "login_mismatch"
	PaneRefusalTargetAccount       = "target_account_unavailable"
	PaneRefusalRelaunchUnavailable = "relaunch_unavailable"
	PaneRefusalOutsideProject      = "outside_project"
	PaneRefusalLauncherUnavailable = "launcher_unavailable"
	PaneRefusalInvalidRequest      = "invalid_request"
	PaneRefusalTrustPrompt         = "trust_prompt"
	PaneRefusalOutsideProxy        = "native_outside_proxy"
	PaneRefusalInitialPrompt       = "initial_prompt_unproven"
	PaneRefusalUnclassified        = "unclassified"
)

// PaneRefusal says which fence held, what holds it and what clears it. Its
// Error text is the blocker alone, so existing messages are unchanged.
type PaneRefusal struct {
	Code       string `json:"reason_code"`
	Blocker    string `json:"blocker"`
	HowToClear string `json:"how_to_clear"`
}

func (r *PaneRefusal) Error() string { return r.Blocker }

var paneRefusalClearing = map[string]string{
	PaneRefusalIdentityUnavailable: "Wait until the pane shows its agent prompt again, then retry with the pane's current session.",
	PaneRefusalPaneChanged:         "The pane's agent changed during the check; read the pane again and retry with its current session.",
	PaneRefusalResumeUnavailable:   "Make sure the conversation's transcript exists in the pane's account, or restart the agent by hand.",
	PaneRefusalManualRestart:       "This launch uses options Relay does not replay; exit and start the agent by hand in the same pane.",
	PaneRefusalLoginMismatch:       "Log the account folder in to its pinned ChatGPT account (relayd codex-login), or move the pane to another account.",
	PaneRefusalTargetAccount:       "Turn on shared conversation history for the target account in Settings and sync it, then retry.",
	PaneRefusalRelaunchUnavailable: "Nothing was sent. Relaunch the agent by hand in this pane, or restart it through Relay maintenance.",
	PaneRefusalOutsideProject:      "Run the resume from a pane whose agent works in the saved conversation's project.",
	PaneRefusalLauncherUnavailable: "Repair Relay's agent launchers on that host (relayd agent-launchers --repair), then retry.",
	PaneRefusalInvalidRequest:      "Pass the exact pane and session UUIDs.",
	PaneRefusalTrustPrompt:         "Trust the folder in the Codex account's config.toml (or enable Relay's matching-parent trust setting), then retry; Relay never answers the trust dialog.",
	PaneRefusalOutsideProxy:        "Exit this Codex yourself (or close its task in Codex desktop), then relaunch the conversation from Relay's launch form (relay_launch_agent), which runs it through Relay's proxy.",
	PaneRefusalInitialPrompt:       "The launch prompt could not be matched to a completed turn of this conversation; restart the agent by hand.",
	PaneRefusalUnclassified:        "Read the blocker text; it names what held the operation.",
}

func newPaneRefusal(code, blocker string) *PaneRefusal {
	how, ok := paneRefusalClearing[code]
	if !ok {
		code, how = PaneRefusalUnclassified, paneRefusalClearing[PaneRefusalUnclassified]
	}
	return &PaneRefusal{Code: code, Blocker: blocker, HowToClear: how}
}

// paneRefusalPatterns classifies the host's existing refusal texts, which the
// maintenance reader raises from deep inside its checks. Order matters: the
// first matching fragment wins.
var paneRefusalPatterns = []struct{ fragment, code string }{
	{"initial Claude prompt is not verified", PaneRefusalInitialPrompt},
	{"needs a manual restart", PaneRefusalManualRestart},
	{"ChatGPT", PaneRefusalLoginMismatch},
	{"logged in", PaneRefusalLoginMismatch},
	{"not visible from the target account", PaneRefusalTargetAccount},
	{"target account could not bind", PaneRefusalTargetAccount},
	{"already uses that account", PaneRefusalTargetAccount},
	{"account directory is invalid", PaneRefusalTargetAccount},
	{"changed during", PaneRefusalPaneChanged},
	{"changed its selected session", PaneRefusalPaneChanged},
	{"launcher unavailable", PaneRefusalLauncherUnavailable},
	{"managed frontend route is unavailable", PaneRefusalRelaunchUnavailable},
	{"outside Relay's proxy", PaneRefusalOutsideProxy},
	{"outside this pane's project", PaneRefusalOutsideProject},
	{"resume command is unavailable", PaneRefusalResumeUnavailable},
	{"missing or ambiguous", PaneRefusalResumeUnavailable},
	{"launch policy is unavailable", PaneRefusalResumeUnavailable},
	{"permission policy is unavailable", PaneRefusalResumeUnavailable},
	{"sandbox is unavailable", PaneRefusalResumeUnavailable},
	{"current Codex directory is unavailable", PaneRefusalResumeUnavailable},
}

// classifyPaneRefusal is the code for an existing refusal text.
func classifyPaneRefusal(message string) string {
	for _, pattern := range paneRefusalPatterns {
		if strings.Contains(message, pattern.fragment) {
			return pattern.code
		}
	}
	return PaneRefusalUnclassified
}

// paneRefusalCodeOrNil is the code for an optional refusal text in a
// maintenance observation: nil when there is no refusal.
func paneRefusalCodeOrNil(message any) any {
	text, ok := message.(string)
	if !ok || text == "" {
		return nil
	}
	return classifyPaneRefusal(text)
}

// PaneRefusalLine is the second stderr line a refusing pane-operation
// command prints after its "relayd: <blocker>" line, for Relay to read the
// structured form. An error that is not a PaneRefusal is classified by text.
func PaneRefusalLine(err error) string {
	if err == nil {
		return ""
	}
	var refusal *PaneRefusal
	if !errors.As(err, &refusal) {
		refusal = newPaneRefusal(classifyPaneRefusal(err.Error()), err.Error())
	}
	data, mErr := json.Marshal(refusal)
	if mErr != nil {
		return ""
	}
	return "refusal: " + string(data)
}
