package daemon

import (
	"errors"
	"os"
	"path"
	"syscall"

	"golang.org/x/sys/unix"
)

// materializeDirectories runs under the group lock. A durable creation intent
// precedes mkdirat; a durable inode receipt follows child/parent fsync. A crash
// in that gap is deliberately unresolved: without a saved inode, a later call
// neither adopts a directory nor recreates a missing one under the same ID.
// No marker is added to children, preserving every manifest child filename.
func (g *lockedFolderGroup) materializeDirectories() error {
	if g.lock == nil || g.uncertain || g.record.State != "receiving" {
		return errors.New("receiving folder group and active lock required")
	}
	root, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	defer root.Close()
	if g.record.DirectoryIntents == nil {
		g.record.DirectoryIntents = make(map[string]string)
	}
	if g.record.Directories == nil {
		g.record.Directories = make(map[string]string)
	}
	entries, _, err := canonicalFolderManifest(g.record.Entries)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Kind != "directory" {
			continue
		}
		if g.record.Directories[entry.Path] != "" {
			dir, err := folderOpenDirectory(root, entry.Path, g.record.Directories)
			if err != nil {
				return err
			}
			dir.Close()
			continue
		}
		if g.record.DirectoryIntents[entry.Path] != "" {
			return errors.New("folder child directory creation outcome unknown; saved inode missing")
		}
		parent, err := folderOpenDirectory(root, path.Dir(entry.Path), g.record.Directories)
		if err != nil {
			return err
		}
		err = g.createManifestDirectory(parent, entry.Path)
		parent.Close()
		if err != nil {
			return err
		}
	}
	current, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	return current.Close()
}

func (g *lockedFolderGroup) createManifestDirectory(parent *os.File, relative string) error {
	parentInfo, err := parent.Stat()
	if err != nil {
		return err
	}
	g.record.DirectoryIntents[relative] = uploadIdentity(parentInfo)
	if err := g.save(); err != nil {
		return err
	}
	if err := unix.Mkdirat(int(parent.Fd()), path.Base(relative), 0700); err != nil {
		return err
	}
	fd, err := unix.Openat(int(parent.Fd()), path.Base(relative), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	dir := os.NewFile(uintptr(fd), relative)
	defer dir.Close()
	info, err := dir.Stat()
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0077 != 0 {
		return errors.New("folder child directory ownership changed")
	}
	if err := dir.Sync(); err != nil {
		return err
	}
	if err := parent.Sync(); err != nil {
		return err
	}
	var named unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), path.Base(relative), &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if uint64(named.Dev) != uint64(stat.Dev) || named.Ino != stat.Ino {
		return errors.New("folder child directory moved before acknowledgement")
	}
	g.record.Directories[relative] = uploadIdentity(info)
	return g.save()
}
