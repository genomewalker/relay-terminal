//go:build !darwin && !linux

package daemon

import "errors"

func renameDirectoryNoReplace(fromFD int, from string, toFD int, to string) error {
	return errors.New("atomic directory publication is unavailable on this platform")
}
