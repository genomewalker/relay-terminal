package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPromptBootstrapRecordDoesNotCreateConversationBinding(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	pane := "owned-pane"
	directory := filepath.Join(server.stateDir, "prompt-owners")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	record := promptBootstrapOwner{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "claude", ProcessID: 12, ProcessStart: 102, SenderPID: 13},
		SessionID: "owned-session", NodeBootID: "boot", WorkerPID: 10, WorkerStart: 100, ShellPID: 11, ShellStart: 101, ObservedAt: time.Now().UTC(), Revision: "private-epoch"}
	if err := writeBindingRecord(directory, pane, record); err != nil {
		t.Fatal(err)
	}
	observed, err := server.readPromptBootstrapOwner(pane)
	if err != nil || observed != record {
		t.Fatalf("input-only record changed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(server.stateDir, "agent-bindings", pane+".json")); !os.IsNotExist(err) {
		t.Fatal("input owner fabricated conversation binding")
	}
	if _, err := server.readVerifiedPromptBootstrapOwner(pane); err == nil {
		t.Fatal("input record without kernel worker accepted")
	}
}

func TestPromptBootstrapRecordRejectsWrongPaneAndPublicFile(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	pane := "owned-pane"
	directory := filepath.Join(server.stateDir, "prompt-owners")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	record := promptBootstrapOwner{Version: 1, Producer: agentProducer{PaneID: "other-pane", Provider: "claude", ProcessID: 12, ProcessStart: 102, SenderPID: 13},
		SessionID: "owned-session", NodeBootID: "boot", WorkerPID: 10, WorkerStart: 100, ShellPID: 11, ShellStart: 101, ObservedAt: time.Now().UTC(), Revision: "epoch"}
	if err := writeBindingRecord(directory, pane, record); err != nil {
		t.Fatal(err)
	}
	if _, err := server.readPromptBootstrapOwner(pane); err == nil {
		t.Fatal("wrong pane accepted")
	}
	record.Producer.PaneID = pane
	if err := writeBindingRecord(directory, pane, record); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, pane+".json")
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := server.readPromptBootstrapOwner(pane); err == nil {
		t.Fatal("public bootstrap record accepted")
	}
}

func TestPromptBootstrapRejectsLateConversationEventFromEarlierSession(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	pane := "owned-pane"
	directory := filepath.Join(server.stateDir, "prompt-owners")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	producer := agentProducer{PaneID: pane, Provider: "claude", ProcessID: 12, ProcessStart: 102, SenderPID: 13}
	record := promptBootstrapOwner{Version: 1, Producer: producer, SessionID: "current-session", NodeBootID: "boot", WorkerPID: 10, WorkerStart: 100,
		ShellPID: 11, ShellStart: 101, ObservedAt: time.Now().UTC(), Revision: "epoch"}
	if err := writeBindingRecord(directory, pane, record); err != nil {
		t.Fatal(err)
	}
	transcripts := filepath.Join(t.TempDir(), ".claude", "projects")
	if err := os.MkdirAll(transcripts, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(transcripts, "earlier-session.jsonl")
	if err := os.WriteFile(path, []byte("owned fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if server.storeAgentBinding(map[string]any{"session_id": "earlier-session", "transcript_path": path}, producer) == nil {
		t.Fatal("late older-session event replaced current owner")
	}
}
