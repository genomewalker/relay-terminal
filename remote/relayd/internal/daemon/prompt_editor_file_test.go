package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPromptEditorFileExactReplacement(t *testing.T) {
	for _, replacement := range []string{"漢字  exact 🧬\nHard   newline", ""} {
		t.Run(replacement, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "draft")
			original := "Original  double   triple 🧬\nSecond  line"
			if err := os.WriteFile(path, []byte(original), 0o600); err != nil {
				t.Fatal(err)
			}
			capture, err := openPromptEditorFile(path)
			if err != nil {
				t.Fatal(err)
			}
			defer capture.file.Close()
			checks := 0
			if err := capture.apply([]byte(replacement), func() error { checks++; return nil }); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil || string(data) != replacement || checks != 2 {
				t.Fatal("exact replacement or ownership checks failed")
			}
		})
	}
}

func TestPromptEditorFileRefusesChangedVersion(t *testing.T) {
	for _, change := range []string{"contents", "inode"} {
		t.Run(change, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "draft")
			if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			capture, err := openPromptEditorFile(path)
			if err != nil {
				t.Fatal(err)
			}
			defer capture.file.Close()
			if change == "inode" {
				if err := os.Rename(path, filepath.Join(root, "captured")); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(path, []byte("changed"), 0o600); err != nil {
				t.Fatal(err)
			}
			if capture.apply([]byte("replacement"), func() error { return nil }) == nil {
				t.Fatal("changed version edited")
			}
			data, _ := os.ReadFile(path)
			if string(data) != "changed" {
				t.Fatal("changed file overwritten")
			}
			if change == "inode" {
				data, _ := os.ReadFile(filepath.Join(root, "captured"))
				if string(data) != "original" {
					t.Fatal("captured file altered")
				}
			}
		})
	}
}

func TestPromptEditorFileOwnerChangeRetainsOriginal(t *testing.T) {
	for _, phase := range []int{1, 2} {
		t.Run(string(rune('0'+phase)), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "draft")
			if err := os.WriteFile(path, []byte("original  🧬\nhard line"), 0o600); err != nil {
				t.Fatal(err)
			}
			capture, err := openPromptEditorFile(path)
			if err != nil {
				t.Fatal(err)
			}
			defer capture.file.Close()
			checks := 0
			err = capture.apply([]byte("replacement"), func() error {
				checks++
				if checks == phase {
					return errors.New("owner changed")
				}
				return nil
			})
			data, _ := os.ReadFile(path)
			if err == nil || string(data) != "original  🧬\nhard line" {
				t.Fatal("owner change lost original")
			}
		})
	}
}

func TestPromptEditorFileRejectsSymlinkAndPublicPermissions(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "draft")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if capture, err := openPromptEditorFile(link); err == nil {
		capture.file.Close()
		t.Fatal("symlink accepted")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if capture, err := openPromptEditorFile(path); err == nil {
		capture.file.Close()
		t.Fatal("public file accepted")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o644 {
		t.Fatal("permissions changed on rejection")
	}
}

func TestPromptEditorFilePrivatizesOnlyAfterVerifiedOwner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "provider-draft")
	if err := os.WriteFile(path, []byte("Exact  provider 🧬\nDraft"), 0o644); err != nil {
		t.Fatal(err)
	}
	if capture, err := openPromptEditorFileForOwner(path, func() error { return errors.New("owner changed") }); err == nil {
		capture.file.Close()
		t.Fatal("changed owner admitted")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o644 {
		t.Fatal("failed owner check changed permissions")
	}
	checks := 0
	capture, err := openPromptEditorFileForOwner(path, func() error { checks++; return nil })
	if err != nil {
		t.Fatal(err)
	}
	defer capture.file.Close()
	info, _ = os.Stat(path)
	if checks != 1 || info.Mode().Perm() != 0o600 || string(capture.original) != "Exact  provider 🧬\nDraft" {
		t.Fatal("authorized intake lost exact data or privacy")
	}
}
