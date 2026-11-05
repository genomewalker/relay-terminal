package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReviewNativeClaudeMustPreserveExplicitDefault(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	explicit := filepath.Join(home, ".claude")
	if got := accountOverride("claude", explicit); got != explicit {
		t.Fatalf("native Claude binding lost explicit CLAUDE_CONFIG_DIR: got %q, want explicit directory", got)
	}
}

func TestReviewSharedHistoryMustRemainBindable(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			home, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			t.Setenv("HOME", home)
			subtree := "projects"
			if provider == "codex" {
				subtree = "sessions"
			}
			main := filepath.Join(home, "."+provider, subtree)
			personal := filepath.Join(home, "."+provider+"-personal")
			relative := filepath.Join("p", "11111111-1111-4111-8111-111111111111.jsonl")
			writeTranscript(t, filepath.Join(main, relative), "{}\n")
			if err := os.MkdirAll(personal, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(main, filepath.Join(personal, subtree)); err != nil {
				t.Fatal(err)
			}
			for _, candidate := range []string{
				filepath.Join(personal, subtree, relative),
				filepath.Join(main, relative),
			} {
				if err := validateAccountTranscript(candidate, provider, personal); err != nil {
					t.Errorf("account with the exact shared-history link cannot bind transcript: %v", err)
				}
			}
		})
	}
}
