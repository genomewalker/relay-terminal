//go:build !unix

package agentaccounts

import (
	"errors"
	"os/exec"
)

func isolate(command *exec.Cmd) (end func()) { return func() {} }

func terminateGently(command *exec.Cmd) {}

func sameDevice(a, b string) bool { return false }

func holdOpen(path string) error {
	return errors.New("account folders cannot be held open on this platform")
}

func lockAccounts(home string, wait bool) (unlock func(), err error) {
	return nil, errors.New("account changes are unsupported on this platform")
}

func renameOver(from, to string) error {
	return errors.New("renaming over a placeholder is unsupported on this platform")
}

func folderIdentity(path string) (dev, inode uint64, ok bool) { return 0, 0, false }

func rmdirOnly(path string) error { return errors.New("rmdir is unsupported on this platform") }
