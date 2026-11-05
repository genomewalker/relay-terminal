package subscriptionquota

import (
	"crypto/rand"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

func owned(info os.FileInfo, uid uint32) bool {
	s, ok := info.Sys().(*syscall.Stat_t)
	return ok && s.Uid == uid
}
func sameFile(a, b os.FileInfo) bool { return a != nil && b != nil && os.SameFile(a, b) }

func privateFile(path string, maximum int, uid uint32) (map[string]any, error) {
	// NONBLOCK prevents a hostile FIFO from hanging before the regular-file check.
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, errUnavailable
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	before, err := f.Stat()
	if err != nil || !before.Mode().IsRegular() || !owned(before, uid) || before.Mode().Perm()&0077 != 0 || before.Size() > int64(maximum) {
		return nil, errUnavailable
	}
	data, err := io.ReadAll(io.LimitReader(f, int64(maximum)+1))
	if err != nil || len(data) > maximum {
		return nil, errUnavailable
	}
	after, err := f.Stat()
	pathInfo, pathErr := os.Lstat(path)
	if err != nil || pathErr != nil || !privateSnapshotMatches(before, after, pathInfo, uid) {
		return nil, errUnavailable
	}
	return decodeObject(data, maximum)
}

func privateSnapshotMatches(before, after, pathInfo os.FileInfo, uid uint32) bool {
	return sameFile(before, after) && sameFile(before, pathInfo) && before.Size() == after.Size() && before.ModTime() == after.ModTime() && pathInfo.Mode()&os.ModeSymlink == 0 && owned(after, uid) && after.Mode().Perm()&0077 == 0 && owned(pathInfo, uid) && pathInfo.Mode().Perm()&0077 == 0
}

func privateDirectory(path string, uid uint32) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 && owned(info, uid) && info.Mode().Perm()&0077 == 0
}

// CaptureStatus records only bounded, reported Claude windows. It never edits
// provider configuration. Statusline forwarding remains independent of capture.
func (r *Reader) CaptureStatus(raw []byte) error {
	record, err := statusRecord(raw, r.accountScope("claude"), r.now())
	if err != nil || record == nil {
		return err
	}
	ident := text(record["session_id"])
	dir := filepath.Join(r.home, ".local/share/relay/claude-status")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return errUnavailable
	}
	if !privateDirectory(dir, r.uid) {
		return errUnavailable
	}
	data, err := marshal(record)
	if err != nil {
		return err
	}
	// Anchor creation and rename to one checked directory inode. Replacing a
	// directory with a symlink cannot redirect a status observation elsewhere.
	dfd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return errUnavailable
	}
	directory := os.NewFile(uintptr(dfd), dir)
	defer directory.Close()
	before, err := directory.Stat()
	if err != nil || !owned(before, r.uid) || before.Mode().Perm()&0077 != 0 {
		return errUnavailable
	}
	var random [16]byte
	if _, err = rand.Read(random[:]); err != nil {
		return errUnavailable
	}
	name := ".quota-" + hex.EncodeToString(random[:])
	fd, err := unix.Openat(dfd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return errUnavailable
	}
	f := os.NewFile(uintptr(fd), name)
	defer f.Close()
	defer unix.Unlinkat(dfd, name, 0)
	if _, err = f.Write(data); err != nil {
		return errUnavailable
	}
	if err = f.Sync(); err != nil {
		return errUnavailable
	}
	if err = f.Close(); err != nil {
		return errUnavailable
	}
	after, err := os.Lstat(dir)
	if err != nil || !sameFile(before, after) || !privateDirectory(dir, r.uid) {
		return errUnavailable
	}
	return unix.Renameat(dfd, name, dfd, "session-"+ident+".json")
}
