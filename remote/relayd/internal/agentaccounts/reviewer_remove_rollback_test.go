package agentaccounts

import (
	"bufio"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReviewerRemovalRollbackRefusesRecreatedAccountRoot(t *testing.T) {
	home, registry, root := removeFixture(t)
	if err := os.WriteFile(filepath.Join(root, "original-data"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	originalName, originalInUse := agentProcessName, inUse
	t.Cleanup(func() { agentProcessName = originalName; inUse = originalInUse })
	self := filepath.Base(os.Args[0])
	agentProcessName = func(name string) bool { return strings.HasPrefix(self, name) || strings.HasPrefix(name, self) }
	calls := 0
	var child *exec.Cmd
	var input io.WriteCloser
	inUse = func(provider string, roots ...string) (string, error) {
		calls++
		if calls == 3 {
			// A provider starting on the old root normally creates its config state.
			if err := os.MkdirAll(root, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "new-agent-state"), []byte("new"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		pids, err := agentsUsing(provider, roots...)
		if calls == 2 {
			// Start after the pre-move scan found no agent, before Rename.
			child = exec.Command(os.Args[0], "-test.run=^TestReviewerAccountRaceHelper$")
			child.Env = []string{"REVIEWER_REMOVE_RACE_HELPER=1", "HOME=" + home, "CLAUDE_CONFIG_DIR=" + root}
			out, e := child.StdoutPipe()
			if e != nil {
				t.Fatal(e)
			}
			input, e = child.StdinPipe()
			if e != nil {
				t.Fatal(e)
			}
			if e = child.Start(); e != nil {
				t.Fatal(e)
			}
			t.Cleanup(func() { _ = input.Close(); _ = child.Process.Kill(); _ = child.Wait() })
			if line, e := bufio.NewReader(out).ReadString('\n'); e != nil || line != "ready\n" {
				t.Fatal("helper readiness failed")
			}
			visible, e := agentsUsing(provider, root)
			if e != nil || visible == "" {
				t.Fatalf("fixture helper not visible: %v", e)
			}
		}
		return pids, err
	}
	logoutRunner = func(context.Context, string, string) error { return nil }
	_, _, err := Remove(home, registry, "claude", "personal", time.Now())
	if err == nil {
		t.Fatal("fixture did not refuse active removal")
	}
	if _, e := os.Stat(filepath.Join(root, "original-data")); e != nil {
		t.Error("refused removal left the original account archived and its registered root replaced by new agent state")
	}
	loaded, e := Load(home)
	if e != nil {
		t.Fatal(e)
	}
	if _, ok := loaded.Find("claude", "personal"); !ok {
		t.Error("refused removal forgot slot")
	}
	t.Logf("remove result: %v", err)
}
