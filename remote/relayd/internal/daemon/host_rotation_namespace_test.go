package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCodexConfiguredSourceNamespace(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_HOME", root)
	directory := filepath.Join(root, "sessions", "2026")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "rollout.jsonl")
	if err := os.WriteFile(path, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := rotationSourcePath(path, "codex"); err != nil || got != path {
		t.Fatalf("trusted CODEX_HOME unavailable: %q %v", got, err)
	}
	if err := validateBindingTranscript(path, "codex"); err != nil {
		t.Fatal("binding lost explicitly configured namespace", err)
	}
	outside := filepath.Join(t.TempDir(), ".codex", "sessions", "outside.jsonl")
	if err := os.MkdirAll(filepath.Dir(outside), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outside, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := rotationSourcePath(outside, "codex"); err == nil {
		t.Fatal("path marker bypassed configured root")
	}
	if err := validateBindingTranscript(outside, "codex"); err == nil {
		t.Fatal("binding path marker bypassed configured root")
	}
	for name, mutation := range map[string]func(string) error{
		"symlink":  func(p string) error { return os.Symlink(path, p) },
		"hardlink": func(p string) error { return os.Link(path, p) },
		"group_writable": func(p string) error {
			if err := os.WriteFile(p, []byte("{}\n"), 0600); err != nil {
				return err
			}
			return os.Chmod(p, 0660)
		},
	} {
		t.Run(name, func(t *testing.T) {
			p := filepath.Join(directory, name+".jsonl")
			if err := mutation(p); err != nil {
				t.Fatal(err)
			}
			defer os.Remove(p)
			if _, err := rotationSourcePath(p, "codex"); err == nil {
				t.Fatal("unsafe configured source accepted")
			}
		})
	}
	for _, rootValue := range []string{"relative", "/private/tmp/../tmp"} {
		t.Run("invalid_root_"+rootValue, func(t *testing.T) {
			t.Setenv("CODEX_HOME", rootValue)
			if _, err := rotationSourcePath(path, "codex"); err == nil {
				t.Fatal("invalid configured root accepted")
			}
			if err := validateBindingTranscript(path, "codex"); err == nil {
				t.Fatal("invalid binding namespace accepted")
			}
		})
	}
	wrong := filepath.Join(root, "arbitrary.jsonl")
	if err := os.WriteFile(wrong, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := rotationSourcePath(wrong, "codex"); err == nil {
		t.Fatal("non-session source accepted")
	}
}
