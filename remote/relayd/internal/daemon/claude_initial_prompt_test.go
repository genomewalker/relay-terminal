package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const initialSession = "initial-session"

func initialRow(kind, text, stop string) map[string]any {
	message := map[string]any{"role": kind, "content": text}
	if stop != "" {
		message["stop_reason"] = stop
	}
	return map[string]any{"type": kind, "sessionId": initialSession, "uuid": "row-id", "parentUuid": "hook-parent", "message": message}
}

func initialTranscript(t *testing.T, rows ...map[string]any) (string, string) {
	t.Helper()
	var body strings.Builder
	for _, row := range rows {
		data, err := json.Marshal(row)
		if err != nil {
			t.Fatal(err)
		}
		body.Write(data)
		body.WriteByte('\n')
	}
	return initialRawTranscript(t, body.String())
}

func initialRawTranscript(t *testing.T, body string) (string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), initialSession+".jsonl")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return path, phClaudeTranscriptRevision(info)
}

func initialProof(path, revision string, args []string) *phClaudeInitialPromptProof {
	return phProveClaudeInitialPrompt(path, initialSession, args, revision, os.Getuid(), true)
}

func TestClaudeInitialPromptIncorporatedResume(t *testing.T) {
	prompt := "Original handoff\nLiteral $(touch /never-execute) and `id`"
	tool := initialRow("user", "", "")
	tool["message"].(map[string]any)["content"] = []any{map[string]any{"type": "tool_result", "tool_use_id": "tool1", "content": "done"}}
	path, revision := initialTranscript(t, initialRow("user", prompt, ""), initialRow("assistant", "tool", "tool_use"), tool, initialRow("assistant", "completed", "end_turn"))
	args := []string{"claude", "--settings", "/private/hooks with spaces.json", "--dangerously-skip-permissions", "--model", "opus", prompt}
	// The old/no-proof API still rejects positional prompts.
	mrRaise(t, "custom Claude launch", func() { phClaudeResumeCommand(args, initialSession, []string{"relayd", "agent", "claude"}, "") })
	proof := initialProof(path, revision, args)
	got := phShlexSplit(phClaudeResumeCommandWithPrompt(args, initialSession, []string{"relayd", "agent", "claude"}, "", proof))
	want := []string{"relayd", "agent", "claude", "--settings", "/private/hooks with spaces.json", "--dangerously-skip-permissions", "--model", "opus", "--resume", initialSession}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume flags/session changed: got %q", got)
	}
	for _, word := range got {
		if word == prompt {
			t.Fatal("initial prompt replayed")
		}
	}
	changed := append([]string(nil), args...)
	changed[len(changed)-1] = "different prompt"
	mrRaise(t, "proof changed", func() {
		phClaudeResumeCommandWithPrompt(changed, initialSession, []string{"relayd", "agent", "claude"}, "", proof)
	})
	mrRaise(t, "proof changed", func() {
		phClaudeResumeCommandWithPrompt(args, "another-session", []string{"relayd", "agent", "claude"}, "", proof)
	})
}

func TestClaudeInitialPromptRefusesAmbiguousEvidence(t *testing.T) {
	goodUser, done := initialRow("user", "prompt", ""), initialRow("assistant", "done", "end_turn")
	cases := map[string][]map[string]any{
		"historical_match_only":         {initialRow("user", "different initial", ""), done, goodUser, done},
		"no_completion":                 {goodUser, initialRow("assistant", "pending", "tool_use")},
		"next_prompt_before_completion": {goodUser, initialRow("user", "later", ""), done},
		"assistant_before_initial":      {done, goodUser, done},
	}
	wrong := initialRow("user", "prompt", "")
	wrong["sessionId"] = "other-session"
	cases["wrong_session"] = []map[string]any{wrong, done}
	side := initialRow("user", "prompt", "")
	side["isSidechain"] = true
	cases["sidechain_only"] = []map[string]any{side, done}
	compact := initialRow("user", "prompt", "")
	compact["isCompactSummary"] = true
	cases["compacted"] = []map[string]any{compact, done}
	meta := initialRow("user", "prompt", "")
	meta["isMeta"] = true
	cases["meta_only"] = []map[string]any{meta, done}
	for name, rows := range cases {
		t.Run(name, func(t *testing.T) {
			path, rev := initialTranscript(t, rows...)
			mrRaise(t, "not verified", func() { initialProof(path, rev, []string{"claude", "prompt"}) })
		})
	}
	t.Run("duplicate_key", func(t *testing.T) {
		path, rev := initialRawTranscript(t, `{"type":"user","sessionId":"wrong","sessionId":"initial-session","message":{"content":"prompt"}}`+"\n")
		mrRaise(t, "not verified", func() { initialProof(path, rev, []string{"claude", "prompt"}) })
	})
}

func TestClaudeInitialPromptPinAndLaunchFences(t *testing.T) {
	path, revision := initialTranscript(t, initialRow("user", "prompt", ""), initialRow("assistant", "done", "end_turn"))
	args := []string{"claude", "prompt"}
	mrRaise(t, "not verified", func() { phProveClaudeInitialPrompt(path, initialSession, args, revision, os.Getuid(), false) })
	mrRaise(t, "not verified", func() { phProveClaudeInitialPrompt(path, initialSession, args, revision, os.Getuid()+1, true) })
	mrRaise(t, "not verified", func() { initialProof(path, "stale-revision", args) })
	for _, selector := range []string{"--resume", "-r", "--continue", "-c", "--session-id", "--fork-session", "--resume=old"} {
		mrRaise(t, "not verified", func() { initialProof(path, revision, []string{"claude", selector, "prompt"}) })
	}
	for _, extra := range []string{"--unknown", "another positional"} {
		argv := []string{"claude", extra, "prompt"}
		proof := initialProof(path, revision, argv)
		mrRaise(t, "custom Claude launch", func() {
			phClaudeResumeCommandWithPrompt(argv, initialSession, []string{"relayd", "agent", "claude"}, "", proof)
		})
	}
	link := filepath.Join(t.TempDir(), initialSession+".jsonl")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if phRaised(t, func() { initialProof(link, revision, args) }) == nil {
		t.Fatal("symlink accepted")
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	mrRaise(t, "not verified", func() { initialProof(path, revision, args) })
}
