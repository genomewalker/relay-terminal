package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

// dandy-07 (2026-10-30): six Claude panes ran under ~/.claude-team, whose
// projects directory is Relay's shared-history link to ~/.claude/projects.
// Their bindings name the transcript through the link; resume-plan must
// accept it, keep the team account and still refuse any other link.
func TestSavedPlanResumesATeamAccountThroughTheSharedHistoryLink(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	team := filepath.Join(home, ".claude-team")
	main := filepath.Join(home, ".claude", "projects")
	session := "f849a11d-46d9-456a-9886-b9511ae73e88"
	work := filepath.Join(home, "rice")
	if err := os.MkdirAll(work, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTranscript(t, filepath.Join(main, "-rice", session+".jsonl"),
		`{"type":"user","sessionId":"`+session+`","cwd":"`+work+`"}`+"\n")
	if err := os.MkdirAll(team, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(team, "projects")
	if err := os.Symlink(main, link); err != nil {
		t.Fatal(err)
	}
	server := &Server{stateDir: filepath.Join(t.TempDir(), "workers")}
	pane := "4b3c6f80-bdbb-493c-8c18-089cd64d67b6"
	producer := agentProducer{PaneID: pane, Provider: "claude", ProcessID: 1 << 22, ProcessStart: 1, ConfigDir: team}
	logical := filepath.Join(link, "-rice", session+".jsonl")
	if err := server.storeAgentBinding(map[string]any{"session_id": session, "transcript_path": logical}, producer); err != nil {
		t.Fatalf("team binding through the shared link refused: %v", err)
	}
	plan, err := readSavedConversationPlan(server, pane)
	if err != nil {
		t.Fatalf("resume-plan refused the shared-history transcript: %v", err)
	}
	if plan.SessionID != session || plan.Directory != work || plan.ConfigDir != team || plan.Provider != "claude" {
		t.Fatalf("plan = %+v", plan)
	}
	// The same binding through any other link is still refused.
	other := filepath.Join(home, "elsewhere")
	if err := os.MkdirAll(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, link); err != nil {
		t.Fatal(err)
	}
	writeTranscript(t, filepath.Join(other, "-rice", session+".jsonl"),
		`{"type":"user","sessionId":"`+session+`","cwd":"`+work+`"}`+"\n")
	if _, err := readSavedConversationPlan(server, pane); err == nil {
		t.Fatal("resume-plan followed a link that is not the shared-history link")
	}
}
