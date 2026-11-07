package agentlaunch

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const claudeBypassDefaults = `{"version":1,"permission_mode":"bypassPermissions"}`

func TestClaudeReplayedHooksSettingsAppearOnce(t *testing.T) {
	home := t.TempDir()
	hooks := "/home/u/.relay/claude-hooks.json"
	arguments := []string{"--settings", hooks, "--settings", hooks, "--settings=" + hooks, "--settings", "/home/u/.config/relay/claude-hooks-status.json",
		"--dangerously-skip-permissions", "--resume", "06f2fc08-cd1b-4cc9-b460-153eb62bd6e5"}
	got, err := ManagedClaudeLaunchArguments(home, hooks, arguments)
	want := []string{"--settings", "/home/u/.config/relay/claude-hooks-status.json", "--dangerously-skip-permissions", "--resume", "06f2fc08-cd1b-4cc9-b460-153eb62bd6e5"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Relay hooks settings were not deduplicated or user settings were lost: %q %v", got, err)
	}
	// Prompt text after -- is content, never an option.
	got, err = ManagedClaudeLaunchArguments(home, hooks, []string{"--", "--settings", hooks})
	if err != nil || !reflect.DeepEqual(got, []string{"--", "--settings", hooks}) {
		t.Fatalf("content after -- was changed: %q %v", got, err)
	}
}

func TestClaudeLaunchDefaultsApplyOnlyWithoutExplicitPermissions(t *testing.T) {
	home := t.TempDir()
	hooks := "/h/claude-hooks.json"
	got, err := ManagedClaudeLaunchArguments(home, hooks, []string{"--resume", "s"})
	if err != nil || !reflect.DeepEqual(got, []string{"--resume", "s"}) {
		t.Fatalf("absent defaults changed the launch: %q %v", got, err)
	}
	launchDefaults(t, home, claudeBypassDefaults)
	got, err = ManagedClaudeLaunchArguments(home, hooks, []string{"--resume", "s"})
	if err != nil || !reflect.DeepEqual(got, []string{"--dangerously-skip-permissions", "--resume", "s"}) {
		t.Fatalf("bypass default not applied: %q %v", got, err)
	}
	for _, explicit := range [][]string{{"--permission-mode", "plan"}, {"--permission-mode=plan"}, {"--dangerously-skip-permissions"}} {
		got, err = ManagedClaudeLaunchArguments(home, hooks, explicit)
		if err != nil || !reflect.DeepEqual(got, explicit) {
			t.Fatalf("explicit permission was overridden: %q %v", got, err)
		}
	}
	// Allowing the mode cycle does not choose the starting mode.
	got, err = ManagedClaudeLaunchArguments(home, hooks, []string{"--allow-dangerously-skip-permissions"})
	if err != nil || !reflect.DeepEqual(got, []string{"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"}) {
		t.Fatalf("mode-cycle option treated as a starting mode: %q %v", got, err)
	}
	// Option values and an optional --resume session are skipped by arity.
	in := []string{"--model", "--dangerously-skip-permissions", "--resume", "--add-dir", "/a", "/b", "--continue", "prompt --permission-mode"}
	got, err = ManagedClaudeLaunchArguments(home, hooks, in)
	if err != nil || !reflect.DeepEqual(got, append([]string{"--dangerously-skip-permissions"}, in...)) {
		t.Fatalf("option values were read as options: %q %v", got, err)
	}
	// After an option of unknown arity nothing is inspected and no default is added.
	in = []string{"--future-option", "--settings", hooks}
	got, err = ManagedClaudeLaunchArguments(home, hooks, in)
	if err != nil || !reflect.DeepEqual(got, in) {
		t.Fatalf("arguments after an unknown option were changed: %q %v", got, err)
	}
	launchDefaults(t, home, `{"version":1,"permission_mode":"acceptEdits"}`)
	got, err = ManagedClaudeLaunchArguments(home, hooks, nil)
	if err != nil || !reflect.DeepEqual(got, []string{"--permission-mode", "acceptEdits"}) {
		t.Fatalf("non-bypass default not applied: %q %v", got, err)
	}
}

func TestClaudeLaunchDefaultsRejectUnsafeFiles(t *testing.T) {
	for _, text := range []string{`{"version":1,"permission_mode":"yolo"}`, `{"version":2,"permission_mode":"bypassPermissions"}`,
		`{"version":1,"permission_mode":"bypassPermissions","extra":1}`, claudeBypassDefaults + `{}`} {
		home := t.TempDir()
		launchDefaults(t, home, text)
		// Like Codex, a malformed policy refuses even when the launch is explicit.
		for _, arguments := range [][]string{nil, {"--permission-mode", "plan"}} {
			if _, err := ManagedClaudeLaunchArguments(home, "/h", arguments); err == nil {
				t.Fatalf("malformed defaults accepted: %s %q", text, arguments)
			}
		}
	}
	home := t.TempDir()
	path := filepath.Join(home, "relay-launch-defaults.json")
	if err := os.WriteFile(path, []byte(claudeBypassDefaults), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ManagedClaudeLaunchArguments(home, "/h", nil); err == nil {
		t.Fatal("group/world-readable defaults accepted")
	}
	if _, _, err := ClaudeLaunchDefaults("relative"); err == nil {
		t.Fatal("relative account directory accepted")
	}
}

func TestClaudeRetiredRelaySettingsAreNoLongerPassed(t *testing.T) {
	hooks, retired := "/h/.relay/claude-hooks.json", "/h/.config/relay/claude-hooks-status.json"
	in := []string{"--settings", retired, "--settings=" + retired, "--settings", "/h/mine.json", "--settings", hooks, "--resume", "s"}
	got, err := ManagedClaudeLaunchArguments(t.TempDir(), hooks, in, retired)
	if err != nil || !reflect.DeepEqual(got, []string{"--settings", "/h/mine.json", "--resume", "s"}) {
		t.Fatalf("retired settings kept or user settings lost: %q %v", got, err)
	}
	// Without a retired path, other settings files are the user's and stay.
	got, err = ManagedClaudeLaunchArguments(t.TempDir(), hooks, []string{"--settings", retired})
	if err != nil || !reflect.DeepEqual(got, []string{"--settings", retired}) {
		t.Fatalf("settings removed without being retired: %q %v", got, err)
	}
}

func TestWithoutRelayClaudeSettingsAddsNoDefaults(t *testing.T) {
	home := t.TempDir()
	launchDefaults(t, home, claudeBypassDefaults)
	hooks, retired := "/h/.relay/claude-hooks.json", "/h/.config/relay/claude-hooks-status.json"
	got := WithoutRelayClaudeSettings(hooks, []string{"--settings", retired, "--settings", hooks, "--continue"}, retired)
	if !reflect.DeepEqual(got, []string{"--continue"}) {
		t.Fatalf("chooser arguments kept Relay settings or gained defaults: %q", got)
	}
}

// A Claude desktop Code session runs in auto mode, and Claude holds
// cross-session messages between sessions whose modes differ, so a Relay
// default may select auto. Unknown modes stay refused.
func TestClaudeLaunchDefaultsAcceptAutoAndRefuseUnknownModes(t *testing.T) {
	home := t.TempDir()
	launchDefaults(t, home, `{"version":1,"permission_mode":"auto"}`)
	got, err := ManagedClaudeLaunchArguments(home, "/h/claude-hooks.json", []string{"--resume", "s"})
	if err != nil || !reflect.DeepEqual(got, []string{"--permission-mode", "auto", "--resume", "s"}) {
		t.Fatalf("auto default not applied: %q %v", got, err)
	}
	for _, mode := range []string{"dontAsk", "manual", "Auto", "auto ", ""} {
		launchDefaults(t, home, `{"version":1,"permission_mode":"`+mode+`"}`)
		if got, err := ManagedClaudeLaunchArguments(home, "/h/claude-hooks.json", nil); err == nil {
			t.Fatalf("mode %q accepted: %q", mode, got)
		}
	}
}
