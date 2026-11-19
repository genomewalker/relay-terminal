package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSavedConversationOpenElsewhere(t *testing.T) {
	root := t.TempDir()
	server := &Server{stateDir: filepath.Join(root, "workers"), runtimeDir: filepath.Join(root, "runtime")}
	directory := filepath.Join(server.stateDir, "agent-bindings")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	session := "f5c58da2-334a-4730-9bc4-732e12f6f43e"
	source, live, dead := "cc583d26-69ae-416c-8984-656f2dbe640e", "07fa914c-6df8-45db-9757-3078bd97d2d2", "4ca4ff69-0000-4000-8000-000000000001"
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	write := func(pane string, pid int, processStart uint64) {
		binding := AgentBindingRecord{Version: 1, SessionID: session}
		binding.Producer.PaneID, binding.Producer.Provider = pane, "claude"
		binding.Producer.ProcessID, binding.Producer.ProcessStart = pid, processStart
		data, _ := json.Marshal(binding)
		if err := os.WriteFile(filepath.Join(directory, pane+".json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	// The source pane itself and a pane whose provider has ended never block.
	write(source, os.Getpid(), start)
	write(dead, 2147483647, 1)
	if pane, err := savedConversationOpenElsewhere(server, session, source); err != nil || pane != "" {
		t.Fatalf("pane=%q err=%v, want no live duplicate", pane, err)
	}
	// A reused pid with a different start is not the same process.
	write(live, os.Getpid(), start+1)
	if pane, _ := savedConversationOpenElsewhere(server, session, source); pane != "" {
		t.Fatalf("pane=%q, a reused pid must not block", pane)
	}
	write(live, os.Getpid(), start)
	if pane, err := savedConversationOpenElsewhere(server, session, source); err != nil || pane != live {
		t.Fatalf("pane=%q err=%v, want %s", pane, err, live)
	}
	if pane, _ := savedConversationOpenElsewhere(server, "11111111-1111-4111-8111-111111111111", source); pane != "" {
		t.Fatalf("another conversation blocked: %q", pane)
	}
	if _, err := savedConversationOpenElsewhere(server, "../x", source); err == nil {
		t.Fatal("accepted an invalid conversation identity")
	}
}
