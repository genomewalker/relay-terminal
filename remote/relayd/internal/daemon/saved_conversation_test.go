package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSavedConversationPlan(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			root := t.TempDir()
			server := &Server{stateDir: filepath.Join(root, "workers"), runtimeDir: filepath.Join(root, "runtime")}
			pane, session := "70665c50-9cca-441d-a03c-1f11aff57d32", "c500790e-1e1a-4d15-a613-df83c1bdca1d"
			directory := filepath.Join(server.stateDir, "agent-bindings")
			if err := os.MkdirAll(directory, 0700); err != nil {
				t.Fatal(err)
			}
			transcript := filepath.Join(root, "."+provider, "projects", "test", session+".jsonl")
			if err := os.MkdirAll(filepath.Dir(transcript), 0700); err != nil {
				t.Fatal(err)
			}
			var line []byte
			if provider == "claude" {
				line, _ = json.Marshal(map[string]any{"sessionId": session, "cwd": root})
			} else {
				line, _ = json.Marshal(map[string]any{"type": "session_meta", "payload": map[string]any{"id": session, "cwd": root}})
			}
			if err := os.WriteFile(transcript, line, 0600); err != nil {
				t.Fatal(err)
			}
			binding := AgentBindingRecord{Version: 1, SessionID: session, TranscriptPath: transcript}
			binding.Producer.PaneID, binding.Producer.Provider = pane, provider
			binding.Producer.ProcessID, binding.Producer.ProcessStart = 2147483647, 1
			path := filepath.Join(directory, pane+".json")
			write := func() {
				data, _ := json.Marshal(binding)
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			write()
			plan, err := readSavedConversationPlan(server, pane)
			if err != nil || plan.SessionID != session || plan.Provider != provider || plan.Directory != root || len(plan.BindingSHA) != 64 {
				t.Fatalf("plan=%+v error=%v", plan, err)
			}
			binding.SessionID = "11111111-1111-4111-8111-111111111111"
			write()
			if _, err := readSavedConversationPlan(server, pane); err == nil {
				t.Fatal("accepted transcript from a different session")
			}
			binding.SessionID = session
			binding.Producer.ProcessID = os.Getpid()
			start, err := processStartTime(os.Getpid())
			if err != nil {
				t.Fatal(err)
			}
			binding.Producer.ProcessStart = start
			write()
			if _, err := readSavedConversationPlan(server, pane); err == nil {
				t.Fatal("accepted a live saved provider process")
			}
		})
	}
}
