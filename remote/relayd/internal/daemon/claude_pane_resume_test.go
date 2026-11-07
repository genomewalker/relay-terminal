package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudePaneResumeCommandKeepsTheExactAccountSelection(t *testing.T) {
	const id = "01a18b32-f284-7220-91a2-6a81cde6db14"
	unset, err := claudePaneResumeCommand("/work/my project", "", "/h/.local/share/relay/shims/claude", id)
	if err != nil || unset != "cd -- '/work/my project' && env -u CLAUDE_CONFIG_DIR '/h/.local/share/relay/shims/claude' --resume '"+id+"'" {
		t.Fatalf("default account: %q %v", unset, err)
	}
	set, err := claudePaneResumeCommand("/work", "/h/.claude-max", "/h/shim", id)
	if err != nil || set != "cd -- '/work' && CLAUDE_CONFIG_DIR='/h/.claude-max' '/h/shim' --resume '"+id+"'" {
		t.Fatalf("explicit account: %q %v", set, err)
	}
	quoted, err := claudePaneResumeCommand("/w'x", "/h/a'b", "/h/shim", id)
	if err != nil || !strings.Contains(quoted, `'/w'\''x'`) || !strings.Contains(quoted, `CLAUDE_CONFIG_DIR='/h/a'\''b'`) {
		t.Fatalf("quoting: %q %v", quoted, err)
	}
	for _, bad := range [][4]string{
		{"relative", "", "/h/shim", id},
		{"/w", "relative", "/h/shim", id},
		{"/w", "/h/../x", "/h/shim", id},
		{"/w", "", "shim", id},
		{"/w", "", "/h/shim", "latest"},
		{"/w", "", "/h/shim", id + "; rm -rf /"},
	} {
		if command, err := claudePaneResumeCommand(bad[0], bad[1], bad[2], bad[3]); err == nil {
			t.Fatalf("accepted %v: %q", bad, command)
		}
	}
}

func TestClaudePaneResumeDirectoryIsTheExactSessionsRecordedProject(t *testing.T) {
	const id = "01a18b32-f284-7220-91a2-6a81cde6db14"
	write := func(lines ...string) *os.File {
		path := filepath.Join(t.TempDir(), id+".jsonl")
		if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { file.Close() })
		return file
	}
	got, err := claudeTranscriptDirectory(write(`{"type":"file-history-snapshot"}`, `not json`,
		`{"sessionId":"01a18b32-f284-7220-91a2-6a81cde6db15","cwd":"/other"}`,
		`{"sessionId":"`+id+`","cwd":"/work/project"}`), id)
	if err != nil || got != "/work/project" {
		t.Fatalf("directory: %q %v", got, err)
	}
	if _, err := claudeTranscriptDirectory(write(`{"sessionId":"`+id+`","cwd":"relative"}`), id); err == nil {
		t.Fatal("accepted a relative directory")
	}
	if _, err := claudeTranscriptDirectory(write(`{"sessionId":"`+id+`","cwd":"/work/../etc"}`), id); err == nil {
		t.Fatal("accepted an unclean directory")
	}
	if _, err := claudeTranscriptDirectory(write(`{"sessionId":"01a18b32-f284-7220-91a2-6a81cde6db15","cwd":"/other"}`), id); err == nil {
		t.Fatal("took another session's directory")
	}
}

func TestClaudePaneResumeRejectsInvalidIdentitiesBeforeInspection(t *testing.T) {
	for _, args := range [][2]string{{"pane/..", "01a18b32-f284-7220-91a2-6a81cde6db14"}, {"11111111-1111-4111-8111-111111111111", "latest"},
		{"11111111-1111-4111-8111-111111111111", "../01a18b32-f284-7220-91a2-6a81cde6db14"}} {
		if _, err := ReadClaudePaneResumePlan(args[0], args[1]); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}
