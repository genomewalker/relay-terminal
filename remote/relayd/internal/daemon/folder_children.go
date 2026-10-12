package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path"
	"syscall"

	"golang.org/x/sys/unix"
)

type folderChildUpload struct {
	Stage        string `json:"stage"`
	Identity     string `json:"identity"`
	State        string `json:"state"`
	Offset       int64  `json:"offset"`
	PrefixSHA256 string `json:"prefix_sha256"`
}

func folderChildStageName(relative string) string {
	sum := sha256.Sum256([]byte(relative))
	return "file-" + hex.EncodeToString(sum[:])
}

func folderEmptyDigest() string {
	sum := sha256.Sum256(nil)
	return hex.EncodeToString(sum[:])
}

func (g *lockedFolderGroup) childEntry(relative string) (folderEntry, error) {
	if g.lock == nil || g.uncertain || g.record.State != "receiving" {
		return folderEntry{}, errors.New("receiving folder group and active lock required")
	}
	for _, entry := range g.record.Entries {
		if entry.Path == relative && entry.Kind == "file" {
			return entry, nil
		}
	}
	return folderEntry{}, errors.New("exact manifest file required")
}

// Prepared stage creation is never retried without its saved inode. Chunks are
// acknowledged only after data fsync and group checkpoint publication; replay
// verifies durable bytes and an uncheckpointed tail is truncated on reopening.
func (g *lockedFolderGroup) openChild(staging *os.File, entry folderEntry) (*os.File, error) {
	if g.record.Uploads == nil {
		g.record.Uploads = make(map[string]folderChildUpload)
	}
	upload, exists := g.record.Uploads[entry.Path]
	if !exists {
		upload = folderChildUpload{Stage: folderChildStageName(entry.Path), State: "prepared", PrefixSHA256: folderEmptyDigest()}
		g.record.Uploads[entry.Path] = upload
		if err := g.save(); err != nil {
			return nil, err
		}
		fd, err := unix.Openat(int(staging.Fd()), upload.Stage, unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
		if err != nil {
			return nil, err
		}
		f := os.NewFile(uintptr(fd), upload.Stage)
		info, err := f.Stat()
		if err == nil {
			err = f.Sync()
		}
		if err == nil {
			err = staging.Sync()
		}
		if err != nil {
			f.Close()
			return nil, err
		}
		upload.Identity, upload.State = uploadIdentity(info), "receiving"
		g.record.Uploads[entry.Path] = upload
		if err := g.save(); err != nil {
			f.Close()
			return nil, err
		}
		return f, nil
	}
	if upload.State != "receiving" {
		return nil, errors.New("folder child creation outcome unknown; saved inode missing")
	}
	fd, err := unix.Openat(int(staging.Fd()), upload.Stage, unix.O_RDWR|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), upload.Stage)
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || uploadIdentity(info) != upload.Identity || info.Size() < upload.Offset {
		f.Close()
		return nil, errors.New("folder child staging identity changed")
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || info.Mode().Perm()&0077 != 0 {
		f.Close()
		return nil, errors.New("folder child staging ownership changed")
	}
	digest, err := uploadDigest(f, upload.Offset)
	if err != nil || digest != upload.PrefixSHA256 {
		f.Close()
		return nil, errors.New("folder durable child bytes changed")
	}
	if info.Size() != upload.Offset {
		if g.record.Files[entry.Path].State != "" {
			f.Close()
			return nil, errors.New("publishing folder child size changed")
		}
		if err := f.Truncate(upload.Offset); err != nil {
			f.Close()
			return nil, err
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return nil, err
		}
	}
	return f, nil
}

func (g *lockedFolderGroup) childChunk(relative string, offset int64, data []byte) error {
	entry, err := g.childEntry(relative)
	if err != nil {
		return err
	}
	if g.record.Files[relative].State != "" {
		return errors.New("folder child is publishing or committed")
	}
	if offset < 0 || offset > entry.Size || len(data) == 0 || len(data) > 4<<20 || int64(len(data)) > entry.Size-offset {
		return errors.New("bounded folder child chunk required")
	}
	if offset > g.record.Uploads[relative].Offset {
		return errors.New("sequential folder child chunk required")
	}
	staging, err := g.openStagingDirectory()
	if err != nil {
		return err
	}
	defer staging.Close()
	f, err := g.openChild(staging, entry)
	if err != nil {
		return err
	}
	defer f.Close()
	upload := g.record.Uploads[relative]
	if offset < upload.Offset {
		if int64(len(data)) > upload.Offset-offset {
			return errors.New("folder child replay crosses checkpoint")
		}
		old := make([]byte, len(data))
		if _, err := f.ReadAt(old, offset); err != nil {
			return err
		}
		if sha256.Sum256(old) != sha256.Sum256(data) {
			return errors.New("folder child replay differs")
		}
		return nil
	}
	n, err := f.WriteAt(data, offset)
	if err != nil {
		return err
	}
	if n != len(data) {
		return io.ErrShortWrite
	}
	if err := f.Sync(); err != nil {
		return err
	}
	upload.Offset += int64(n)
	upload.PrefixSHA256, err = uploadDigest(f, upload.Offset)
	if err != nil {
		return err
	}
	g.record.Uploads[relative] = upload
	return g.save()
}

func (g *lockedFolderGroup) commitChild(relative string) error {
	if g.lock != nil && !g.uncertain && g.record.State == "committed" && g.record.Files[relative].State == "committed" {
		return nil
	}
	entry, err := g.childEntry(relative)
	if err != nil {
		return err
	}
	if g.record.Files[relative].State == "committed" {
		return nil
	}
	staging, err := g.openStagingDirectory()
	if err != nil {
		return err
	}
	defer staging.Close()
	f, err := g.openChild(staging, entry)
	if err != nil {
		return err
	}
	f.Close()
	upload := g.record.Uploads[relative]
	if upload.Offset != entry.Size || upload.PrefixSHA256 != entry.SHA256 {
		return errors.New("folder child incomplete or checksum differs")
	}
	root, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	defer root.Close()
	if g.record.Files == nil {
		g.record.Files = make(map[string]folderFileReceipt)
	}
	if g.record.Files[relative].State == "" {
		parent, err := folderOpenDirectory(root, path.Dir(relative), g.record.Directories)
		if err != nil {
			return err
		}
		info, err := parent.Stat()
		parent.Close()
		if err != nil {
			return err
		}
		g.record.Files[relative] = folderFileReceipt{Path: relative, Stage: upload.Stage, StageIdentity: upload.Identity, ParentIdentity: uploadIdentity(info), Size: entry.Size, SHA256: entry.SHA256, State: "publishing"}
		if err := g.save(); err != nil {
			return err
		}
	}
	receipt := g.record.Files[relative]
	if err := folderPublishFile(root, staging, g.record.Directories, entry, receipt); err != nil {
		return err
	}
	current, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	current.Close()
	receipt.State = "committed"
	g.record.Files[relative] = receipt
	if err := g.save(); err != nil {
		return err
	}
	// Retain the private hard link for now. Cleanup must verify the saved stage
	// identity and its durable receipt; it can never remove the published name.
	return nil
}
