package daemon

import (
	"errors"
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

// Publication uses pinned parent descriptors. The staging parent must be
// private so a different user cannot swap the checked tree before rename.
// The caller journals the destination first and flushes both parents afterward.
func publishDirectoryNoReplace(fromFD int, from string, toFD int, to string) error {
	for _, name := range []string{from, to} {
		if name == "" || name == "." || name == ".." || len(name) > 255 || strings.ContainsAny(name, "/\x00") {
			return errors.New("directory publication requires bounded child names")
		}
	}
	var sourceParent, destinationParent, source unix.Stat_t
	if err := unix.Fstat(fromFD, &sourceParent); err != nil {
		return err
	}
	if err := unix.Fstat(toFD, &destinationParent); err != nil {
		return err
	}
	if uint32(sourceParent.Mode)&unix.S_IFMT != unix.S_IFDIR || int(sourceParent.Uid) != os.Getuid() || uint32(sourceParent.Mode)&077 != 0 || uint32(destinationParent.Mode)&unix.S_IFMT != unix.S_IFDIR {
		return errors.New("private staging parent and pinned destination directory required")
	}
	if err := unix.Fstatat(fromFD, from, &source, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if uint32(source.Mode)&unix.S_IFMT != unix.S_IFDIR || int(source.Uid) != os.Getuid() {
		return errors.New("publication source is not an owned directory")
	}
	return renameDirectoryNoReplace(fromFD, from, toFD, to)
}
