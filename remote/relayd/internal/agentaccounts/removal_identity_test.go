package agentaccounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// identityFixture journals a removal the way Remove does now: with the
// account folder's identity, after unregistering the slot.
func identityFixture(t *testing.T) (string, string, removal) {
	t.Helper()
	home, registry, root := removeFixture(t)
	writeFile(t, filepath.Join(root, "original-data"), "original")
	account, _ := registry.Find("claude", "personal")
	dev, inode, ok := folderIdentity(root)
	if !ok {
		t.Fatal("fixture account folder has no identity")
	}
	job := removal{ID: "0123456789abcdef", Account: account, Index: 1, Root: root,
		Staged:      filepath.Join(filepath.Dir(root), ".claude-personal.removing-0123456789abcdef"),
		Destination: filepath.Join(home, "retired", "claude-personal"), Dev: dev, Inode: inode}
	if err := writeRemoval(home, job); err != nil {
		t.Fatal(err)
	}
	kept := Registry{Version: registryVersion}
	for _, a := range registry.Accounts {
		if a.Provider != "claude" || a.Label != "personal" {
			kept.Accounts = append(kept.Accounts, a)
		}
	}
	if _, err := Save(home, kept); err != nil {
		t.Fatal(err)
	}
	return home, root, job
}

// The current-format counterpart of the reviewer's unfilled staging
// reservation: the fallback died after Mkdir(staged), before or after
// journaling the placeholder, and before the folder moved.
func TestRecoveryRecognisesAnUnfilledStagingReservationByIdentity(t *testing.T) {
	for _, journaled := range []bool{false, true} {
		home, root, job := identityFixture(t)
		if err := os.Mkdir(job.Staged, 0700); err != nil {
			t.Fatal(err)
		}
		if journaled {
			dev, inode, _ := folderIdentity(job.Staged)
			job.Reserved = &reservation{Path: job.Staged, Dev: dev, Inode: inode}
			if err := writeRemoval(home, job); err != nil {
				t.Fatal(err)
			}
		}
		notes := RecoverRemovals(home)
		if !present(filepath.Join(root, "original-data")) || !registered(t, home) || pendingCount(t, home) != 0 {
			t.Fatalf("journaled=%v: the account was not restored: %v", journaled, notes)
		}
		if present(job.Staged) {
			t.Errorf("journaled=%v: the empty placeholder was left behind", journaled)
		}
		for _, note := range notes {
			if strings.Contains(note, "is kept at "+job.Staged) {
				t.Errorf("journaled=%v: recovery points to an empty placeholder as the account: %q", journaled, note)
			}
		}
	}
}

// With identity recorded, an original staged folder (empty or not) is
// never taken for a placeholder when root was recreated.
func TestRecoveryKeepsAStagedOriginalBesideARecreatedRoot(t *testing.T) {
	home, root, job := identityFixture(t)
	if err := os.Remove(filepath.Join(root, "original-data")); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(root, job.Staged); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "replacement-data"), "new provider state")
	notes := RecoverRemovals(home)
	if dev, inode, ok := folderIdentity(job.Staged); !ok || dev != job.Dev || inode != job.Inode {
		t.Fatalf("the staged original was removed: %v", notes)
	}
	if registered(t, home) {
		t.Error("the recreated root was registered as the account")
	}
	if string(mustRead(t, filepath.Join(root, "replacement-data"))) != "new provider state" {
		t.Error("the recreated root was changed")
	}
}

// A record without identity naming two existing folders is held: nothing
// is removed, moved or registered, and the journal stays.
func TestLegacyRecordWithTwoFoldersIsHeld(t *testing.T) {
	home, root, job := identityFixture(t)
	job.Dev, job.Inode = 0, 0
	if err := writeRemoval(home, job); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(job.Staged, 0700); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		notes := RecoverRemovals(home)
		if !present(job.Staged) || !present(filepath.Join(root, "original-data")) || registered(t, home) || pendingCount(t, home) != 1 {
			t.Fatalf("a legacy two-folder record was acted on: %v", notes)
		}
		if len(notes) != 1 || !strings.Contains(notes[0], "on hold") || strings.Contains(notes[0], "is kept at") {
			t.Fatalf("hold note: %v", notes)
		}
	}
}

func TestRmdirNeverRemovesAFileOrAFullFolder(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	full := filepath.Join(dir, "full")
	writeFile(t, file, "x")
	writeFile(t, filepath.Join(full, "x"), "x")
	if syscallRmdir(file) == nil || syscallRmdir(full) == nil || !present(file) || !present(full) {
		t.Fatal("rmdir removed a file or a non-empty folder")
	}
	if err := syscallRmdir(filepath.Join(dir, "missing")); err == nil {
		t.Fatal("rmdir of a missing path succeeded")
	}
}
