package daemon

import (
	"errors"
	"testing"
)

func publishAgentTransitions(session *Session, changes []agentProcessTransition) {
	for _, change := range changes {
		session.publishDetectedAgent(change.process.agent, change.event, change.pid, change.process.startIdentity)
	}
}

func TestDetectedAgentProcessExitKeepsIncarnation(t *testing.T) {
	known := make(map[int]detectedAgentProcess)
	started := observedAgentProcesses(map[int]string{206865: "claude"}, known, func(int) (string, error) {
		return "956839242", nil
	})
	session := &Session{}
	publishAgentTransitions(session, agentProcessTransitions(known, started))
	if _, exists := session.activeAgentRoots["claude:206865:956839242"]; !exists {
		t.Fatal("native start did not publish the captured incarnation")
	}
	ended := observedAgentProcesses(map[int]string{}, started, func(int) (string, error) {
		t.Fatal("exit attempted to reread a vanished process")
		return "", errors.New("process exited")
	})
	publishAgentTransitions(session, agentProcessTransitions(started, ended))
	if len(session.activeAgentRoots) != 0 {
		t.Fatalf("exited process left phantom roots: %v", session.activeAgentRoots)
	}
}

func TestDetectedAgentProcessPIDReuseEndsOldBeforeStartingNew(t *testing.T) {
	old := map[int]detectedAgentProcess{77: {agent: "claude", startIdentity: "old"}}
	current := observedAgentProcesses(map[int]string{77: "claude"}, old, func(int) (string, error) {
		return "new", nil
	})
	changes := agentProcessTransitions(old, current)
	if len(changes) != 2 || changes[0].event != "SessionEnd" || changes[0].process.startIdentity != "old" ||
		changes[1].event != "SessionStart" || changes[1].process.startIdentity != "new" {
		t.Fatalf("incorrect PID-reuse lifecycle: %+v", changes)
	}
	session := &Session{}
	session.publishDetectedAgent("claude", "SessionStart", 77, "old")
	publishAgentTransitions(session, changes)
	if len(session.activeAgentRoots) != 1 || session.activeAgentRoots["claude:77:new"] == nil {
		t.Fatalf("PID reuse retained the wrong incarnation: %v", session.activeAgentRoots)
	}
}

func TestObservedAgentProcessIdentityFailureDoesNotInventLifecycle(t *testing.T) {
	known := map[int]detectedAgentProcess{77: {agent: "claude", startIdentity: "original"}}
	current := observedAgentProcesses(map[int]string{77: "claude", 88: "codex"}, known, func(int) (string, error) {
		return "", errors.New("temporarily unreadable")
	})
	if current[77] != known[77] || len(current) != 1 || len(agentProcessTransitions(known, current)) != 0 {
		t.Fatalf("unverified sample invented a start or an exit: %v", current)
	}
}
