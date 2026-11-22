package daemon

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// Every refusal code has clearing advice, and an unknown code is reported as
// unclassified with the blocker kept.
func TestPaneRefusalEveryCodeSaysHowToClear(t *testing.T) {
	for code, how := range paneRefusalClearing {
		refusal := newPaneRefusal(code, "held")
		if refusal.Code != code || refusal.HowToClear != how || how == "" || refusal.Error() != "held" {
			t.Fatalf("%s: %+v", code, refusal)
		}
	}
	if refusal := newPaneRefusal("no_such_code", "held"); refusal.Code != PaneRefusalUnclassified || refusal.Blocker != "held" {
		t.Fatalf("unknown code: %+v", refusal)
	}
}

// The host's existing refusal texts each map to their code.
func TestPaneRefusalClassifiesExistingHostTexts(t *testing.T) {
	for message, code := range map[string]string{
		"This custom Claude launch needs a manual restart.":                                     PaneRefusalManualRestart,
		"A custom remote Codex endpoint needs a manual restart.":                                PaneRefusalManualRestart,
		"This conversation is not visible from the target account. Turn on shared conversation": PaneRefusalTargetAccount,
		"The target account could not bind this conversation after the move.":                   PaneRefusalTargetAccount,
		"The agent already uses that account.":                                                  PaneRefusalTargetAccount,
		"The native process changed during inspection.":                                         PaneRefusalPaneChanged,
		"The managed frontend route is unavailable.":                                            PaneRefusalRelaunchUnavailable,
		"The exact agent resume command is unavailable.":                                        PaneRefusalResumeUnavailable,
		"saved session is missing or ambiguous in the original account":                         PaneRefusalResumeUnavailable,
		"The saved Codex sandbox is unavailable on this host; automatic restart is held.":       PaneRefusalResumeUnavailable,
		phClaudeInitialPromptRefusal:                                                            PaneRefusalInitialPrompt,
		"something new":                                                                         PaneRefusalUnclassified,
	} {
		if got := classifyPaneRefusal(message); got != code {
			t.Fatalf("%q: %s, want %s", message, got, code)
		}
	}
	if paneRefusalCodeOrNil(nil) != nil || paneRefusalCodeOrNil("") != nil {
		t.Fatal("no refusal must have no code")
	}
}

// The refusal line carries the structured form for typed and plain errors.
func TestPaneRefusalLineIsStructured(t *testing.T) {
	_, err := ReadCodexPaneResumePlan("../pane", "session", "target")
	var refusal *PaneRefusal
	if !errors.As(err, &refusal) || refusal.Code != PaneRefusalInvalidRequest {
		t.Fatalf("plan refusal: %#v", err)
	}
	_, err = ReadClaudePaneResumePlan("../pane", "session")
	if !errors.As(err, &refusal) || refusal.Code != PaneRefusalInvalidRequest {
		t.Fatalf("claude plan refusal: %#v", err)
	}
	for _, test := range []struct {
		err  error
		code string
	}{{err, PaneRefusalInvalidRequest}, {errors.New("The managed frontend route is unavailable."), PaneRefusalRelaunchUnavailable}} {
		line := PaneRefusalLine(test.err)
		var decoded PaneRefusal
		if !strings.HasPrefix(line, "refusal: ") || json.Unmarshal([]byte(strings.TrimPrefix(line, "refusal: ")), &decoded) != nil ||
			decoded.Code != test.code || decoded.Blocker != test.err.Error() || decoded.HowToClear == "" {
			t.Fatalf("line %q", line)
		}
	}
	if PaneRefusalLine(nil) != "" {
		t.Fatal("nil error printed a refusal")
	}
}
