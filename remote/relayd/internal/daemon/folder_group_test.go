package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestFolderGroupRestartBindingAndPrivateStatus(t *testing.T) {
	base := t.TempDir()
	state, destination := filepath.Join(base, "state"), filepath.Join(base, "destination")
	if err := os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	g, err := lockFolderGroup(state, "folder-proof")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockFolderGroup(state, "folder-proof"); err == nil {
		t.Fatal("parallel group lock accepted")
	}
	source := strings.Repeat("a", 64)
	if err := g.begin("pane-proof", source, destination, "original-name", []folderEntry{}); err != nil {
		g.Close()
		t.Fatal(err)
	}
	nonce, identity := g.record.Reservation.Nonce, g.record.Reservation.Identity
	status, err := json.Marshal(g.status())
	if err != nil || strings.Contains(string(status), nonce) || strings.Contains(string(status), "nonce") || strings.Contains(string(status), "stage") {
		t.Fatal("private journal leaked through status")
	}
	if err := g.Close(); err != nil {
		t.Fatal(err)
	}
	g, err = lockFolderGroup(state, "folder-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.begin("pane-proof", source, destination, "original-name", []folderEntry{}); err != nil {
		t.Fatal(err)
	}
	if g.record.Reservation.Nonce != nonce || g.record.Reservation.Identity != identity {
		t.Fatal("restart changed reservation")
	}
	reservedPath := filepath.Join(destination, "original-name")
	if err := os.Rename(reservedPath, reservedPath+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(reservedPath, 0700); err != nil {
		t.Fatal(err)
	}
	if err := g.begin("pane-proof", source, destination, "original-name", nil); err == nil {
		t.Fatal("replaced reservation accepted")
	}
	if err := os.Remove(reservedPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(reservedPath+"-moved", reservedPath); err != nil {
		t.Fatal(err)
	}
	if err := g.begin("pane-proof", strings.Repeat("b", 64), destination, "original-name", []folderEntry{}); err == nil {
		t.Fatal("changed source accepted")
	}
	if err := g.cancel(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(destination, "original-name")); err != nil {
		t.Fatal("cancel removed real folder")
	}
	g.record.State = "receiving"
	if err := g.save(); err == nil {
		t.Fatal("terminal group resurrected")
	}
}

func TestFolderGroupCancelBeforeBegin(t *testing.T) {
	state := filepath.Join(t.TempDir(), "state")
	g, err := lockFolderGroup(state, "cancel-proof")
	if err != nil {
		t.Fatal(err)
	}
	if err := g.cancel(); err != nil {
		g.Close()
		t.Fatal(err)
	}
	g.Close()
	g, err = lockFolderGroup(state, "cancel-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	parent := t.TempDir()
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "must-not-create", nil); err == nil {
		t.Fatal("cancelled ID accepted late begin")
	}
	if _, err := os.Lstat(filepath.Join(parent, "must-not-create")); !os.IsNotExist(err) {
		t.Fatal("cancelled ID created destination")
	}
}

func TestFolderGroupCommitRequiresExactTreeAndRecovers(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(base, "state")
	g, err := lockFolderGroup(state, "commit-proof")
	if err != nil {
		t.Fatal(err)
	}
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "empty-tree", nil); err != nil {
		g.Close()
		t.Fatal(err)
	}
	unexpected := filepath.Join(parent, "empty-tree", "unexpected")
	if err := os.WriteFile(unexpected, []byte("unrelated"), 0600); err != nil {
		g.Close()
		t.Fatal(err)
	}
	if err := g.commit(); err == nil {
		g.Close()
		t.Fatal("unexpected file committed")
	}
	if g.record.State != "committing" {
		g.Close()
		t.Fatal("commit intent not durable")
	}
	if err := g.cancel(); err == nil {
		g.Close()
		t.Fatal("pending commit cancelled")
	}
	g.Close()
	g, err = lockFolderGroup(state, "commit-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := os.Remove(unexpected); err != nil {
		t.Fatal(err)
	}
	if err := g.commit(); err != nil {
		t.Fatal(err)
	}
	if err := g.commit(); err != nil {
		t.Fatal("repeat commit failed", err)
	}
	if err := g.cancel(); err != nil {
		t.Fatal(err)
	}
	if g.status().State != "committed" {
		t.Fatal("committed receipt lost")
	}
	if _, err := os.Stat(filepath.Join(parent, "empty-tree")); err != nil {
		t.Fatal("committed directory removed")
	}
}

func TestFolderGroupCollisionAndChangedPreparedParent(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(parent, "existing")
	if err := os.WriteFile(existing, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	g, err := lockFolderGroup(filepath.Join(base, "state"), "collision-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "existing", nil); err == nil {
		t.Fatal("collision accepted")
	}
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "another", nil); err == nil {
		t.Fatal("collision retried under another name")
	}
	raw, err := os.ReadFile(existing)
	if err != nil || string(raw) != "original" {
		t.Fatal("original collision changed")
	}
	info, err := os.Stat(parent)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(parent, parent+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	_, err = reserveFolder(filepath.Join(g.root, "reservations"), "parent-proof", parent, "must-not-create", strings.Repeat("a", 64), uploadIdentity(info))
	if err == nil {
		t.Fatal("changed prepared parent accepted")
	}
	if _, err := os.Lstat(filepath.Join(parent, "must-not-create")); !os.IsNotExist(err) {
		t.Fatal("changed parent received directory")
	}
}

func TestFolderGroupMaterializesEmptyDirectoriesAcrossRestart(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(base, "state")
	g, err := lockFolderGroup(state, "directories-proof")
	if err != nil {
		t.Fatal(err)
	}
	entries := []folderEntry{{Path: "nested/empty", Kind: "directory"}, {Path: "nested", Kind: "directory"}, {Path: "root-empty", Kind: "directory"}, {Path: "nested/" + folderOwnerMarker, Kind: "directory"}}
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", entries); err != nil {
		g.Close()
		t.Fatal(err)
	}
	if err := g.commit(); err == nil {
		g.Close()
		t.Fatal("missing directories committed")
	}
	if err := g.materializeDirectories(); err != nil {
		g.Close()
		t.Fatal(err)
	}
	identities := make(map[string]string)
	for relative, identity := range g.record.Directories {
		identities[relative] = identity
	}
	g.Close()
	g, err = lockFolderGroup(state, "directories-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.materializeDirectories(); err != nil {
		t.Fatal(err)
	}
	for relative, identity := range identities {
		if g.record.Directories[relative] != identity {
			t.Fatal("directory recreated on resume")
		}
		info, err := os.Stat(filepath.Join(parent, "tree", relative))
		if err != nil || !info.IsDir() || uploadIdentity(info) != identity {
			t.Fatal("directory receipt differs")
		}
	}
	if err := g.commit(); err != nil {
		t.Fatal(err)
	}
}

func TestFolderGroupUnknownDirectoryIntentNeverAdoptsOrRecreates(t *testing.T) {
	for _, exists := range []bool{false, true} {
		t.Run(map[bool]string{false: "missing", true: "existing"}[exists], func(t *testing.T) {
			base := t.TempDir()
			parent := filepath.Join(base, "parent")
			if err := os.Mkdir(parent, 0700); err != nil {
				t.Fatal(err)
			}
			state := filepath.Join(base, "state")
			g, err := lockFolderGroup(state, "unknown-proof")
			if err != nil {
				t.Fatal(err)
			}
			if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", []folderEntry{{Path: "child", Kind: "directory"}}); err != nil {
				g.Close()
				t.Fatal(err)
			}
			g.record.DirectoryIntents = map[string]string{"child": g.record.Reservation.Identity}
			if err := g.save(); err != nil {
				g.Close()
				t.Fatal(err)
			}
			child := filepath.Join(parent, "tree", "child")
			if exists {
				if err := os.Mkdir(child, 0700); err != nil {
					g.Close()
					t.Fatal(err)
				}
			}
			g.Close()
			g, err = lockFolderGroup(state, "unknown-proof")
			if err != nil {
				t.Fatal(err)
			}
			defer g.Close()
			if err := g.materializeDirectories(); err == nil {
				t.Fatal("unknown directory accepted")
			}
			if g.record.Directories["child"] != "" {
				t.Fatal("unknown directory adopted")
			}
			if _, err := os.Stat(child); !exists && !os.IsNotExist(err) {
				t.Fatal("unknown directory recreated")
			}
		})
	}
}

func TestFolderGroupDirectoryCollisionPreserved(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	g, err := lockFolderGroup(filepath.Join(base, "state"), "child-collision-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", []folderEntry{{Path: "child", Kind: "directory"}}); err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(parent, "tree", "child")
	if err := os.WriteFile(child, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := g.materializeDirectories(); err == nil {
		t.Fatal("directory collision accepted")
	}
	raw, err := os.ReadFile(child)
	if err != nil || string(raw) != "original" {
		t.Fatal("directory collision changed original")
	}
	if err := g.materializeDirectories(); err == nil {
		t.Fatal("failed mkdir intent replayed")
	}
}

func TestFolderGroupStagingSiblingRestartAndIdentity(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(base, "state")
	g, err := lockFolderGroup(state, "staging-proof")
	if err != nil {
		t.Fatal(err)
	}
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", nil); err != nil {
		g.Close()
		t.Fatal(err)
	}
	stage, err := g.openStagingDirectory()
	if err != nil {
		g.Close()
		t.Fatal(err)
	}
	stageInfo, err := stage.Stat()
	stage.Close()
	if err != nil {
		g.Close()
		t.Fatal(err)
	}
	parentInfo, err := os.Stat(parent)
	if err != nil {
		g.Close()
		t.Fatal(err)
	}
	if stageInfo.Sys().(*syscall.Stat_t).Dev != parentInfo.Sys().(*syscall.Stat_t).Dev || stageInfo.Mode().Perm() != 0700 {
		g.Close()
		t.Fatal("staging not private on destination filesystem")
	}
	identity, nonce := g.record.Staging.Identity, g.record.Staging.Nonce
	wire, err := json.Marshal(g.status())
	if err != nil || strings.Contains(string(wire), nonce) {
		g.Close()
		t.Fatal("staging nonce leaked")
	}
	g.Close()
	g, err = lockFolderGroup(state, "staging-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	stage, err = g.openStagingDirectory()
	if err != nil {
		t.Fatal(err)
	}
	stage.Close()
	if g.record.Staging.Identity != identity || g.record.Staging.Nonce != nonce {
		t.Fatal("staging identity changed after restart")
	}
	stagePath := filepath.Join(parent, g.record.Staging.Name)
	if err := os.Rename(stagePath, stagePath+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(stagePath, 0700); err != nil {
		t.Fatal(err)
	}
	if stage, err = g.openStagingDirectory(); err == nil {
		stage.Close()
		t.Fatal("replacement staging accepted")
	}
	if err := os.Remove(stagePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(stagePath+"-moved", stagePath); err != nil {
		t.Fatal(err)
	}
	if err := g.commit(); err != nil {
		t.Fatal("sibling staging contaminated manifest", err)
	}
}

func TestFolderGroupStagingCollisionNeverRenames(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	g, err := lockFolderGroup(filepath.Join(base, "state"), "staging-collision-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", nil); err != nil {
		t.Fatal(err)
	}
	collision := filepath.Join(parent, folderStagingName(g.record.ID))
	if err := os.WriteFile(collision, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if stage, err := g.openStagingDirectory(); err == nil {
			stage.Close()
			t.Fatal("staging collision accepted")
		}
	}
	raw, err := os.ReadFile(collision)
	if err != nil || string(raw) != "original" {
		t.Fatal("staging collision changed original")
	}
	names, err := os.ReadDir(parent)
	if err != nil || len(names) != 2 {
		t.Fatal("staging collision created another name")
	}
}

func TestFolderGroupChildRestartTailReplayAndWholeTreeCommit(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(base, "state")
	data := []byte("durable\x00folder child bytes")
	sum, empty := sha256.Sum256(data), sha256.Sum256(nil)
	entries := []folderEntry{{Path: "nested", Kind: "directory"}, {Path: "nested/exact.bin", Kind: "file", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}, {Path: "zero", Kind: "file", SHA256: hex.EncodeToString(empty[:])}, {Path: "empty", Kind: "directory"}}
	g, err := lockFolderGroup(state, "child-proof")
	if err != nil {
		t.Fatal(err)
	}
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", entries); err != nil {
		g.Close()
		t.Fatal(err)
	}
	if err := g.materializeDirectories(); err != nil {
		g.Close()
		t.Fatal(err)
	}
	if err := g.childChunk("nested/exact.bin", 0, data[:7]); err != nil {
		g.Close()
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(parent, "tree", "nested", "exact.bin")); !os.IsNotExist(err) {
		g.Close()
		t.Fatal("partial file published")
	}
	stagePath := filepath.Join(parent, g.record.Staging.Name, g.record.Uploads["nested/exact.bin"].Stage)
	f, err := os.OpenFile(stagePath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		g.Close()
		t.Fatal(err)
	}
	if _, err = f.Write([]byte("uncheckpointed tail")); err != nil {
		f.Close()
		g.Close()
		t.Fatal(err)
	}
	f.Sync()
	f.Close()
	g.Close()
	g, err = lockFolderGroup(state, "child-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.childChunk("nested/exact.bin", 0, data[:7]); err != nil {
		t.Fatal("durable replay failed", err)
	}
	info, err := os.Stat(stagePath)
	if err != nil || info.Size() != 7 {
		t.Fatal("uncheckpointed tail retained")
	}
	if err := g.childChunk("nested/exact.bin", 0, []byte("changed")); err == nil {
		t.Fatal("changed replay accepted")
	}
	if err := g.childChunk("nested/exact.bin", 7, data[7:]); err != nil {
		t.Fatal(err)
	}
	if err := g.childChunk("nested/exact.bin", 0, data); err != nil {
		t.Fatal("full durable replay rejected", err)
	}
	if err := g.commitChild("nested/exact.bin"); err != nil {
		t.Fatal(err)
	}
	if err := g.commitChild("nested/exact.bin"); err != nil {
		t.Fatal("repeat file publication failed", err)
	}
	if err := g.childChunk("nested/exact.bin", 0, data); err == nil {
		t.Fatal("committed file accepted chunk")
	}
	if err := g.commitChild("zero"); err != nil {
		t.Fatal("empty file publication failed", err)
	}
	if err := g.commit(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(parent, "tree", "nested", "exact.bin"))
	if err != nil || !bytes.Equal(raw, data) {
		t.Fatal("published child bytes differ")
	}
	if g.status().CommittedFiles != 2 {
		t.Fatal("file receipts missing")
	}
}

func TestFolderGroupChildPublicationCollisionAndUnknownRecovery(t *testing.T) {
	for _, collision := range []bool{false, true} {
		t.Run(map[bool]string{false: "published-before-receipt", true: "collision"}[collision], func(t *testing.T) {
			base := t.TempDir()
			parent := filepath.Join(base, "parent")
			if err := os.Mkdir(parent, 0700); err != nil {
				t.Fatal(err)
			}
			state := filepath.Join(base, "state")
			data := []byte("complete bytes")
			sum := sha256.Sum256(data)
			entry := folderEntry{Path: "exact.txt", Kind: "file", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}
			g, err := lockFolderGroup(state, "publication-proof")
			if err != nil {
				t.Fatal(err)
			}
			if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", []folderEntry{entry}); err != nil {
				g.Close()
				t.Fatal(err)
			}
			if err := g.childChunk(entry.Path, 0, data); err != nil {
				g.Close()
				t.Fatal(err)
			}
			destination := filepath.Join(parent, "tree", entry.Path)
			if collision {
				if err := os.WriteFile(destination, []byte("original"), 0600); err != nil {
					g.Close()
					t.Fatal(err)
				}
				if err := g.commitChild(entry.Path); err == nil {
					g.Close()
					t.Fatal("file collision accepted")
				}
			} else {
				upload := g.record.Uploads[entry.Path]
				g.record.Files[entry.Path] = folderFileReceipt{Path: entry.Path, Stage: upload.Stage, StageIdentity: upload.Identity, ParentIdentity: g.record.Reservation.Identity, Size: entry.Size, SHA256: entry.SHA256, State: "publishing"}
				if err := g.save(); err != nil {
					g.Close()
					t.Fatal(err)
				}
				if err := os.Link(filepath.Join(parent, g.record.Staging.Name, upload.Stage), destination); err != nil {
					g.Close()
					t.Fatal(err)
				}
				if err := uploadSyncDirectory(filepath.Dir(destination)); err != nil {
					g.Close()
					t.Fatal(err)
				}
			}
			g.Close()
			g, err = lockFolderGroup(state, "publication-proof")
			if err != nil {
				t.Fatal(err)
			}
			defer g.Close()
			err = g.commitChild(entry.Path)
			if collision {
				if err == nil {
					t.Fatal("collision accepted on restart")
				}
				raw, readErr := os.ReadFile(destination)
				if readErr != nil || string(raw) != "original" {
					t.Fatal("collision changed original")
				}
				names, readErr := os.ReadDir(filepath.Dir(destination))
				if readErr != nil || len(names) != 2 {
					t.Fatal("collision selected numbered name")
				}
			} else if err != nil || g.record.Files[entry.Path].State != "committed" {
				t.Fatal("uncertain publication not recovered", err)
			}
		})
	}
}
