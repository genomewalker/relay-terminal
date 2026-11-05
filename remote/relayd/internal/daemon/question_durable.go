package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Every question-state write that a dispatch, a notice or a removal depends on
// goes through these helpers. A file is synced before its rename, and the
// directory that holds it is synced after. A directory is made durable by
// syncing every directory of its real path (symlinks resolved) down to it,
// because syncing a directory persists the entries it holds, including a child
// created since its last sync. The chain stops at a device change: the topmost
// ancestor on the target's st_dev is synced, its parent is not. The entry naming
// a mount point lives on another filesystem, is not part of this data, and may
// refuse fsync (an autofs mount point returns EINVAL). st_dev does not reveal a
// bind mount of the same filesystem; such a chain simply continues upward.
// Nothing else is inferred from a Stat: a directory that already exists is
// synced too, since an earlier attempt may have created it without syncing.

// questionJournalSync is the durability call for every question-state write.
// Tests replace it to observe or fail a sync.
var questionJournalSync = func(file *os.File) error { return file.Sync() }

// syncDirectory makes the entries of one directory durable.
func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return questionJournalSync(dir)
}

// durableDirectory creates dir if it is missing, then makes it reachable durably,
// from the filesystem root down. It returns an error unless every sync succeeds.
func durableDirectory(dir string) error {
	dir = filepath.Clean(dir)
	if !filepath.IsAbs(dir) {
		return errors.New("durable directory must be absolute")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// The chain is built from the real path, so device lookups and syncs
	// address the same directories, never a symlink's own parent.
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return err
	}
	device, err := durableDirectoryDevice(real)
	if err != nil {
		return err
	}
	var chain []string
	for d := real; ; d = filepath.Dir(d) {
		chain = append([]string{d}, chain...)
		parent := filepath.Dir(d)
		if parent == d {
			break
		}
		// Every error up to the mount root fails closed.
		parentDevice, err := durableDirectoryDevice(parent)
		if err != nil {
			return err
		}
		if parentDevice != device {
			break // d is the mount root
		}
	}
	for _, d := range chain {
		if err := syncDirectory(d); err != nil {
			return err
		}
	}
	// A component replaced during the walk would leave the synced chain
	// naming other directories.
	if again, err := filepath.EvalSymlinks(dir); err != nil || again != real {
		return fmt.Errorf("durable directory %s changed while it was synced", dir)
	}
	if again, err := filepath.EvalSymlinks(real); err != nil || again != real {
		return fmt.Errorf("durable directory %s changed while it was synced", real)
	}
	return nil
}

// durableDirectoryDevice is the filesystem a path's entry lives on. Tests
// replace it to model a mount boundary.
var durableDirectoryDevice = func(path string) (uint64, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("no device for " + path)
	}
	return uint64(stat.Dev), nil
}

// durableWriteFile replaces path with data. The new content is synced before the
// rename, and the directory is synced after it. A failure at any step is returned,
// and the old file stays in place until the rename.
func durableWriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := durableDirectory(dir); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(dir, ".durable-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := questionJournalSync(temporary); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return err
	}
	return syncDirectory(dir)
}

// durableRemoveFile removes path and syncs its directory, so the removal survives a
// rollback. An absent file is still synced, because an earlier unsynced removal may
// not be durable yet. An absent directory has no entries to sync.
func durableRemoveFile(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// durableCreated makes a file that was just created exclusively durable: the file
// is synced, then its directory chain.
func durableCreated(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := questionJournalSync(file); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return durableDirectory(filepath.Dir(path))
}
