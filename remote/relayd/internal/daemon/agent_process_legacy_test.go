package daemon

import (
	"encoding/json"
	"os"
	"testing"
)

func TestCapturedLegacyJournalRebuildsWithoutPhantomRoots(t *testing.T) {
	data, err := os.ReadFile("testdata/agent-process-legacy-exit.json")
	if err != nil {
		t.Fatal(err)
	}
	var events []json.RawMessage
	if err := json.Unmarshal(data, &events); err != nil {
		t.Fatal(err)
	}
	session := &Session{}
	for _, event := range events {
		session.updateActiveSubagents(event)
	}
	if len(events) != 130 || len(session.activeAgentRoots) != 0 {
		t.Fatalf("captured ended sessions retained phantom roots: events=%d roots=%d", len(events), len(session.activeAgentRoots))
	}
}

func processLifecyclePayload(root, source, name string, sequence uint64) []byte {
	payload, _ := json.Marshal(map[string]any{
		"agent": "claude", "relay_event_seq": sequence,
		"event": map[string]any{"root_id": root, "source": source, "hook_event_name": name},
	})
	return payload
}

func TestLegacyProcessExitRepairsPriorObservedRoots(t *testing.T) {
	session := &Session{}
	session.updateActiveSubagents(processLifecyclePayload("claude:206865:956839242", "process-tree", "SessionStart", 1543))
	session.updateActiveSubagents(processLifecyclePayload("claude:99:other", "process-tree", "SessionStart", 1540))
	session.updateActiveSubagents(processLifecyclePayload("claude:206865:hook", "hook", "SessionStart", 1541))
	session.updateActiveSubagents(processLifecyclePayload("claude:206865:unavailable", "process-tree", "SessionEnd", 1544))
	if session.activeAgentRoots["claude:206865:956839242"] != nil || len(session.activeAgentRoots) != 2 {
		t.Fatalf("legacy exit failed to repair only its prior process roots: %v", session.activeAgentRoots)
	}
}

func TestHistoricalProcessExitCannotRetireNewerSnapshotRoot(t *testing.T) {
	session := &Session{}
	session.updateActiveSubagents(processLifecyclePayload("claude:77:new", "process-tree", "SessionStart", 20))
	session.updateActiveSubagents(processLifecyclePayload("claude:77:unavailable", "process-tree", "SessionEnd", 10))
	session.updateActiveSubagents(processLifecyclePayload("claude:77:new", "process-tree", "SessionEnd", 11))
	if session.activeAgentRoots["claude:77:new"] == nil {
		t.Fatal("historical end retired a newer snapshot incarnation")
	}
	session.updateActiveSubagents(processLifecyclePayload("claude:77:new", "process-tree", "SessionEnd", 21))
	if len(session.activeAgentRoots) != 0 {
		t.Fatal("current matching exit did not retire its process")
	}
}
