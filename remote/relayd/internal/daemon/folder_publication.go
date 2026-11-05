package daemon

import (
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// These helpers are source-only until the group protocol owns the operation
// lock and journals every directory identity and file publication intent.
// All traversal is relative to pinned descriptors, without following symlinks.
func folderOpenDirectory(root *os.File, relative string, identities map[string]string) (*os.File, error) {
	fd, err := unix.Dup(int(root.Fd()))
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(fd)
	current := os.NewFile(uintptr(fd), ".")
	if relative == "." {
		return current, nil
	}
	var prefix string
	for _, component := range strings.Split(relative, "/") {
		if !folderChildName(component) {
			current.Close()
			return nil, errors.New("invalid folder directory path")
		}
		prefix = path.Join(prefix, component)
		nextFD, openErr := unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		current.Close()
		if openErr != nil {
			return nil, openErr
		}
		current = os.NewFile(uintptr(nextFD), prefix)
		info, statErr := current.Stat()
		if statErr != nil || identities[prefix] == "" || uploadIdentity(info) != identities[prefix] {
			current.Close()
			return nil, errors.New("folder directory identity changed")
		}
	}
	return current, nil
}

// The caller persists this receipt in state "publishing" before linking and
// persists "committed" only after this function returns. Stage remains private
// and retained until that journal write is durable, permitting exact recovery.
type folderFileReceipt struct {
	Path           string `json:"path"`
	Stage          string `json:"stage"`
	StageIdentity  string `json:"stage_identity"`
	ParentIdentity string `json:"parent_identity"`
	Size           int64  `json:"size"`
	SHA256         string `json:"sha256"`
	State          string `json:"state"`
}

func folderPublishFile(root, staging *os.File, identities map[string]string, entry folderEntry, receipt folderFileReceipt) error {
	if entry.Kind != "file" || receipt.State != "publishing" || receipt.Path != entry.Path || receipt.Size != entry.Size || receipt.SHA256 != entry.SHA256 || !folderChildName(receipt.Stage) || receipt.StageIdentity == "" || receipt.ParentIdentity == "" {
		return errors.New("exact folder publication intent required")
	}
	if len(entry.Path) > 1024 || len(strings.Split(entry.Path, "/")) > 32 || strings.Split(entry.Path, "/")[0] == folderOwnerMarker {
		return errors.New("folder publication path exceeds bounds")
	}
	for _, component := range strings.Split(entry.Path, "/") {
		if !folderChildName(component) {
			return errors.New("folder publication requires relative child path")
		}
	}
	stagingInfo, err := staging.Stat()
	if err != nil {
		return err
	}
	owner, ok := stagingInfo.Sys().(*syscall.Stat_t)
	if !ok || !stagingInfo.IsDir() || int(owner.Uid) != os.Getuid() || stagingInfo.Mode().Perm()&0077 != 0 {
		return errors.New("private owned folder staging directory required")
	}
	digestBytes, err := hex.DecodeString(entry.SHA256)
	if err != nil || len(digestBytes) != 32 || entry.SHA256 != strings.ToLower(entry.SHA256) || entry.Size < 0 {
		return errors.New("bounded folder file and canonical checksum required")
	}
	parent, err := folderOpenDirectory(root, path.Dir(entry.Path), identities)
	if err != nil {
		return err
	}
	defer parent.Close()
	parentInfo, err := parent.Stat()
	if err != nil || uploadIdentity(parentInfo) != receipt.ParentIdentity {
		return errors.New("file publication parent changed")
	}
	stageFD, err := unix.Openat(int(staging.Fd()), receipt.Stage, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	stage := os.NewFile(uintptr(stageFD), receipt.Stage)
	defer stage.Close()
	info, err := stage.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != entry.Size || uploadIdentity(info) != receipt.StageIdentity {
		return errors.New("folder staging file changed")
	}
	fileOwner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(fileOwner.Uid) != os.Getuid() || info.Mode().Perm()&0077 != 0 {
		return errors.New("private owned folder staging file required")
	}
	digest, err := uploadDigest(stage, entry.Size)
	if err != nil || digest != entry.SHA256 {
		return errors.New("folder staging checksum differs")
	}
	if err := stage.Sync(); err != nil {
		return err
	}
	// Linkat never overwrites a collision. An uncertain repeat can accept only
	// the same inode; byte equality alone cannot establish ownership.
	err = unix.Linkat(int(staging.Fd()), receipt.Stage, int(parent.Fd()), path.Base(entry.Path), 0)
	if err != nil && !errors.Is(err, unix.EEXIST) {
		return err
	}
	publishedFD, err := unix.Openat(int(parent.Fd()), path.Base(entry.Path), unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	published := os.NewFile(uintptr(publishedFD), entry.Path)
	defer published.Close()
	publishedInfo, err := published.Stat()
	if err != nil || !publishedInfo.Mode().IsRegular() || !os.SameFile(info, publishedInfo) || publishedInfo.Size() != entry.Size {
		return errors.New("folder filename collision or publication outcome unknown")
	}
	if err := parent.Sync(); err != nil {
		return err
	}
	var named unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), path.Base(entry.Path), &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if uint64(named.Dev) != uint64(fileOwner.Dev) || named.Ino != fileOwner.Ino {
		return errors.New("folder file moved before acknowledgement")
	}
	return nil
}

// Verify the whole tree, including empty directories and unexpected entries.
// The ownership marker is the sole non-manifest entry permitted at the root.
// Caller must hold the group lock and revalidate the reservation before and
// after verification; external filesystem writers are not covered by that lock.
func folderVerifyManifest(root *os.File, entries []folderEntry, identities map[string]string, receipts map[string]folderFileReceipt) error {
	canonical, _, err := canonicalFolderManifest(entries)
	if err != nil {
		return err
	}
	expected := map[string]map[string]folderEntry{".": {}}
	for _, entry := range canonical {
		parent := path.Dir(entry.Path)
		if expected[parent] == nil {
			expected[parent] = make(map[string]folderEntry)
		}
		expected[parent][path.Base(entry.Path)] = entry
		if entry.Kind == "directory" && expected[entry.Path] == nil {
			expected[entry.Path] = make(map[string]folderEntry)
		}
	}
	for relative, children := range expected {
		dir, err := folderOpenDirectory(root, relative, identities)
		if err != nil {
			return err
		}
		// Dup shares directory offsets. Open "." to get an independent cursor.
		fd, err := unix.Openat(int(dir.Fd()), ".", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
		dir.Close()
		if err != nil {
			return err
		}
		dir = os.NewFile(uintptr(fd), relative)
		err = folderVerifyChildren(dir, relative, children, identities, receipts)
		dir.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func folderVerifyChildren(dir *os.File, relative string, expected map[string]folderEntry, identities map[string]string, receipts map[string]folderFileReceipt) error {
	parentInfo, err := dir.Stat()
	if err != nil {
		return err
	}
	seen := make(map[string]bool)
	for {
		names, err := dir.Readdirnames(128)
		if err != nil && err != io.EOF {
			return err
		}
		for _, name := range names {
			if relative == "." && name == folderOwnerMarker {
				continue
			}
			entry, exists := expected[name]
			if !exists || seen[name] {
				return errors.New("folder contains unexpected entry")
			}
			seen[name] = true
			flags := unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_CLOEXEC
			if entry.Kind == "directory" {
				flags |= unix.O_DIRECTORY
			}
			fd, openErr := unix.Openat(int(dir.Fd()), name, flags, 0)
			if openErr != nil {
				return openErr
			}
			file := os.NewFile(uintptr(fd), entry.Path)
			info, statErr := file.Stat()
			valid := statErr == nil
			if entry.Kind == "directory" {
				valid = valid && info.IsDir() && identities[entry.Path] != "" && uploadIdentity(info) == identities[entry.Path]
			} else {
				receipt := receipts[entry.Path]
				valid = valid && info.Mode().IsRegular() && info.Size() == entry.Size && receipt.State == "committed" && receipt.Path == entry.Path && receipt.Size == entry.Size && receipt.SHA256 == entry.SHA256 && receipt.ParentIdentity == uploadIdentity(parentInfo) && receipt.StageIdentity != "" && uploadIdentity(info) == receipt.StageIdentity
				if valid {
					digest, digestErr := uploadDigest(file, entry.Size)
					valid = digestErr == nil && digest == entry.SHA256
				}
			}
			file.Close()
			if !valid {
				return errors.New("folder manifest or receipt differs from destination")
			}
		}
		if err == io.EOF {
			break
		}
	}
	if len(seen) != len(expected) {
		return errors.New("folder manifest entry missing")
	}
	return dir.Sync()
}
