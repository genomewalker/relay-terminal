package daemon

import "testing"

func TestHarnessEntrypointClassification(t *testing.T) {
	tests := []struct{ command, arguments, want string }{
		{"claude", "claude\x00--resume\x00id", "claude"},
		{"2.1.301", "claude\x00--resume\x00id", "claude"},
		{"2.1.301", "claude --resume id", "claude"},
		{"2.1.301", "sleep\x00claude", ""},
		{"2.1.301", "echo claude", ""},
		{"2.1.301", "codex\x00resume", ""},
		{"2.1.301-helper", "claude\x00--resume", ""},
		{"2..301", "claude\x00", ""},
		{"2.+1.301", "claude\x00", ""},
		{"2.1.301", "", ""},
		{"codex", "codex\x00resume\x00id", "codex"},
		{"opencode", "opencode\x00", "opencode"},
		{"gemini", "gemini\x00", "gemini"},
		{"node", "node\x00/home/me/node_modules/@anthropic-ai/claude-code/cli.js\x00--resume\x00id", "claude"},
		{"node", "node\x00/home/me/node_modules/@openai/codex/bin/codex.js\x00resume", "codex"},
		{"node", "node\x00/home/me/node_modules/@google/gemini-cli/dist/index.js", "gemini"},
		{"python3.13", "python3\x00-m\x00aider\x00--model\x00x", "aider"},
		{"python3", "python3\x00/bin/aider", "aider"},
		{"bash", "bash\x00-c\x00echo /opt/bin/codex", ""},
		{"echo", "echo\x00/opt/bin/claude", ""},
		{"sleep", "codex\x00100", ""},
		{"node", "node\x00-e\x00require('/opt/bin/claude')", ""},
		{"node", "node\x00/tmp/ordinary.js\x00/opt/bin/codex", ""},
		{"node", "node\x00--require\x00/opt/bin/codex\x00/tmp/ordinary.js", ""},
		{"node", "node\x00--require\x00/tmp/setup.js\x00/home/me/node_modules/@google/gemini-cli/dist/index.js", "gemini"},
		{"python3", "python3\x00/tmp/analysis.py\x00aider", ""},
		{"codex-peer-work", "codex-peer-worker\x00", ""},
	}
	for _, test := range tests {
		if got := classifyAgentProcess(test.command, test.arguments); got != test.want {
			t.Errorf("%q %q: got %q, want %q", test.command, test.arguments, got, test.want)
		}
	}
}

func TestOuterHarnessDoesNotBecomeItsSubagent(t *testing.T) {
	candidates := map[int]HarnessProcess{20: {Provider: "claude", PID: 20, Start: "kernel:1"},
		30: {Provider: "codex", PID: 30, Start: "kernel:2"}, 40: {Provider: "gemini", PID: 40, Start: "kernel:3"}}
	roots := outerHarnessProcesses(candidates, map[int][]int{20: {20, 10}, 30: {30, 20, 10}, 40: {40, 10}})
	if len(roots) != 2 || roots[0].PID != 20 || roots[0].Provider != "claude" || roots[1].PID != 40 {
		t.Fatalf("unexpected foreground harness roots: %#v", roots)
	}
}

func TestPaneHarnessesRejectInvalidScope(t *testing.T) {
	for _, panes := range [][]string{nil, {"../foreign-pane"}, make([]string, 129)} {
		if _, err := ReadPaneHarnesses(panes); err == nil {
			t.Fatalf("accepted invalid panes: %v", panes)
		}
	}
}
