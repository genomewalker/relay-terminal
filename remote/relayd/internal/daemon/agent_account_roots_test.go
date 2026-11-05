package daemon

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestAccountRootsHelperProcess(t *testing.T) {
	if os.Getenv("RELAY_ACCOUNT_ROOTS_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(60 * time.Second)
}

// startAccountAgent starts this test binary with an exact environment as a
// stand-in agent process; cleanup stops only that exact child.
func startAccountAgent(t *testing.T, environment ...string) int {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestAccountRootsHelperProcess$")
	command.Env = append([]string{"RELAY_ACCOUNT_ROOTS_HELPER=1"}, environment...)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})
	pid := command.Process.Pid
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if vars, err := agentlaunch.ProcessEnvironment(pid, "RELAY_ACCOUNT_ROOTS_HELPER"); err == nil && vars["RELAY_ACCOUNT_ROOTS_HELPER"] == "1" {
			return pid
		}
	}
	t.Fatal("helper environment never became readable")
	return 0
}

func writeTranscript(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestAccountTranscriptStaysInsideTheProducersAccount(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	personalPath := filepath.Join(personal, "projects", "p", "1e292b09-1f1c-49eb-9b3a-85844d9b8cd7.jsonl")
	defaultPath := filepath.Join(home, ".claude", "projects", "p", "1e292b09-1f1c-49eb-9b3a-85844d9b8cd7.jsonl")
	writeTranscript(t, personalPath, "{}\n")
	writeTranscript(t, defaultPath, "{}\n")
	if err := validateBindingTranscript(personalPath, "claude"); err == nil {
		t.Fatal("the legacy provider check unexpectedly accepts a personal directory")
	}
	if err := validateAccountTranscript(personalPath, "claude", personal); err != nil {
		t.Fatalf("personal Claude transcript refused: %v", err)
	}
	if err := validateAccountTranscript(defaultPath, "claude", personal); err == nil {
		t.Fatal("a transcript outside the producer's account was accepted")
	}
	if err := validateAccountTranscript(defaultPath, "claude", ""); err != nil {
		t.Fatalf("default account transcript refused: %v", err)
	}
	codexHome := filepath.Join(home, ".codex-personal")
	rollout := filepath.Join(codexHome, "sessions", "2026", "10", "17", "rollout-x-019a0000-0000-7000-8000-000000000000.jsonl")
	writeTranscript(t, rollout, "{}\n")
	if err := validateAccountTranscript(rollout, "codex", codexHome); err != nil {
		t.Fatalf("personal Codex rollout refused: %v", err)
	}
	if err := validateAccountTranscript(filepath.Join(codexHome, "elsewhere.jsonl"), "codex", codexHome); err == nil {
		t.Fatal("a Codex file outside sessions was accepted")
	}
}

func TestBindingSourcePathUsesTheRecordedAccount(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	path := filepath.Join(personal, "projects", "p", "s.jsonl")
	writeTranscript(t, path, "{}\n")
	binding := AgentBindingRecord{Producer: agentProducer{Provider: "claude", ConfigDir: personal}, TranscriptPath: path}
	if _, err := bindingSourcePath(binding, "claude"); err != nil {
		t.Fatalf("rotation source in the personal account refused: %v", err)
	}
	binding.Producer.ConfigDir = ""
	if _, err := bindingSourcePath(binding, "claude"); err == nil {
		t.Fatal("a default-account binding accepted a personal transcript")
	}
}

func TestAgentConfigRootFollowsTheAgentProcessEnvironment(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	pid := startAccountAgent(t, "HOME="+home, "CLAUDE_CONFIG_DIR="+personal)
	if override, err := agentConfigOverride(pid, "claude"); err != nil || override != personal {
		t.Fatalf("override = %q %v", override, err)
	}
	if root, err := agentConfigRoot(pid, "claude"); err != nil || root != personal {
		t.Fatalf("root = %q %v", root, err)
	}
	codexHome := filepath.Join(home, ".codex-personal")
	codex := startAccountAgent(t, "HOME="+home, "CODEX_HOME="+codexHome)
	if override := processAccountOverride(codex, "codex"); override != codexHome {
		t.Fatalf("Codex override = %q", override)
	}
	rollout := filepath.Join(codexHome, "sessions", "2026", "10", "17", "rollout-a.jsonl")
	writeTranscript(t, rollout, "{}\n")
	if _, err := processSourcePath(codex, rollout, "codex"); err != nil {
		t.Fatalf("open Codex rollout in personal account refused: %v", err)
	}
	defaultAgent := startAccountAgent(t, "HOME="+home)
	if override, err := agentConfigOverride(defaultAgent, "claude"); err != nil || override != "" {
		t.Fatalf("default override = %q %v", override, err)
	}
	relative := startAccountAgent(t, "HOME="+home, "CLAUDE_CONFIG_DIR=relative")
	if _, err := agentConfigOverride(relative, "claude"); err == nil {
		t.Fatal("a relative account directory was accepted")
	}
}

func TestPersonalClaudeBindingRecordsItsAccountAndPlansItsResume(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	session := "1e292b09-1f1c-49eb-9b3a-85844d9b8cd7"
	work := t.TempDir()
	transcript := filepath.Join(personal, "projects", "p", session+".jsonl")
	writeTranscript(t, transcript, `{"type":"user","sessionId":"`+session+`","cwd":"`+work+`"}`+"\n")
	server := &Server{stateDir: filepath.Join(t.TempDir(), "workers")}
	pane := "account-pane"
	// An exited producer: a saved conversation can only be resumed then.
	producer := agentProducer{PaneID: pane, Provider: "claude", ProcessID: 1 << 22, ProcessStart: 1, ConfigDir: personal}
	if err := server.storeAgentBinding(map[string]any{"session_id": session, "transcript_path": transcript}, producer); err != nil {
		t.Fatalf("personal binding refused: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(server.stateDir, "agent-bindings", pane+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var record AgentBindingRecord
	if err := json.Unmarshal(data, &record); err != nil || record.Producer.ConfigDir != personal {
		t.Fatalf("binding lacks its account: %s %v", data, err)
	}
	plan, err := readSavedConversationPlan(server, pane)
	if err != nil || plan.ConfigDir != personal || plan.SessionID != session || plan.Directory != work {
		t.Fatalf("resume plan = %+v %v", plan, err)
	}
	// A default-account producer cannot bind the personal transcript.
	producer.ConfigDir = ""
	if err := server.storeAgentBinding(map[string]any{"session_id": session, "transcript_path": transcript}, producer); err == nil {
		t.Fatal("a default producer bound a personal transcript")
	}
}

func TestNativeClaudeTranscriptUsesTheFrontendsAccount(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".claude-personal")
	session := "1e292b09-1f1c-49eb-9b3a-85844d9b8cd7"
	path := filepath.Join(personal, "projects", "p", session+".jsonl")
	writeTranscript(t, path, "{}\n")
	writeTranscript(t, filepath.Join(home, ".claude", "projects", "p", session+".jsonl"), "{}\n")
	found, err := nativeClaudeTranscript(personal, session)
	if err != nil || found != path {
		t.Fatalf("personal transcript = %q %v", found, err)
	}
	if !strings.HasPrefix(found, personal) {
		t.Fatal("transcript resolved outside the frontend's account")
	}
}
