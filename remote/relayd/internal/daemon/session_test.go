package daemon

import (
	"testing"
	"time"
)

func TestClassifyAgentProcess(t *testing.T) {
	tests := []struct {
		command   string
		arguments string
		want      string
	}{
		{"codex", "/home/me/.local/bin/codex\x00resume\x00thr_1", "codex"},
		{"node", "/opt/tools/claude --dangerously-skip-permissions", "claude"},
		{"bash", "bash -l", ""},
	}
	for _, test := range tests {
		if got := classifyAgentProcess(test.command, test.arguments); got != test.want {
			t.Fatalf("classifyAgentProcess(%q, %q) = %q, want %q", test.command, test.arguments, got, test.want)
		}
	}
}

func TestExitedSessionIsReplacedOnNextAttach(t *testing.T) {
	first, err := startSession("restart-test", "exit 0", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !first.hasExited() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !first.hasExited() {
		t.Fatal("first session did not exit")
	}

	second, err := startSession("restart-test", "sleep 5", "", 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("exited session was reused")
	}
	_ = second.signal(15)
}
