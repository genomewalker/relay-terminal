package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

// A reserved real directory may be visible before its files are complete.
// The private journal precedes mkdir. Missing ownership evidence after a crash
// is an unknown outcome; recovery never adopts an unmarked directory.
type folderReservation struct {
	Format         int    `json:"format"`
	ID             string `json:"id"`
	Fingerprint    string `json:"fingerprint"`
	Parent         string `json:"parent"`
	ParentIdentity string `json:"parent_identity"`
	Name           string `json:"name"`
	Nonce          string `json:"nonce"`
	Identity       string `json:"identity,omitempty"`
	State          string `json:"state"`
}

func saveFolderReservation(root string, record folderReservation) error {
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(root, ".reservation-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(raw)
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
	if err = os.Rename(f.Name(), filepath.Join(root, record.ID+".json")); err != nil {
		return err
	}
	return uploadSyncDirectory(root)
}

// root is a private reservation catalog. The caller binds fingerprint to pane,
// manifest and host before calling; this helper also pins the destination inode.
// An EEXIST result is terminal for this ID. Selecting another name requires a
// new explicit reservation, never an automatic retry after an unknown outcome.
func reserveFolder(root, id, parent, name, fingerprint, expectedParentIdentity string) (folderReservation, error) {
	var record folderReservation
	digest, err := hex.DecodeString(fingerprint)
	if !validSessionID.MatchString(id) || !filepath.IsAbs(parent) || filepath.Clean(parent) != parent || !folderChildName(name) || err != nil || len(digest) != 32 {
		return record, errors.New("exact folder destination, stable ID and fingerprint required")
	}
	if err := EnsurePrivateRuntimeDir(root); err != nil {
		return record, err
	}
	// Persist the catalog's own entry before a journal can authorize mkdir.
	if err := uploadSyncDirectory(filepath.Dir(root)); err != nil {
		return record, err
	}
	lock, err := OpenPrivateFile(filepath.Join(root, id+".lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return record, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return record, errors.New("folder reservation busy")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	parentFD, err := unix.Open(parent, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return record, err
	}
	parentFile := os.NewFile(uintptr(parentFD), parent)
	defer parentFile.Close()
	parentInfo, err := parentFile.Stat()
	if err != nil {
		return record, err
	}
	if expectedParentIdentity == "" || uploadIdentity(parentInfo) != expectedParentIdentity {
		return record, errors.New("folder reservation parent differs from prepared group")
	}
	initial := false
	f, err := OpenPrivateFile(filepath.Join(root, id+".json"), os.O_RDONLY)
	if err == nil {
		raw, readErr := io.ReadAll(io.LimitReader(f, 16385))
		f.Close()
		if readErr != nil || len(raw) > 16384 || json.Unmarshal(raw, &record) != nil || record.Format != 1 || record.ID != id || record.Fingerprint != fingerprint || record.Parent != parent || record.ParentIdentity != uploadIdentity(parentInfo) || record.Name != name || len(record.Nonce) != 64 {
			return record, errors.New("folder reservation binding changed or checkpoint invalid")
		}
		if _, err := hex.DecodeString(record.Nonce); err != nil {
			return record, errors.New("invalid reservation nonce")
		}
	} else if os.IsNotExist(err) {
		nonce := make([]byte, 32)
		if _, err = rand.Read(nonce); err != nil {
			return record, err
		}
		record = folderReservation{Format: 1, ID: id, Fingerprint: fingerprint, Parent: parent, ParentIdentity: uploadIdentity(parentInfo), Name: name, Nonce: hex.EncodeToString(nonce), State: "prepared"}
		if err = saveFolderReservation(root, record); err != nil {
			return record, err
		}
		initial = true
	} else {
		return record, err
	}
	if record.State == "collision" {
		return record, errors.New("folder destination exists")
	}
	if record.State != "prepared" && record.State != "reserved" {
		return record, errors.New("invalid reservation state")
	}
	if record.State == "reserved" && record.Identity == "" {
		return record, errors.New("reserved folder checkpoint lacks inode identity")
	}
	if initial {
		if err = unix.Mkdirat(parentFD, name, 0700); err != nil {
			if errors.Is(err, unix.EEXIST) {
				record.State = "collision"
				if saveErr := saveFolderReservation(root, record); saveErr != nil {
					return record, saveErr
				}
			}
			return record, err
		}
	}
	dirFD, err := unix.Openat(parentFD, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return record, errors.New("folder reservation outcome unknown: destination unavailable")
	}
	dir := os.NewFile(uintptr(dirFD), name)
	defer dir.Close()
	info, err := dir.Stat()
	if err != nil {
		return record, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0077 != 0 || (record.Identity != "" && uploadIdentity(info) != record.Identity) {
		return record, errors.New("folder reservation ownership changed")
	}
	if initial {
		markerFD, openErr := unix.Openat(dirFD, folderOwnerMarker, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
		if openErr != nil {
			return record, openErr
		}
		marker := os.NewFile(uintptr(markerFD), folderOwnerMarker)
		_, err = marker.WriteString(record.Nonce)
		if err == nil {
			err = marker.Sync()
		}
		closeErr := marker.Close()
		if err == nil {
			err = closeErr
		}
		if err != nil {
			return record, err
		}
	} else {
		markerFD, openErr := unix.Openat(dirFD, folderOwnerMarker, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if openErr != nil {
			return record, errors.New("folder reservation outcome unknown: ownership marker unavailable")
		}
		marker := os.NewFile(uintptr(markerFD), folderOwnerMarker)
		markerInfo, statErr := marker.Stat()
		if statErr != nil || !markerInfo.Mode().IsRegular() || markerInfo.Size() != 64 {
			marker.Close()
			return record, errors.New("folder reservation ownership marker invalid")
		}
		raw, readErr := io.ReadAll(io.LimitReader(marker, 65))
		marker.Close()
		if readErr != nil || string(raw) != record.Nonce {
			return record, errors.New("folder reservation ownership marker differs")
		}
	}
	if err = dir.Sync(); err != nil {
		return record, err
	}
	if err = parentFile.Sync(); err != nil {
		return record, err
	}
	// Check the name still points at the pinned inode before acknowledging it.
	var current unix.Stat_t
	if err = unix.Fstatat(parentFD, name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return record, err
	}
	if uint64(current.Dev) != uint64(stat.Dev) || current.Ino != stat.Ino {
		return record, errors.New("folder reservation moved before acknowledgement")
	}
	record.Identity, record.State = uploadIdentity(info), "reserved"
	if err = saveFolderReservation(root, record); err != nil {
		return record, err
	}
	return record, nil
}
