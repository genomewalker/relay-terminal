package daemon

import (
	"errors"
	"testing"
)

// The argv of a process that must not be read is a failure if it is.
func unreadArgv(t *testing.T) func() (string, error) {
	return func() (string, error) {
		t.Helper()
		t.Error("arguments read for a process that must not be read")
		return "", nil
	}
}

func TestAncestorClaudeFromArgv(t *testing.T) {
	claudeCLI := "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume"
	for _, tc := range []struct {
		name    string
		command string
		argv    func() (string, error)
		want    bool
		wantErr bool
	}{
		{"native claude command", "claude", unreadArgv(t), true, false},
		{"node running claude cli.js", "node", func() (string, error) { return claudeCLI, nil }, true, false},
		{"node running another program", "node", func() (string, error) { return "node /srv/app/server.js", nil }, false, false},
		{"node with unreadable argv is refused", "node", func() (string, error) { return "", errors.New("procargs denied") }, false, true},
		{"sh wrapper is skipped without reading argv", "sh", unreadArgv(t), false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ancestorClaudeFromArgv(tc.command, tc.argv)
			if (err != nil) != tc.wantErr || got != tc.want {
				t.Fatalf("ancestorClaudeFromArgv(%q) = %v, %v; want %v, error %v", tc.command, got, err, tc.want, tc.wantErr)
			}
		})
	}
}

// An interpreter ancestor whose argv is unreadable stops the walk: a desktop
// Claude further up the chain is not attributed in its place.
func TestClaudeSessionWalkRefusesUnreadableInterpreterAncestor(t *testing.T) {
	previous := claudeAncestorIsClaude
	defer func() { claudeAncestorIsClaude = previous }()
	claudeAncestorIsClaude = func(pid int) (bool, error) {
		if pid == 50 {
			return false, errors.New("interpreter arguments unreadable")
		}
		return pid == 60, nil
	}
	if actor, err := readClaudeSessionActorFrom([]int{50, 60}, 10, "start"); err == nil {
		t.Fatalf("walk continued past an unreadable ancestor: %+v", actor)
	}
}
