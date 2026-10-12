package daemon

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// Cleanup is a separate private journal: terminal transfer receipts never
// change. The group lock also serializes cleanup. Published names are never
// passed to unlink; only saved staging names under its verified descriptor.
type folderCleanupRecord struct {
	Format        int    `json:"format"`
	ID            string `json:"id"`
	Fingerprint   string `json:"fingerprint"`
	StageIdentity string `json:"stage_identity"`
	State         string `json:"state"`
}

func saveFolderCleanup(root string, record folderCleanupRecord) error {
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(root, ".cleanup-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	n, err := f.Write(raw)
	if err == nil && n != len(raw) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(f.Name(), filepath.Join(root, record.ID+".cleanup.json")); err != nil {
		return err
	}
	return uploadSyncDirectory(root)
}

func (g *lockedFolderGroup) cleanupStaging() (resultErr error) {
	if g.lock == nil || g.uncertain || g.record.State != "committed" && g.record.State != "cancelled" {
		return errors.New("terminal folder receipt and active lock required for cleanup")
	}
	defer func() {
		if resultErr != nil {
			g.uncertain = true
		}
	}()
	if g.record.Staging == nil {
		return nil
	}
	r := *g.record.Staging
	if r.State != "reserved" {
		return errors.New("staging reservation outcome unknown; cleanup requires saved inode")
	}
	cleanup := folderCleanupRecord{Format: 1, ID: g.record.ID, Fingerprint: g.record.Fingerprint, StageIdentity: r.Identity, State: "prepared"}
	f, err := OpenPrivateFile(filepath.Join(g.root, g.record.ID+".cleanup.json"), os.O_RDONLY)
	if err == nil {
		raw, readErr := io.ReadAll(io.LimitReader(f, 16385))
		f.Close()
		if readErr != nil || len(raw) > 16384 || json.Unmarshal(raw, &cleanup) != nil || cleanup.Format != 1 || cleanup.ID != g.record.ID || cleanup.Fingerprint != g.record.Fingerprint || cleanup.StageIdentity != r.Identity || cleanup.State != "prepared" && cleanup.State != "removing" && cleanup.State != "done" {
			return errors.New("invalid folder cleanup journal")
		}
	} else if !os.IsNotExist(err) {
		return err
	} else if err := saveFolderCleanup(g.root, cleanup); err != nil {
		return err
	}
	if cleanup.State == "done" {
		return nil
	}
	parentFD, err := unix.Open(r.Parent, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	parent := os.NewFile(uintptr(parentFD), r.Parent)
	defer parent.Close()
	parentInfo, err := parent.Stat()
	if err != nil || uploadIdentity(parentInfo) != r.ParentIdentity {
		return errors.New("folder cleanup parent changed")
	}
	var named unix.Stat_t
	err = unix.Fstatat(parentFD, r.Name, &named, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) && cleanup.State == "removing" {
		if err := parent.Sync(); err != nil {
			return err
		}
		cleanup.State = "done"
		return saveFolderCleanup(g.root, cleanup)
	}
	if err != nil {
		return err
	}
	// Missing marker with an extant directory is unresolved, even if its inode
	// matches. Never infer ownership of a replacement after marker removal.
	stage, err := openVerifiedFolderReservation(filepath.Join(g.root, "staging-reservations"), r)
	if err != nil {
		return err
	}
	defer stage.Close()
	for _, upload := range g.record.Uploads {
		fd, err := unix.Openat(int(stage.Fd()), upload.Stage, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(err, unix.ENOENT) {
			continue
		}
		if err != nil {
			return err
		}
		file := os.NewFile(uintptr(fd), upload.Stage)
		info, err := file.Stat()
		file.Close()
		if err != nil || !info.Mode().IsRegular() || upload.Identity == "" || uploadIdentity(info) != upload.Identity {
			return errors.New("folder cleanup stage file identity unknown or changed")
		}
		if err := unix.Unlinkat(int(stage.Fd()), upload.Stage, 0); err != nil {
			return err
		}
	}
	if err := stage.Sync(); err != nil {
		return err
	}
	names, err := stage.Readdirnames(2)
	if err != nil && err != io.EOF {
		return err
	}
	if len(names) != 1 || names[0] != folderOwnerMarker {
		return errors.New("folder staging contains unknown entries; cleanup stopped")
	}
	cleanup.State = "removing"
	if err := saveFolderCleanup(g.root, cleanup); err != nil {
		return err
	}
	if err := unix.Unlinkat(int(stage.Fd()), folderOwnerMarker, 0); err != nil {
		return err
	}
	if err := stage.Sync(); err != nil {
		return err
	}
	if err := unix.Fstatat(parentFD, r.Name, &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	stageInfo, err := stage.Stat()
	if err != nil {
		return err
	}
	if stageInfoIdentity := uploadIdentity(stageInfo); stageInfoIdentity != r.Identity {
		return errors.New("folder staging identity changed during cleanup")
	}
	// Check the named inode again before rmdir. Nonempty directories are refused;
	// external writers with the same UID are not serialized by the group lock.
	fd, err := unix.Openat(parentFD, r.Name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	current := os.NewFile(uintptr(fd), r.Name)
	currentInfo, err := current.Stat()
	current.Close()
	if err != nil || !os.SameFile(stageInfo, currentInfo) {
		return errors.New("folder staging moved during cleanup")
	}
	if err := unix.Unlinkat(parentFD, r.Name, unix.AT_REMOVEDIR); err != nil {
		return err
	}
	if err := parent.Sync(); err != nil {
		return err
	}
	cleanup.State = "done"
	return saveFolderCleanup(g.root, cleanup)
}
