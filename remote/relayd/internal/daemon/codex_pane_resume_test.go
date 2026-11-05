package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCodexPaneResumeExactSavedSession(t *testing.T) {
	root := t.TempDir()
	id := "01a18b32-f284-7220-91a2-6a81cde6db14"
	dir := filepath.Join(root, "sessions", "2026", "10", "30")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "rollout-date-"+id+".jsonl")
	if err := os.WriteFile(path, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := exactCodexResumeTranscript(root, id); err != nil || got != path {
		t.Fatalf("exact: %q %v", got, err)
	}
	if _, err := exactCodexResumeTranscript(root, "../"+id); err == nil {
		t.Fatal("accepted traversal")
	}
	if _, err := exactCodexResumeTranscript(root, "01a18b32-f284-7220-91a2-6a81cde6db15"); err == nil {
		t.Fatal("substituted another saved session")
	}
	if err := os.WriteFile(filepath.Join(dir, "duplicate-"+id+".jsonl"), []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := exactCodexResumeTranscript(root, id); err == nil {
		t.Fatal("accepted ambiguous saved session")
	}
}

func TestCodexPaneResumeRejectsInvalidIdentitiesBeforeInspection(t *testing.T) {
	if _, err := ReadCodexPaneResumePlan("pane", "session", "target"); err == nil {
		t.Fatal("accepted invalid IDs")
	}
}
