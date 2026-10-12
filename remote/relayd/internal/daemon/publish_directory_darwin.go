//go:build darwin

package daemon

import "golang.org/x/sys/unix"

func renameDirectoryNoReplace(fromFD int, from string, toFD int, to string) error {
	return unix.RenameatxNp(fromFD, from, toFD, to, unix.RENAME_EXCL)
}
