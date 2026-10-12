//go:build darwin || linux

package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestDirectoryPublicationNeverReplacesCollision(t *testing.T) {
	for _, kind := range []string{"empty-directory", "directory", "file", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			stageRoot, destinationRoot := t.TempDir(), t.TempDir()
			if err := os.Chmod(stageRoot, 0700); err != nil {
				t.Fatal(err)
			}
			stage := filepath.Join(stageRoot, "complete")
			if err := os.Mkdir(stage, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(stage, "bytes"), []byte("complete"), 0600); err != nil {
				t.Fatal(err)
			}
			destination := filepath.Join(destinationRoot, "taken")
			switch kind {
			case "empty-directory", "directory":
				if err := os.Mkdir(destination, 0700); err != nil {
					t.Fatal(err)
				}
				if kind == "directory" {
					if err := os.WriteFile(filepath.Join(destination, "old"), []byte("original"), 0600); err != nil {
						t.Fatal(err)
					}
				}
			case "file":
				if err := os.WriteFile(destination, []byte("original"), 0600); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Symlink(stage, destination); err != nil {
					t.Fatal(err)
				}
			}
			before, err := os.Lstat(destination)
			if err != nil {
				t.Fatal(err)
			}
			from, err := os.Open(stageRoot)
			if err != nil {
				t.Fatal(err)
			}
			defer from.Close()
			to, err := os.Open(destinationRoot)
			if err != nil {
				t.Fatal(err)
			}
			defer to.Close()
			if err := publishDirectoryNoReplace(int(from.Fd()), "complete", int(to.Fd()), "taken"); !errors.Is(err, syscall.EEXIST) && !errors.Is(err, syscall.ENOTEMPTY) {
				t.Fatalf("collision must reach the no-replace primitive: %v", err)
			}
			after, err := os.Lstat(destination)
			if err != nil || !os.SameFile(before, after) {
				t.Fatal("collision inode changed")
			}
			if _, err := os.Stat(filepath.Join(stage, "bytes")); err != nil {
				t.Fatal("failed publication consumed stage")
			}
		})
	}
}

func TestDirectoryPublicationPublishesCompleteTree(t *testing.T) {
	stageRoot, targetRoot := t.TempDir(), t.TempDir()
	if err := os.Chmod(stageRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(stageRoot, "complete"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stageRoot, "complete", "bytes"), []byte("complete"), 0600); err != nil {
		t.Fatal(err)
	}
	from, err := os.Open(stageRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer from.Close()
	to, err := os.Open(targetRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer to.Close()
	if err := publishDirectoryNoReplace(int(from.Fd()), "complete", int(to.Fd()), "published"); err != nil {
		t.Fatal(err)
	}
	bytes, err := os.ReadFile(filepath.Join(targetRoot, "published", "bytes"))
	if err != nil || string(bytes) != "complete" {
		t.Fatal("wrong published bytes")
	}
	if _, err := os.Stat(filepath.Join(stageRoot, "complete")); !os.IsNotExist(err) {
		t.Fatal("publication left original name")
	}
}

func TestDirectoryPublicationUsesPinnedParents(t *testing.T) {
	base := t.TempDir()
	stageRoot, targetRoot := filepath.Join(base, "private"), filepath.Join(base, "destination")
	for _, path := range []string{stageRoot, targetRoot, filepath.Join(stageRoot, "complete")} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(stageRoot, "complete", "bytes"), []byte("complete"), 0600); err != nil {
		t.Fatal(err)
	}
	from, err := os.Open(stageRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer from.Close()
	to, err := os.Open(targetRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer to.Close()
	// Path replacement cannot redirect a publication through already pinned FDs.
	moved := filepath.Join(base, "moved")
	if err := os.Rename(targetRoot, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(targetRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := publishDirectoryNoReplace(int(from.Fd()), "complete", int(to.Fd()), "published"); err != nil {
		t.Fatal(err)
	}
	bytes, err := os.ReadFile(filepath.Join(moved, "published", "bytes"))
	if err != nil || string(bytes) != "complete" {
		t.Fatal("wrong published bytes")
	}
	if _, err := os.Stat(filepath.Join(targetRoot, "published")); !os.IsNotExist(err) {
		t.Fatal("pathname redirected publication")
	}
}

func TestDirectoryPublicationRejectsUnsafeStage(t *testing.T) {
	stageRoot, targetRoot := t.TempDir(), t.TempDir()
	if err := os.Chmod(stageRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(stageRoot, "complete"), 0700); err != nil {
		t.Fatal(err)
	}
	from, err := os.Open(stageRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer from.Close()
	to, err := os.Open(targetRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer to.Close()
	for _, name := range []string{"..", "../escape", "/absolute", "bad\x00name"} {
		if err := publishDirectoryNoReplace(int(from.Fd()), "complete", int(to.Fd()), name); err == nil {
			t.Fatal("unsafe child accepted")
		}
	}
	if err := os.Chmod(stageRoot, 0770); err != nil {
		t.Fatal(err)
	}
	if err := publishDirectoryNoReplace(int(from.Fd()), "complete", int(to.Fd()), "published"); err == nil {
		t.Fatal("shared stage accepted")
	}
}
