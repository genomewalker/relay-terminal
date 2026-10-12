package daemon

import (
	"testing"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestCodexRotationPlanBindsCapturedFlagsSocketAndFreshRoot(t *testing.T) {
	fresh := []string{"--model", "gpt-6-sol", "--sandbox", "workspace-write"}
	thread := "12345678-1234-4234-8234-123456789abc"
	socket := agentlaunch.CodexSocket{Path: "/home/user/.codex/app-server-control/app-server-control.sock"}
	valid := append(append([]string{}, fresh...), "resume", "--remote",
		"unix:///home/user/.codex/app-server-control/app-server-control.sock", thread)
	if err := validateCodexRotationArgs(fresh, valid, thread, socket); err != nil {
		t.Fatal(err)
	}
	for name, changed := range map[string][]string{
		"flags":  {"--model", "gpt-6-astra", "--sandbox", "workspace-write", "resume", "--remote", valid[6], thread},
		"socket": {"--model", "gpt-6-sol", "--sandbox", "workspace-write", "resume", "--remote", "unix:///tmp/other.sock", thread},
		"root":   {"--model", "gpt-6-sol", "--sandbox", "workspace-write", "resume", "--remote", valid[6], "87654321-1234-4234-8234-123456789abc"},
		"extra":  append(append([]string{}, valid...), "--dangerously-bypass-approvals-and-sandbox"),
	} {
		if err := validateCodexRotationArgs(fresh, changed, thread, socket); err == nil {
			t.Errorf("%s changed the launch plan without rejection", name)
		}
	}
	if err := validateCodexRotationArgs(fresh, valid, "not-a-thread", socket); err == nil {
		t.Fatal("invalid app-server root accepted")
	}
}
