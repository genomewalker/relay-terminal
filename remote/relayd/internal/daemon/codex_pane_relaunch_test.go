package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// codexRelaunchFixture is a temp account holding one saved root session, a
// temp home with the managed launcher, and a trusted git project directory.
func codexRelaunchFixture(t *testing.T) (home, config, cwd, session string) {
	t.Helper()
	root := t.TempDir()
	home, config, cwd = filepath.Join(root, "home"), filepath.Join(root, "home", ".codex-work"), filepath.Join(root, "project")
	session = "01a18b32-f284-7220-91a2-6a81cde6db14"
	for _, dir := range []string{filepath.Join(config, "sessions", "2026", "11", "18"), filepath.Join(home, ".local", "share", "relay", "shims"), filepath.Join(cwd, ".git")} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	meta := `{"type":"session_meta","payload":{"id":"` + session + `","cwd":"` + cwd + `","source":"cli"}}` + "\n"
	if err := os.WriteFile(filepath.Join(config, "sessions", "2026", "11", "18", "rollout-x-"+session+".jsonl"), []byte(meta), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.toml"), []byte("[projects.\""+cwd+"\"]\ntrust_level = \"trusted\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".local", "share", "relay", "shims", "codex"), []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return
}

func refusalCode(err error) string {
	var refusal *PaneRefusal
	if errors.As(err, &refusal) {
		return refusal.Code
	}
	return ""
}

// The relaunch an exit relies on is proven before the exit: the exact saved
// session in its account and recorded directory, through the managed launcher.
func TestCodexRelaunchCommandIsProvenBeforeExit(t *testing.T) {
	home, config, cwd, session := codexRelaunchFixture(t)
	gotCwd, command, err := codexRelaunchCommand(home, config, session)
	shim := filepath.Join(home, ".local", "share", "relay", "shims", "codex")
	if err != nil || gotCwd != cwd || command != "cd -- "+shellQuote(cwd)+" && CODEX_HOME="+shellQuote(config)+" "+shellQuote(shim)+" resume "+shellQuote(session) {
		t.Fatalf("command %q %q %v", gotCwd, command, err)
	}
	// The session's own model and effort survive the relaunch, whatever the
	// account default says (bc08e46f, 2026-11-21: astra/low came back as sol/medium).
	path := filepath.Join(config, "sessions", "2026", "11", "18", "rollout-x-"+session+".jsonl")
	rollout, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rollout = append(rollout, []byte("\n"+`{"type":"turn_context","payload":{"model":"gpt-6.2-sol","effort":"medium"}}`+"\n"+
		`{"type":"turn_context","payload":{"model":"gpt-6.2-astra","effort":"low"}}`+"\n")...)
	if err := os.WriteFile(path, rollout, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.toml"), []byte("model = \"gpt-6.2-sol\"\n[projects.\""+cwd+"\"]\ntrust_level = \"trusted\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, command, err = codexRelaunchCommand(home, config, session)
	if err != nil || command != "cd -- "+shellQuote(cwd)+" && CODEX_HOME="+shellQuote(config)+" "+shellQuote(shim)+" resume -m "+shellQuote("gpt-6.2-astra")+" -c "+shellQuote("model_reasoning_effort=low")+" "+shellQuote(session) {
		t.Fatalf("model not carried: %q %v", command, err)
	}
	if _, _, err := codexRelaunchCommand(home, config, "01a18b32-f284-7220-91a2-6a81cde6db15"); refusalCode(err) != PaneRefusalResumeUnavailable {
		t.Fatalf("missing session: %v", err)
	}
	// Case 10: a non-git folder trusted only through its parent is refused.
	if err := os.RemoveAll(filepath.Join(cwd, ".git")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.toml"), []byte("[projects.\""+filepath.Dir(cwd)+"\"]\ntrust_level = \"trusted\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := codexRelaunchCommand(home, config, session); refusalCode(err) != PaneRefusalTrustPrompt || !strings.Contains(err.Error(), cwd) {
		t.Fatalf("trust: %v", err)
	}
	if err := os.WriteFile(filepath.Join(config, "config.toml"), []byte("[projects.\""+cwd+"\"]\ntrust_level = \"trusted\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(shim); err != nil {
		t.Fatal(err)
	}
	if _, _, err := codexRelaunchCommand(home, config, session); refusalCode(err) != PaneRefusalLauncherUnavailable {
		t.Fatalf("launcher: %v", err)
	}
}

// Case 3 (7db531e6): a managed-backend pane is exited only when its managed
// route is intact, as maintenance's restart requires.
func TestCodexManagedRouteIsCheckedBeforeExit(t *testing.T) {
	state := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	pane := "7db531e6-0000-4000-8000-000000000001"
	if refusal := codexManagedRouteRefusal(pane); refusal != nil {
		t.Fatalf("a pane without the managed backend was refused: %+v", refusal)
	}
	path := filepath.Join(state, "relay/workers/codex-proxies", pane, "descriptor.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{`{`, `{"pane":"other","frontend_socket":"/s"}`, `{"pane":"` + pane + `","frontend_socket":"relative"}`} {
		if err := os.WriteFile(path, []byte(bad), 0o600); err != nil {
			t.Fatal(err)
		}
		if refusal := codexManagedRouteRefusal(pane); refusal == nil || refusal.Code != PaneRefusalRelaunchUnavailable {
			t.Fatalf("%s: %+v", bad, refusal)
		}
	}
	if err := os.WriteFile(path, []byte(`{"pane":"`+pane+`","frontend_socket":"/run/frontend.sock"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if refusal := codexManagedRouteRefusal(pane); refusal != nil {
		t.Fatalf("intact route refused: %+v", refusal)
	}
}

func TestCodexRelaunchPlanRefusesInvalidSelectorsBeforeInspection(t *testing.T) {
	for _, args := range [][3]string{{"../pane", "01a18b32-f284-7220-91a2-6a81cde6db14", "/a"},
		{"7db531e6-0000-4000-8000-000000000001", "x/y", "/a"},
		{"7db531e6-0000-4000-8000-000000000001", "01a18b32-f284-7220-91a2-6a81cde6db14", "relative"},
		{"7db531e6-0000-4000-8000-000000000001", "01a18b32-f284-7220-91a2-6a81cde6db14", "/a/../b"}} {
		if _, err := ReadCodexPaneRelaunchPlan(args[0], args[1], args[2]); refusalCode(err) != PaneRefusalInvalidRequest {
			t.Fatalf("%v: %v", args, err)
		}
	}
}
