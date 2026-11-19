package main

import "testing"

// Codex strips RELAY_SESSION from its MCP servers' environment, so relay-mcp
// also looks for it in its parent processes (Codex, then the pane's shell).
func TestCallerPaneFallsBackToTheNearestAncestorsRelaySession(t *testing.T) {
	pane := "44444444-4444-4444-8444-444444444444"
	parents := map[int]int{100: 90, 90: 80, 80: 1}
	envs := map[int]string{90: "PATH=/bin\x00HOME=/h", 80: "RELAY_SESSION=" + pane + "\x00TERM=xterm"}
	parent := func(pid int) int { return parents[pid] }
	env := func(pid int) ([]byte, bool) { e, ok := envs[pid]; return []byte(e), ok }
	if got := callerPaneFromAncestors(100, parent, env); got != pane {
		t.Fatalf("got %q", got)
	}
	envs[90] = "RELAY_SESSION=not-a-pane"
	if got := callerPaneFromAncestors(100, parent, env); got != "" {
		t.Fatalf("an invalid nearer value must not be skipped over: %q", got)
	}
	delete(envs, 90)
	delete(envs, 80)
	if got := callerPaneFromAncestors(100, parent, env); got != "" {
		t.Fatalf("no pane: %q", got)
	}
	loop := map[int]int{100: 100}
	if got := callerPaneFromAncestors(100, func(p int) int { return loop[p] }, env); got != "" {
		t.Fatalf("a parent loop ends: %q", got)
	}
}
